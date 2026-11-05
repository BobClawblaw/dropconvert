import AppKit
import Combine
import DropConvertCore
import Foundation
import UniformTypeIdentifiers

private struct FFmpegResult {
    var launchError: String?
    var status: Int32
    var stderr: String
    var cancelled: Bool
}

/// Runs jobs one at a time, in the order they were added.
@MainActor
final class ConversionQueue: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var ffmpeg: FFmpeg?
    @Published private(set) var downloader: Downloader?
    @Published private(set) var isLocating = true
    @Published private(set) var isPaused = false
    @Published private(set) var isUpdatingDownloader = false
    @Published private(set) var downloaderUpdateMessage: String?
    let settings: Settings

    private var current: Job?
    private let store = QueueStore()
    private var pendingRecords: [JobRecord] = []
    private var deferredFiles: [URL] = []
    private var deferredLinks: [URL] = []
    private var restored = false
    private var jobObservers: [UUID: AnyCancellable] = [:]

    init(settings: Settings) {
        self.settings = settings
        self.pendingRecords = store.load()
        Self.removeStaleStaging()
        Task { await locateTools() }
    }

    var availableFormats: [OutputFormat] {
        guard let ffmpeg else { return [] }
        return OutputFormat.all.filter { $0.isAvailable(ffmpeg.encoders) }
    }

    var activeCount: Int { jobs.filter { !$0.state.isFinished }.count }

    var statusText: String {
        if isLocating { return "Looking for ffmpeg and yt-dlp…" }
        if isPaused { return "Queue paused" }
        if let current {
            if case .running(let fraction) = current.state {
                return fraction.map { "\(Int($0 * 100))% · \(current.title)" }
                    ?? "Working · \(current.title)"
            }
        }
        if activeCount > 0 { return "\(activeCount) queued" }
        return "DropConvert"
    }

    func relocate() {
        isLocating = true
        Task { await locateTools() }
    }

    private func locateTools() async {
        let result = await Task.detached(priority: .userInitiated) {
            (FFmpeg.locate(), Downloader.locate())
        }.value
        ffmpeg = result.0
        downloader = result.1
        isLocating = false
        Log.tools.info("ffmpeg=\(result.0?.ffmpeg.path ?? "missing", privacy: .public) yt-dlp=\(result.1?.ytDlp.path ?? "missing", privacy: .public)")
        restorePending()
        if ffmpeg != nil, !deferredFiles.isEmpty {
            let files = deferredFiles
            deferredFiles = []
            add(files)
        }
        if downloader != nil, !deferredLinks.isEmpty {
            let links = deferredLinks
            deferredLinks = []
            addLinks(links)
        }
        startNext()
        updateBadge()
    }

    // MARK: - Queue changes

    func add(_ urls: [URL]) {
        guard ffmpeg != nil else {
            deferredFiles += urls
            return
        }
        let files = MediaFiles.expand(urls)
        guard !files.isEmpty, let format = selectedFormat(), let options = makeOptions() else { return }
        var claimed = claimedOutputs()
        for url in files {
            let folder = destinationFolder(for: url)
            let output = OutputNamer.uniqueOutput(input: url, ext: format.ext, folder: folder,
                                                  avoiding: claimed)
            claimed.insert(output.standardizedFileURL.path)
            let job = Job(source: .file(url), title: url.lastPathComponent, output: output,
                          format: format, options: options, phase: .converting)
            jobs.append(job)
            observe(job)
        }
        save()
        startNext()
    }

    func addLinks(_ urls: [URL]) {
        guard downloader != nil else {
            deferredLinks += urls
            return
        }
        guard let format = selectedFormat(), let options = makeOptions() else { return }
        for url in urls {
            let source = MediaSource.link(url)
            let job = Job(source: source, title: source.displayName, output: nil,
                          format: format, options: options, phase: .downloading)
            jobs.append(job)
            observe(job)
        }
        save()
        startNext()
    }

    func cancel(_ job: Job) {
        if job.state == .queued {
            job.state = .cancelled
        } else if case .running = job.state {
            job.state = .cancelled
            if let process = job.process {
                if job.phase == .downloading {
                    ProcessTree.interrupt(process)
                } else {
                    ProcessTree.terminate(process)
                }
            }
        }
        save()
        updateBadge()
    }

    func cancelAll() {
        jobs.forEach(cancel)
    }

    func clearFinished() {
        for job in jobs where job.state.isFinished { unobserve(job) }
        jobs.removeAll { $0.state.isFinished }
        save()
        updateBadge()
    }

    func retry(_ job: Job) {
        guard job.state.isFinished, job.state != .done,
              let index = jobs.firstIndex(where: { $0 === job }) else { return }
        let output: URL?
        if job.isRemote {
            output = nil
        } else {
            let input = job.source.url
            output = OutputNamer.uniqueOutput(input: input, ext: job.format.ext,
                                              folder: destinationFolder(for: input),
                                              avoiding: claimedOutputs())
        }
        let again = Job(source: job.source,
                        title: job.isRemote ? job.source.displayName : job.title,
                        output: output,
                        format: job.format,
                        options: job.options,
                        phase: job.isRemote ? .downloading : .converting)
        unobserve(job)
        jobs[index] = again
        observe(again)
        save()
        startNext()
    }

    func remove(_ job: Job) {
        if case .running = job.state { cancel(job) }
        jobs.removeAll { $0 === job }
        unobserve(job)
        save()
        startNext()
        updateBadge()
    }

    func move(_ job: Job, by offset: Int) {
        guard let index = jobs.firstIndex(where: { $0 === job }) else { return }
        let target = index + offset
        guard target >= 0, target < jobs.count else { return }
        jobs.swapAt(index, target)
        save()
    }

    func changeFormat(_ job: Job, id: String) {
        guard let format = availableFormats.first(where: { $0.id == id }),
              let ffmpeg else { return }
        if case .running = job.state { return }
        job.format = format
        job.options = EncodeOptions(quality: settings.quality, resolution: settings.resolution,
                                    hardware: settings.hardware, remux: settings.remux,
                                    encoders: ffmpeg.encoders)
        if job.isRemote {
            job.output = nil
            job.phase = .downloading
        } else {
            let input = job.source.url
            job.output = OutputNamer.uniqueOutput(input: input, ext: format.ext,
                                                  folder: destinationFolder(for: input),
                                                  avoiding: claimedOutputs())
            job.phase = .converting
        }
        if job.state.isFinished {
            job.state = .queued
            job.errorDetails = nil
            job.note = nil
        }
        save()
        startNext()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused { startNext() }
        updateBadge()
    }

    func shutdown() {
        for job in jobs {
            if case .running = job.state {
                job.state = .cancelled
                if let process = job.process { ProcessTree.terminate(process) }
            } else if job.state == .queued {
                job.state = .cancelled
            }
        }
        current = nil
        for job in jobs { cleanupStaging(job) }
        save()
        updateBadge()
    }

    func updateDownloader() {
        guard let downloader, !isUpdatingDownloader else { return }
        isUpdatingDownloader = true
        downloaderUpdateMessage = "Updating yt-dlp…"
        Task.detached(priority: .userInitiated) { [downloader] in
            let result = downloader.update()
            await MainActor.run {
                self.isUpdatingDownloader = false
                self.downloaderUpdateMessage = result.message
                if result.succeeded { self.relocate() }
            }
        }
    }

    // MARK: - Naming

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
        Set(jobs.filter { !$0.state.isFinished }.compactMap { $0.output?.standardizedFileURL.path })
    }

    private func destinationFolder(for input: URL) -> URL {
        if let folder = settings.outputFolder, isWritableDirectory(folder) { return folder }
        let beside = input.deletingLastPathComponent()
        if isWritableDirectory(beside) { return beside }
        return downloadsFolder
    }

    private var linkFolder: URL {
        if let folder = settings.outputFolder, isWritableDirectory(folder) { return folder }
        return downloadsFolder
    }

    private var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func isWritableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue && fm.isWritableFile(atPath: url.path)
    }

    // MARK: - Running jobs

    private func startNext() {
        guard !isPaused, current == nil, let ffmpeg,
              let job = jobs.first(where: { $0.state == .queued }) else {
            updateBadge()
            return
        }
        current = job
        job.state = .running(nil)
        job.detail = nil
        job.errorDetails = nil
        job.elapsed = 0
        let started = Date()

        switch job.source {
        case .file(let input):
            guard FileManager.default.fileExists(atPath: input.path) else {
                job.state = .failed("The source file is missing.")
                finished(job)
                return
            }
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
        let staging = fm.temporaryDirectory.appendingPathComponent("DropConvert-\(job.id.uuidString)",
                                                                   isDirectory: true)
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
        let environment = FFmpeg.environment(adding: [ffmpeg.ffmpeg.deletingLastPathComponent()])
        Log.jobs.info("Downloading \(link.absoluteString, privacy: .public)")

        Task.detached(priority: .userInitiated) { [self] in
            let process = Process()
            process.executableURL = ytDlp
            process.arguments = arguments
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let errors = ErrorTail()
            err.fileHandleForReading.readabilityHandler = { handle in
                errors.append(handle.availableData)
            }
            let progress = DownloadProgressParser()
            out.fileHandleForReading.readabilityHandler = { handle in
                guard let update = progress.feed(handle.availableData) else { return }
                Task { @MainActor in
                    guard case .running = job.state else { return }
                    if let fraction = update.fraction { job.state = .running(fraction) }
                    job.detail = Self.downloadDetail(update)
                    job.elapsed = Date().timeIntervalSince(started)
                    self.updateBadge()
                }
            }

            let cancelledBefore = await MainActor.run { job.state == .cancelled }
            var launchError: String?
            if !cancelledBefore {
                launchError = await MainActor.run {
                    do {
                        try process.run()
                        job.process = process
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
                if launchError == nil { process.waitUntilExit() }
            }

            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let status = process.terminationStatus
            let stderr = errors.text
            let paths = Self.downloadedFiles(staging: staging, pathFile: pathFile)
            let finalLaunchError = launchError

            await MainActor.run {
                job.process = nil
                job.elapsed = Date().timeIntervalSince(started)

                if cancelledBefore || job.state == .cancelled {
                    Self.remove(staging)
                    job.staging = nil
                    self.finished(job)
                    return
                }
                if let finalLaunchError {
                    Self.remove(staging)
                    job.staging = nil
                    job.state = .failed(finalLaunchError)
                    job.errorDetails = stderr.isEmpty ? finalLaunchError : stderr
                    self.finished(job)
                    return
                }
                guard status == 0, !paths.isEmpty else {
                    let fallback = errors.lastLine ?? "yt-dlp exited with status \(status)"
                    let message = ErrorHints.message(for: stderr) ?? fallback
                    Self.remove(staging)
                    job.staging = nil
                    job.state = .failed(message)
                    job.errorDetails = stderr.isEmpty ? message : stderr
                    self.finished(job)
                    return
                }

                if paths.count > 1 {
                    self.finishPlaylist(job, paths: paths, staging: staging)
                    return
                }

                let downloaded = paths[0]
                job.title = downloaded.deletingPathExtension().lastPathComponent
                job.inputFile = downloaded
                job.output = OutputNamer.uniqueOutput(
                    base: job.title, folder: self.linkFolder, ext: job.format.ext,
                    avoiding: self.claimedOutputs())
                job.phase = .converting
                job.state = .running(nil)
                job.detail = "Converting…"
                self.runConversion(job, input: downloaded, ffmpeg: ffmpeg, started: started)
            }
        }
    }

    private func finishPlaylist(_ job: Job, paths: [URL], staging: URL) {
        job.title = "Playlist · \(paths.count) items"
        job.output = nil
        job.phase = .converting
        job.note = "Queued \(paths.count) conversions"
        job.state = .done
        var claimed = claimedOutputs()
        for path in paths {
            let title = path.deletingPathExtension().lastPathComponent
            let output = OutputNamer.uniqueOutput(base: title, folder: linkFolder,
                                                  ext: job.format.ext, avoiding: claimed)
            claimed.insert(output.standardizedFileURL.path)
            let child = Job(source: .file(path), title: title, output: output,
                            format: job.format, options: job.options, phase: .converting)
            child.staging = staging
            jobs.append(child)
            observe(child)
        }
        job.staging = staging
        save()
        finished(job)
    }

    private func downloadArguments(job: Job, link: URL, staging: URL,
                                   pathFile: URL, ffmpeg: FFmpeg) -> [String] {
        var args = [
            "--no-warnings",
            "--no-mtime",
            "--no-write-info-json",
            "--no-write-thumbnail",
            "--no-write-description",
            "--no-write-playlist-metafiles",
            "--progress",
            "--newline",
            "--ffmpeg-location", ffmpeg.ffmpeg.deletingLastPathComponent().path,
            "--print-to-file", "after_move:filepath", pathFile.path,
            "-o", staging.appendingPathComponent("%(title)s.%(ext)s").path,
        ]
        args += settings.downloadPlaylists ? ["--yes-playlist"] : ["--no-playlist"]
        if let browser = settings.cookiesBrowser.argument {
            args += ["--cookies-from-browser", browser]
        }
        if settings.embedSubtitles && job.format.kind == .video {
            args += ["--write-subs", "--sub-langs", "en.*", "--embed-subs"]
        }
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

        let folder = output.deletingLastPathComponent()
        guard isWritableDirectory(folder) else {
            job.state = .failed("Can't write to \(folder.lastPathComponent). Choose another folder in the gear menu.")
            finished(job)
            return
        }
        if let size = Self.fileSize(input),
           let capacity = Self.availableCapacity(folder),
           capacity < Int64(Double(size) * 1.1) {
            job.state = .failed("Not enough free space for \(output.lastPathComponent).")
            finished(job)
            return
        }
        if job.format.kind == .audio, ffmpeg.ffprobe != nil,
           !ffmpeg.hasAudioStream(of: input) {
            job.state = .failed("This file has no audio track to convert.")
            finished(job)
            return
        }
        if job.format.kind == .video, ffmpeg.ffprobe != nil,
           !ffmpeg.hasVideoStream(of: input) {
            job.state = .failed("This file has no video track to convert.")
            finished(job)
            return
        }

        let format = job.format
        let options = job.options
        let staging = job.staging
        let environment = FFmpeg.environment(adding: [ffmpeg.ffmpeg.deletingLastPathComponent()])

        if format.engine == .imageIO {
            runImageConversion(job, input: input, output: output, format: format,
                               options: options, staging: staging, ffmpeg: ffmpeg,
                               environment: environment, started: started)
            return
        }

        job.detail = "Converting…"
        Task.detached(priority: .userInitiated) { [self] in
            let duration = ffmpeg.duration(of: input)
            var result = await Self.runFFmpeg(job: job, input: input, output: output,
                                              format: format, options: options,
                                              ffmpeg: ffmpeg, environment: environment,
                                              duration: duration, started: started, queue: self)
            if !result.cancelled, result.launchError == nil, result.status != 0,
               options.remux, format.canRemux {
                await MainActor.run {
                    job.note = "Streams didn't fit the container; re-encoded instead."
                }
                try? FileManager.default.removeItem(at: output)
                result = await Self.runFFmpeg(job: job, input: input, output: output,
                                              format: format, options: options,
                                              ffmpeg: ffmpeg, environment: environment,
                                              duration: duration, started: started, queue: self,
                                              remux: false)
            }

            let finalResult = result
            await MainActor.run {
                let cancelled = job.state == .cancelled
                job.process = nil
                job.elapsed = Date().timeIntervalSince(started)
                if cancelled || finalResult.cancelled {
                    try? FileManager.default.removeItem(at: output)
                    self.cleanupStaging(job)
                    self.finished(job)
                    return
                }
                if let launchError = finalResult.launchError {
                    self.cleanupStaging(job)
                    job.state = .failed(launchError)
                    job.errorDetails = finalResult.stderr.isEmpty ? launchError : finalResult.stderr
                    self.finished(job)
                    return
                }
                if finalResult.status == 0 {
                    self.cleanupStaging(job)
                    job.state = .done
                    job.detail = nil
                    self.finished(job)
                } else {
                    try? FileManager.default.removeItem(at: output)
                    let fallback = Self.lastMeaningfulLine(finalResult.stderr)
                        ?? "ffmpeg exited with status \(finalResult.status)"
                    let message = ErrorHints.message(for: finalResult.stderr) ?? fallback
                    self.cleanupStaging(job)
                    job.state = .failed(message)
                    job.errorDetails = finalResult.stderr.isEmpty ? message : finalResult.stderr
                    self.finished(job)
                }
            }
        }
    }

    private func runImageConversion(_ job: Job, input: URL, output: URL, format: OutputFormat,
                                    options: EncodeOptions, staging: URL?, ffmpeg: FFmpeg,
                                    environment: [String: String], started: Date) {
        let frameDirectory: URL
        if let staging {
            frameDirectory = staging
        } else {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("DropConvert-\(job.id.uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            job.staging = temp
            frameDirectory = temp
        }
        let frame = frameDirectory.appendingPathComponent("frame-\(job.id.uuidString).png")
        job.detail = "Rendering \(format.name)…"

        Task.detached(priority: .userInitiated) { [self] in
            var failure: String?
            if Self.isImage(input) {
                do {
                    try NativeImage.convert(input: input, output: output, format: format,
                                            resolution: options.resolution,
                                            quality: options.quality)
                } catch {
                    failure = error.localizedDescription
                }
            } else {
                let args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                            "-i", input.path, "-frames:v", "1", "-f", "image2", frame.path]
                let extracted = ProcessRunner.run(ffmpeg.ffmpeg, args,
                                                  environment: environment, timeout: 120)
                if extracted?.succeeded == true {
                    do {
                        try NativeImage.convert(input: frame, output: output, format: format,
                                                resolution: options.resolution,
                                                quality: options.quality)
                    } catch {
                        failure = error.localizedDescription
                    }
                } else {
                    let text = extracted?.stderr ?? ""
                    failure = ErrorHints.message(for: text) ?? "Couldn't extract a frame from the video."
                }
            }

            let finalFailure = failure
            await MainActor.run {
                job.elapsed = Date().timeIntervalSince(started)
                if job.state == .cancelled {
                    try? FileManager.default.removeItem(at: output)
                    self.cleanupStaging(job)
                    self.finished(job)
                    return
                }
                if let finalFailure {
                    try? FileManager.default.removeItem(at: output)
                    job.state = .failed(finalFailure)
                    job.errorDetails = finalFailure
                } else {
                    job.state = .done
                    job.detail = nil
                }
                self.cleanupStaging(job)
                self.finished(job)
            }
        }
    }

    nonisolated private static func runFFmpeg(job: Job, input: URL, output: URL,
                                              format: OutputFormat, options: EncodeOptions,
                                              ffmpeg: FFmpeg, environment: [String: String],
                                              duration: Double?, started: Date,
                                              queue: ConversionQueue,
                                              remux: Bool? = nil) async -> FFmpegResult {
        var runOptions = options
        if let remux { runOptions.remux = remux }
        let args = format.arguments(input: input.path, output: output.path, options: runOptions)

        let process = Process()
        process.executableURL = ffmpeg.ffmpeg
        process.arguments = args
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let errors = ErrorTail()
        err.fileHandleForReading.readabilityHandler = { handle in
            errors.append(handle.availableData)
        }
        let progress = FFmpegProgressParser()
        out.fileHandleForReading.readabilityHandler = { handle in
            guard let update = progress.feed(handle.availableData) else { return }
            Task { @MainActor in
                guard case .running = job.state else { return }
                if let seconds = update.seconds, let duration, duration > 0 {
                    let fraction = min(max(seconds / duration, 0), 1)
                    job.state = .running(fraction)
                    job.detail = Self.conversionDetail(fraction: fraction, speed: update.speed,
                                                       elapsed: Date().timeIntervalSince(started))
                } else {
                    job.detail = Self.conversionDetail(fraction: nil, speed: update.speed,
                                                       elapsed: Date().timeIntervalSince(started))
                }
                job.elapsed = Date().timeIntervalSince(started)
                queue.updateBadge()
            }
        }

        let cancelledBefore = await MainActor.run { job.state == .cancelled }
        if cancelledBefore { return FFmpegResult(launchError: nil, status: 0, stderr: "", cancelled: true) }

        let launchError: String? = await MainActor.run {
            do {
                try process.run()
                job.process = process
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if launchError == nil { process.waitUntilExit() }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let status = process.terminationStatus
        let stderr = errors.text
        let cancelled = await MainActor.run {
            job.process = nil
            return job.state == .cancelled
        }
        return FFmpegResult(launchError: launchError, status: status, stderr: stderr,
                            cancelled: cancelled)
    }

    private func finished(_ job: Job) {
        current = nil
        if job.state == .done, settings.revealWhenDone, activeCount == 0, let output = job.output {
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
        save()
        updateBadge()
        startNext()
    }

    private func updateBadge() {
        let active = jobs.filter { !$0.state.isFinished }
        guard !active.isEmpty else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        if let running = jobs.first(where: {
            if case .running = $0.state { return true }
            return false
        }), case .running(let fraction) = running.state, let fraction {
            NSApp.dockTile.badgeLabel = "\(Int(fraction * 100))%"
        } else {
            NSApp.dockTile.badgeLabel = "…"
        }
    }

    // MARK: - Persistence

    private func observe(_ job: Job) {
        guard jobObservers[job.id] == nil else { return }
        jobObservers[job.id] = job.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    private func unobserve(_ job: Job) {
        jobObservers[job.id] = nil
    }

    private func restorePending() {
        guard !restored else { return }
        if pendingRecords.isEmpty {
            restored = true
            save()
            return
        }
        guard let ffmpeg else { return }
        let encoders = ffmpeg.encoders
        for record in pendingRecords {
            let stored = OutputFormat.all.first(where: { $0.id == record.formatID })
            let format = stored?.isAvailable(encoders) == true ? stored : selectedFormat()
            guard let format else { continue }
            let options = EncodeOptions(
                quality: Quality(rawValue: record.quality) ?? .medium,
                resolution: Resolution(rawValue: record.resolution) ?? .original,
                hardware: record.hardware,
                remux: record.remux,
                encoders: encoders)
            let output = record.source.isLink ? nil
                : record.outputPath.map { URL(fileURLWithPath: $0) }
            let job = Job(source: record.source, title: record.title, output: output,
                          format: format, options: options,
                          phase: record.phase == "downloading" ? .downloading : .converting)
            switch record.state {
            case "failed": job.state = .failed(record.error ?? "Failed")
            case "cancelled": job.state = .cancelled
            default: job.state = .queued
            }
            job.note = record.note
            job.errorDetails = record.error
            if case .file(let url) = record.source,
               !FileManager.default.fileExists(atPath: url.path) {
                job.state = .failed("The source file is missing.")
            }
            jobs.append(job)
            observe(job)
        }
        pendingRecords = []
        restored = true
        save()
    }

    private func save() {
        guard restored else { return }
        let records = jobs.filter { $0.state != .done }.map { record(for: $0) }
        store.save(records)
    }

    private func record(for job: Job) -> JobRecord {
        let state: String
        let error: String?
        switch job.state {
        case .queued, .running: state = "queued"; error = nil
        case .failed(let message): state = "failed"; error = message
        case .cancelled: state = "cancelled"; error = nil
        case .done: state = "done"; error = nil
        }
        return JobRecord(
            id: job.id,
            source: job.source,
            formatID: job.format.id,
            quality: job.options.quality.rawValue,
            resolution: job.options.resolution.rawValue,
            hardware: job.options.hardware,
            remux: job.options.remux,
            title: job.title,
            outputPath: job.output?.path,
            state: state,
            error: error,
            note: job.note,
            phase: job.phase == .downloading ? "downloading" : "converting")
    }

    // MARK: - Temporary files

    private func cleanupStaging(_ job: Job) {
        guard let staging = job.staging else { return }
        job.staging = nil
        let inUse = jobs.contains {
            $0 !== job && $0.staging == staging && !$0.state.isFinished
        }
        if !inUse { try? FileManager.default.removeItem(at: staging) }
    }

    nonisolated private static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The paths yt-dlp wrote after moving files, or the media files left in
    /// the staging folder when the path file is missing.
    nonisolated private static func downloadedFiles(staging: URL, pathFile: URL) -> [URL] {
        let fm = FileManager.default
        let stagingPath = staging.standardizedFileURL.path
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(stagingPath + "/"),
                  fm.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted else { return }
            result.append(standardized)
        }

        if let text = try? String(contentsOf: pathFile, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { continue }
                append(URL(fileURLWithPath: path))
            }
        }

        if result.isEmpty, let names = try? fm.contentsOfDirectory(atPath: staging.path) {
            for name in names {
                let url = staging.appendingPathComponent(name)
                guard MediaFiles.isMedia(url) else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                append(url)
            }
        }
        return result
    }

    /// Removes staging folders left behind by an earlier crash or quit.
    nonisolated private static func removeStaleStaging() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix("DropConvert-") {
            try? fm.removeItem(at: tmp.appendingPathComponent(name, isDirectory: true))
        }
    }

    // MARK: - Helpers

    nonisolated private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return Int64(size)
    }

    nonisolated private static func availableCapacity(_ folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    nonisolated private static func lastMeaningfulLine(_ text: String) -> String? {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
    }

    nonisolated private static func downloadDetail(_ update: DownloadProgress) -> String {
        var parts = ["Downloading"]
        if let fraction = update.fraction { parts[0] += " \(Int(fraction * 100))%" }
        if let speed = update.speed { parts.append(speed) }
        if let eta = update.eta { parts.append("ETA \(eta)") }
        return parts.joined(separator: " · ")
    }

    nonisolated private static func conversionDetail(fraction: Double?, speed: String?,
                                                     elapsed: TimeInterval) -> String {
        var parts = ["Converting"]
        if let fraction { parts[0] += " \(Int(fraction * 100))%" }
        if let speed { parts.append(speed) }
        parts.append(Self.time(elapsed))
        return parts.joined(separator: " · ")
    }

    nonisolated private static func time(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        return seconds < 60 ? "\(seconds)s" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
