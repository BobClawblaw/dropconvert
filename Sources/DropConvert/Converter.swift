import AppKit
import Foundation

/// Finds ffmpeg/ffprobe and lists the encoders the build offers.
struct FFmpeg {
    let ffmpeg: URL
    let ffprobe: URL?
    let encoders: Set<String>

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    static func locate() -> FFmpeg? {
        let fm = FileManager.default
        let dirs = searchPaths + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        func find(_ name: String) -> URL? {
            dirs.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { fm.isExecutableFile(atPath: $0.path) }
        }
        guard let ffmpeg = find("ffmpeg") else { return nil }
        let listing = run(ffmpeg, ["-hide_banner", "-encoders"]) ?? ""
        // Lines look like " V....D libx264   libx264 H.264 ...".
        let encoders = listing.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6, "VAS".contains(parts[0].first!) else { return nil }
            return String(parts[1])
        }
        return FFmpeg(ffmpeg: ffmpeg, ffprobe: find("ffprobe"), encoders: Set(encoders))
    }

    /// Duration in seconds, or nil when the container doesn't say.
    func duration(of file: URL) -> Double? {
        guard let ffprobe,
              let out = FFmpeg.run(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                                             "-of", "default=noprint_wrappers=1:nokey=1", file.path]),
              let seconds = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds > 0 else { return nil }
        return seconds
    }

    private static func run(_ tool: URL, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
final class Job: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued
        case running(Double?) // fraction done, nil when the duration is unknown
        case done
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: true
            case .queued, .running: false
            }
        }
    }

    let id = UUID()
    let input: URL
    let output: URL
    let format: OutputFormat
    let options: EncodeOptions
    @Published var state: State = .queued
    @Published var elapsed: TimeInterval = 0
    fileprivate var process: Process?

    init(input: URL, output: URL, format: OutputFormat, options: EncodeOptions) {
        self.input = input
        self.output = output
        self.format = format
        self.options = options
    }
}

/// Runs jobs one at a time, in the order they were dropped.
@MainActor
final class ConversionQueue: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var ffmpeg: FFmpeg?
    let settings: Settings
    private var current: Job?

    init(settings: Settings) {
        self.settings = settings
        self.ffmpeg = FFmpeg.locate()
    }

    var availableFormats: [OutputFormat] {
        guard let ffmpeg else { return [] }
        return OutputFormat.all.filter { $0.isAvailable(ffmpeg.encoders) }
    }

    var activeCount: Int { jobs.filter { !$0.state.isFinished }.count }

    func relocate() { ffmpeg = FFmpeg.locate() }

    func add(_ urls: [URL]) {
        guard let ffmpeg else { return }
        let formats = availableFormats
        guard let format = formats.first(where: { $0.id == settings.formatID }) ?? formats.first else { return }
        let options = EncodeOptions(quality: settings.quality, resolution: settings.resolution,
                                    hardware: settings.hardware, remux: settings.remux,
                                    encoders: ffmpeg.encoders)
        var claimed = Set(jobs.filter { !$0.state.isFinished }.map(\.output.path))
        for url in urls where Self.isFile(url) {
            let output = outputURL(for: url, ext: format.ext, avoiding: claimed)
            claimed.insert(output.path)
            jobs.append(Job(input: url, output: output, format: format, options: options))
        }
        startNext()
    }

    func cancel(_ job: Job) {
        if job.state == .queued {
            job.state = .cancelled
        } else if case .running = job.state {
            job.state = .cancelled
            job.process?.terminate()
        }
    }

    func cancelAll() { jobs.forEach(cancel) }

    func clearFinished() { jobs.removeAll { $0.state.isFinished } }

    func retry(_ job: Job) {
        guard job.state.isFinished, job.state != .done, let i = jobs.firstIndex(where: { $0 === job }) else { return }
        let again = Job(input: job.input, output: job.output, format: job.format, options: job.options)
        jobs[i] = again
        startNext()
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// `name.ext` beside the source (or in the chosen folder), numbered when taken.
    private func outputURL(for input: URL, ext: String, avoiding claimed: Set<String>) -> URL {
        let folder = settings.outputFolder ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        var n = 0
        while true {
            let name = n == 0 ? base : "\(base) \(n + 1)"
            let candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if candidate.standardizedFileURL != input.standardizedFileURL,
               !fm.fileExists(atPath: candidate.path), !claimed.contains(candidate.path) {
                return candidate
            }
            n += 1
        }
    }

    private func startNext() {
        guard current == nil, let ffmpeg, let job = jobs.first(where: { $0.state == .queued }) else { return }
        current = job
        job.state = .running(nil)
        let started = Date()

        Task.detached(priority: .userInitiated) { [self] in
            let duration = ffmpeg.duration(of: job.input)
            let process = Process()
            process.executableURL = ffmpeg.ffmpeg
            process.arguments = job.format.arguments(input: job.input.path, output: job.output.path,
                                                     options: job.options)
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let errors = ErrorTail()
            err.fileHandleForReading.readabilityHandler = { h in errors.append(h.availableData) }
            let progress = ProgressParser()
            out.fileHandleForReading.readabilityHandler = { h in
                guard let seconds = progress.feed(h.availableData) else { return }
                let fraction = duration.map { min(max(seconds / $0, 0), 1) }
                Task { @MainActor in
                    if case .running = job.state { job.state = .running(fraction) }
                    job.elapsed = Date().timeIntervalSince(started)
                }
            }

            let launched: Error? = await MainActor.run {
                guard job.state != .cancelled else { return CancellationError() }
                do { try process.run(); job.process = process; return nil } catch { return error }
            }
            if launched == nil { process.waitUntilExit() }
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil

            await MainActor.run {
                job.process = nil
                job.elapsed = Date().timeIntervalSince(started)
                if job.state == .cancelled {
                    try? FileManager.default.removeItem(at: job.output)
                } else if let launched {
                    job.state = .failed(launched.localizedDescription)
                } else if process.terminationStatus == 0 {
                    job.state = .done
                } else {
                    try? FileManager.default.removeItem(at: job.output)
                    job.state = .failed(job.options.remux && job.format.canRemux
                        ? "These streams can't be copied into .\(job.format.ext). Turn off “Copy streams” to re-encode."
                        : errors.lastLine ?? "ffmpeg exited with status \(process.terminationStatus)")
                }
                self.finished(job)
            }
        }
    }

    private func finished(_ job: Job) {
        current = nil
        if job.state == .done, settings.revealWhenDone, activeCount == 0 {
            NSWorkspace.shared.activateFileViewerSelecting([job.output])
        }
        startNext()
    }
}

/// Reads ffmpeg's `-progress` key=value stream and returns the latest output time.
private final class ProgressParser: @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()

    func feed(_ data: Data) -> Double? {
        lock.lock(); defer { lock.unlock() }
        buffer += String(decoding: data, as: UTF8.self)
        var latest: Double?
        while let nl = buffer.firstIndex(of: "\n") {
            let line = buffer[..<nl]
            buffer.removeSubrange(...nl)
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                latest = us / 1_000_000
            }
        }
        return latest
    }
}

/// Keeps the last few stderr lines so a failure can say why.
private final class ErrorTail: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        lines += String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        if lines.count > 20 { lines.removeFirst(lines.count - 20) }
    }

    var lastLine: String? {
        lock.lock(); defer { lock.unlock() }
        return lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
