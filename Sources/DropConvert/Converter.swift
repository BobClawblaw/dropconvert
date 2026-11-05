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

    /// PATH for child tools launched from Finder, where the environment is minimal.
    static func environment(adding directories: [URL]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var path = directories.map(\.path)
        for dir in searchPaths + ["/bin", "/usr/sbin", "/sbin"] where !path.contains(dir) {
            path.append(dir)
        }
        if let existing = env["PATH"] {
            for dir in existing.split(separator: ":").map(String.init) where !path.contains(dir) {
                path.append(dir)
            }
        }
        env["PATH"] = path.joined(separator: ":")
        return env
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

/// Where a job came from: a file on disk or a link to download.
enum MediaSource {
    case file(URL)
    case link(URL)

    var isLink: Bool {
        if case .link = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .file(let url):
            return url.lastPathComponent
        case .link(let url):
            let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Link"
            if host.contains("youtu"),
               let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                   .queryItems?.first(where: { $0.name == "v" })?.value {
                return "YouTube · \(id)"
            }
            let last = url.lastPathComponent
            return last.isEmpty || last == "/" ? host : "\(host)/\(last)"
        }
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

    enum Phase: Equatable {
        case downloading
        case converting
    }

    let id = UUID()
    let source: MediaSource
    let format: OutputFormat
    let options: EncodeOptions
    @Published var title: String
    @Published var output: URL?
    @Published var state: State = .queued
    @Published var phase: Phase
    @Published var elapsed: TimeInterval = 0
    fileprivate var process: Process?
    fileprivate var inputFile: URL?
    fileprivate var staging: URL?

    init(source: MediaSource, title: String, output: URL?, format: OutputFormat,
         options: EncodeOptions, phase: Phase) {
        self.source = source
        self.title = title
        self.output = output
        self.format = format
        self.options = options
        self.phase = phase
    }

    var isRemote: Bool { source.isLink }
}

/// Runs jobs one at a time, in the order they were added.
@MainActor
final class ConversionQueue: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var ffmpeg: FFmpeg?
    @Published private(set) var downloader: Downloader?
    let settings: Settings
    private var current: Job?

    init(settings: Settings) {
        self.settings = settings
        self.ffmpeg = FFmpeg.locate()
        self.downloader = Downloader.locate()
        Self.removeStaleStaging()
    }

    var availableFormats: [OutputFormat] {
        guard let ffmpeg else { return [] }
        return OutputFormat.all.filter { $0.isAvailable(ffmpeg.encoders) }
    }

    var activeCount: Int { jobs.filter { !$0.state.isFinished }.count }

    func relocate() {
        ffmpeg = FFmpeg.locate()
        downloader = Downloader.locate()
    }

    func add(_ urls: [URL]) {
        guard let format = selectedFormat(), let options = makeOptions() else { return }
        var claimed = claimedOutputs()
        for url in urls where Self.isFile(url) {
            let output = outputURL(for: url, ext: format.ext, avoiding: claimed)
            claimed.insert(output.path)
            jobs.append(Job(source: .file(url), title: url.lastPathComponent, output: output,
                            format: format, options: options, phase: .converting))
        }
        startNext()
    }

    func addLinks(_ urls: [URL]) {
        guard downloader != nil, let format = selectedFormat(), let options = makeOptions() else { return }
        for url in urls {
            let source = MediaSource.link(url)
            jobs.append(Job(source: source, title: source.displayName, output: nil,
                            format: format, options: options, phase: .downloading))
        }
        startNext()
    }

    func cancel(_ job: Job) {
        if job.state == .queued {
            job.state = .cancelled
        } else if case .running = job.state {
            job.state = .cancelled
            if job.phase == .downloading {
                job.process?.interrupt()
            } else {
                job.process?.terminate()
            }
        }
    }

    func cancelAll() { jobs.forEach(cancel) }

    func clearFinished() { jobs.removeAll { $0.state.isFinished } }

    func retry(_ job: Job) {
        guard job.state.isFinished, job.state != .done,
              let i = jobs.firstIndex(where: { $0 === job }) else { return }
        let again = Job(source: job.source,
                        title: job.isRemote ? job.source.displayName : job.title,
                        output: job.isRemote ? nil : job.output,
                        format: job.format,
                        options: job.options,
                        phase: job.isRemote ? .downloading : .converting)
        jobs[i] = again
        startNext()
    }

    // MARK: - Adding and naming

    private func selectedFormat() -> OutputFormat? {
        let formats = availableFormats
        return formats.first(where: { $0.id == settings.formatID }) ?? formats.first
    }

    private func makeOptions() -> EncodeOptions? {
        guard let ffmpeg else { return nil }
        return EncodeOptions(quality: settings.quality, resolution: settings.resolution,
                             hardware: settings.hardware, remux: settings.remux,
                             encoders: ffmpeg.encoders)
    }

    private func claimedOutputs() -> Set<String> {
        Set(jobs.filter { !$0.state.isFinished }.compactMap { $0.output?.path })
    }

    nonisolated private static func isFile(_ url: URL) -> Bool {
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

    /// `title.ext` in the download folder, numbered when taken.
    private func outputURL(base: String, folder: URL, ext: String, avoiding claimed: Set<String>) -> URL {
        let fm = FileManager.default
        let clean = base.isEmpty ? "video" : base
        var n = 0
        while true {
            let name = n == 0 ? clean : "\(clean) \(n + 1)"
            let candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path), !claimed.contains(candidate.path) {
                return candidate
            }
            n += 1
        }
    }

    /// Links go to the chosen folder, or Downloads when none is chosen.
    private var linkFolder: URL {
        if let folder = settings.outputFolder { return folder }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Running jobs

    private func startNext() {
        guard current == nil, let ffmpeg, let job = jobs.first(where: { $0.state == .queued }) else { return }
        current = job
        job.state = .running(nil)
        let started = Date()

        switch job.source {
        case .file(let input):
            job.phase = .converting
            job.inputFile = input
            runConversion(job, input: input, ffmpeg: ffmpeg, started: started)
        case .link(let link):
            job.phase = .downloading
            guard downloader != nil else {
                job.state = .failed("yt-dlp not found. Install it with Homebrew: brew install yt-dlp")
                finished(job)
                return
            }
            runDownload(job, link: link, ffmpeg: ffmpeg, started: started)
        }
    }

    private func runDownload(_ job: Job, link: URL, ffmpeg: FFmpeg, started: Date) {
        guard let ytDlp = downloader?.ytDlp else {
            job.state = .failed("yt-dlp not found. Install it with Homebrew: brew install yt-dlp")
            finished(job)
            return
        }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("DropConvert-\(job.id.uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            job.state = .failed("Couldn't create a temporary folder: \(error.localizedDescription)")
            finished(job)
            return
        }
        job.staging = staging

        let pathFile = staging.appendingPathComponent("downloaded-path.txt")
        let arguments = downloadArguments(job: job, link: link, staging: staging,
                                          pathFile: pathFile, ffmpeg: ffmpeg)

        Task.detached(priority: .userInitiated) { [self] in
            let process = Process()
            process.executableURL = ytDlp
            process.arguments = arguments
            process.environment = FFmpeg.environment(adding: [ffmpeg.ffmpeg.deletingLastPathComponent()])
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let errors = ErrorTail()
            err.fileHandleForReading.readabilityHandler = { h in errors.append(h.availableData) }
            let progress = DownloadProgressParser()
            out.fileHandleForReading.readabilityHandler = { h in
                guard let fraction = progress.feed(h.availableData) else { return }
                Task { @MainActor in
                    if case .running = job.state {
                        job.state = .running(fraction)
                        job.elapsed = Date().timeIntervalSince(started)
                    }
                }
            }

            let launched: Error? = await MainActor.run {
                guard job.state != .cancelled else { return CancellationError() }
                do { try process.run(); job.process = process; return nil } catch { return error }
            }
            if launched == nil { process.waitUntilExit() }
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil

            let status = process.terminationStatus
            let downloaded = Self.downloadedFile(staging: staging, pathFile: pathFile)
            let errorLine = errors.lastLine

            await MainActor.run {
                job.process = nil
                job.elapsed = Date().timeIntervalSince(started)

                if job.state == .cancelled {
                    Self.remove(staging)
                    job.staging = nil
                    self.finished(job)
                    return
                }
                if let launched {
                    Self.remove(staging)
                    job.staging = nil
                    job.state = .failed(launched.localizedDescription)
                    self.finished(job)
                    return
                }
                guard status == 0, let downloaded else {
                    Self.remove(staging)
                    job.staging = nil
                    job.state = .failed(errorLine ?? "yt-dlp exited with status \(status)")
                    self.finished(job)
                    return
                }

                job.title = downloaded.deletingPathExtension().lastPathComponent
                job.inputFile = downloaded
                job.output = self.outputURL(base: job.title, folder: self.linkFolder,
                                            ext: job.format.ext, avoiding: self.claimedOutputs())
                job.phase = .converting
                job.state = .running(nil)
                self.runConversion(job, input: downloaded, ffmpeg: ffmpeg, started: started)
            }
        }
    }

    private func downloadArguments(job: Job, link: URL, staging: URL,
                                   pathFile: URL, ffmpeg: FFmpeg) -> [String] {
        var args = [
            "--no-playlist",
            "--newline",
            "--no-warnings",
            "--no-mtime",
            "--no-write-info-json",
            "--no-write-thumbnail",
            "--no-write-description",
            "--no-write-playlist-metafiles",
            "--progress",
            "--ffmpeg-location", ffmpeg.ffmpeg.deletingLastPathComponent().path,
            "--print-to-file", "after_move:filepath", pathFile.path,
            "-o", staging.appendingPathComponent("%(title)s.%(ext)s").path,
        ]
        if job.format.kind == .audio {
            args += ["-f", "ba/b"]
        } else {
            var selector = "bv*+ba/b"
            if job.options.resolution != .original {
                let height = job.options.resolution.rawValue
                selector = "bv*[height<=\(height)]+ba/b[height<=\(height)]/bv*+ba/b"
            }
            args += ["-f", selector, "--merge-output-format", "mkv"]
        }
        args.append(link.absoluteString)
        return args
    }

    private func runConversion(_ job: Job, input: URL, ffmpeg: FFmpeg, started: Date) {
        guard let output = job.output else {
            job.state = .failed("No output path was chosen")
            finished(job)
            return
        }
        let args = job.format.arguments(input: input.path, output: output.path, options: job.options)
        let remux = job.options.remux
        let canRemux = job.format.canRemux
        let ext = job.format.ext
        let staging = job.staging

        Task.detached(priority: .userInitiated) { [self] in
            let duration = ffmpeg.duration(of: input)
            let process = Process()
            process.executableURL = ffmpeg.ffmpeg
            process.arguments = args
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
                    if case .running = job.state {
                        job.state = .running(fraction)
                        job.elapsed = Date().timeIntervalSince(started)
                    }
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
                    try? FileManager.default.removeItem(at: output)
                    Self.remove(staging)
                    job.staging = nil
                } else if let launched {
                    Self.remove(staging)
                    job.staging = nil
                    job.state = .failed(launched.localizedDescription)
                } else if process.terminationStatus == 0 {
                    Self.remove(staging)
                    job.staging = nil
                    job.state = .done
                } else {
                    try? FileManager.default.removeItem(at: output)
                    Self.remove(staging)
                    job.staging = nil
                    job.state = .failed(remux && canRemux
                        ? "These streams can't be copied into .\(ext). Turn off “Copy streams” to re-encode."
                        : errors.lastLine ?? "ffmpeg exited with status \(process.terminationStatus)")
                }
                self.finished(job)
            }
        }
    }

    private func finished(_ job: Job) {
        current = nil
        if job.state == .done, settings.revealWhenDone, activeCount == 0, let output = job.output {
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
        startNext()
    }

    // MARK: - Temporary files

    nonisolated private static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The path yt-dlp wrote after moving the file, or the largest media file
    /// left in the staging folder if that file is missing.
    nonisolated private static func downloadedFile(staging: URL, pathFile: URL) -> URL? {
        let fm = FileManager.default
        let stagingPath = staging.standardizedFileURL.path
        if let text = try? String(contentsOf: pathFile, encoding: .utf8) {
            let lines = text.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let last = lines.last(where: { !$0.isEmpty }) {
                let url = URL(fileURLWithPath: last).standardizedFileURL
                if url.path.hasPrefix(stagingPath + "/"), fm.fileExists(atPath: url.path) {
                    return url
                }
            }
        }

        guard let names = try? fm.contentsOfDirectory(atPath: staging.path) else { return nil }
        let ignored: Set<String> = ["txt", "part", "ytdl", "json", "jpg", "jpeg", "png", "webp", "vtt", "srt", "ass"]
        let candidates: [URL] = names.compactMap { name in
            let url = staging.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard !name.hasPrefix("."),
                  !ignored.contains(url.pathExtension.lowercased()),
                  fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            return url
        }
        return candidates.max { a, b in
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sa < sb
        }
    }

    /// Removes staging folders left behind by an earlier crash or quit.
    nonisolated private static func removeStaleStaging() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for name in names where name.hasPrefix("DropConvert-") {
            let url = tmp.appendingPathComponent(name, isDirectory: true)
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, date < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
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

/// Reads yt-dlp's `[download] xx.x%` lines.
private final class DownloadProgressParser: @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()

    func feed(_ data: Data) -> Double? {
        lock.lock(); defer { lock.unlock() }
        buffer += String(decoding: data, as: UTF8.self)
        var latest: Double?
        while let idx = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = buffer[..<idx]
            buffer.removeSubrange(...idx)
            if let fraction = Self.fraction(in: line) { latest = fraction }
        }
        return latest
    }

    private static func fraction(in line: Substring) -> Double? {
        guard line.hasPrefix("[download]") else { return nil }
        for token in line.split(separator: " ") where token.hasSuffix("%") {
            if let value = Double(token.dropLast()) {
                return min(max(value / 100, 0), 1)
            }
        }
        return nil
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
