import AppKit
import Combine
import DropConvertCore
import Foundation
import UniformTypeIdentifiers
import UserNotifications

private struct FFmpegResult {
    var launchError: String?
    var status: Int32
    var stderr: String
    var cancelled: Bool
}

/// Runs jobs in the order they were added, up to `settings.maxConcurrentJobs` at once.
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

    private var runningJobs: [Job] = []
    private let store = QueueStore()
    private var pendingRecords: [JobRecord] = []
    private var deferredFiles: [URL] = []
    private var deferredLinks: [URL] = []
    private var restored = false
    private var jobObservers: [UUID: AnyCancellable] = [:]
    private var settingsObserver: AnyCancellable?
    private var sleepActivity: NSObjectProtocol?
    private var batchCompletedOutputs: [URL] = []
    private var batchDoneCount = 0
    private var batchFailedCount = 0
    private var notificationPermissionRequested = false

    init(settings: Settings) {
        self.settings = settings
        self.pendingRecords = store.load()
        let protected = Self.referencedStagingNames(in: pendingRecords)
        Self.removeStaleStaging(keeping: protected)
        settingsObserver = settings.$maxConcurrentJobs
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.startNext() }
            }
        Task { await locateTools() }
    }

    var availableFormats: [OutputFormat] {
        guard let ffmpeg else { return [] }
        return OutputFormat.all.filter { $0.isAvailable(ffmpeg.encoders) }
    }

    var activeCount: Int { jobs.filter { !$0.state.isFinished }.count }

    var failedCount: Int {
        jobs.filter {
            if case .failed = $0.state { return true }
            return false
        }.count
    }

    var statusText: String {
        if isLocating { return "Looking for ffmpeg and yt-dlp…" }
        if isPaused { return "Queue paused" }
        if runningJobs.count > 1 {
            return "Working on \(runningJobs.count) items (\(activeCount) remaining)"
        }
        if let current = runningJobs.first {
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
        guard let format = selectedFormat(), let options = makeOptions() else { return }
        settings.recordFormatUse(format.id)
        let outputUnavailable = settings.outputFolderIsUnavailable
        let chosenFolderName = settings.outputFolder?.lastPathComponent

        Task {
            let sized: [(URL, Int64?)] = await Task.detached(priority: .userInitiated) {
                MediaFiles.expand(urls).map { ($0, Self.fileSize($0)) }
            }.value
            guard !sized.isEmpty else { return }
            var claimed = self.claimedOutputs()
            for (url, sizeBytes) in sized {
                let folder = self.destinationFolder(for: url)
                let output = OutputNamer.uniqueOutput(input: url, ext: format.ext, folder: folder,
                                                      avoiding: claimed)
                claimed.insert(output.standardizedFileURL.path)
                let job = Job(source: .file(url), title: url.lastPathComponent, output: output,
                              format: format, options: options, phase: .converting)
                job.inputSizeBytes = sizeBytes
                if outputUnavailable, let chosenFolderName {
                    job.appendNote("Output folder “\(chosenFolderName)” is unavailable; saving to \(folder.lastPathComponent).")
                }
                self.jobs.append(job)
                self.observe(job)
            }
            self.save()
            self.startNext()
        }
    }

    func addLinks(_ urls: [URL]) {
        guard downloader != nil else {
            deferredLinks += urls
            return
        }
        guard let format = selectedFormat(), let options = makeOptions() else { return }
        settings.recordFormatUse(format.id)
        let outputUnavailable = settings.outputFolderIsUnavailable
        let chosenFolderName = settings.outputFolder?.lastPathComponent
        for url in urls {
            let source = MediaSource.link(url)
            let job = Job(source: source, title: source.displayName, output: nil,
                          format: format, options: options, phase: .downloading)
            if outputUnavailable, let chosenFolderName {
                job.appendNote("Output folder “\(chosenFolderName)” is unavailable; saving to \(linkFolder.lastPathComponent).")
            }
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
        again.inputSizeBytes = job.inputSizeBytes
        again.staging = job.staging
        unobserve(job)
        jobs[index] = again
        observe(again)
        save()
        startNext()
    }

    func retryAllFailed() {
        let failed = jobs.filter {
            if case .failed = $0.state { return true }
            return false
        }
        for job in failed { retry(job) }
    }

    func remove(_ job: Job) {
        if case .running = job.state { cancel(job) }
        jobs.removeAll { $0 === job }
        runningJobs.removeAll { $0 === job }
        unobserve(job)
        cleanupStaging(job)
        save()
        startNext()
        updateBadge()
        updateSleepAssertion()
    }

    func move(_ job: Job, by offset: Int) {
        guard let index = jobs.firstIndex(where: { $0 === job }) else { return }
        let target = index + offset
        guard target >= 0, target < jobs.count else { return }
        jobs.swapAt(index, target)
        save()
    }

    func move(fromID: UUID, toID: UUID) {
        guard fromID != toID,
              let fromIndex = jobs.firstIndex(where: { $0.id == fromID }),
              let toIndex = jobs.firstIndex(where: { $0.id == toID }) else { return }
        let job = jobs.remove(at: fromIndex)
        jobs.insert(job, at: toIndex)
        save()
    }

    func changeFormat(_ job: Job, id: String) {
        guard let format = availableFormats.first(where: { $0.id == id }),
              let ffmpeg else { return }
        if case .running = job.state { return }
        settings.recordFormatUse(format.id)
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
            job.outputSizeBytes = nil
        }
        save()
        startNext()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused { startNext() }
        updateBadge()
        updateSleepAssertion()
    }

    func shutdown() {
        // Persist unfinished jobs as "queued" BEFORE cancelling live processes,
        // so normal quit restores and resumes them on the next launch.
        save()

        // Keep staging folders that belong to queued/running playlist children
        // whose source files live in staging, so they can still convert on relaunch.
        let protectedStaging = Set(
            jobs.compactMap { job -> URL? in
                guard !job.state.isFinished, case .file(let url) = job.source else { return nil }
                guard let staging = job.staging,
                      url.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/")
                else { return nil }
                return staging.standardizedFileURL
            }
        )

        for job in jobs {
            if case .running = job.state {
                job.state = .cancelled
                if let process = job.process { ProcessTree.terminate(process, wait: true) }
            } else if job.state == .queued {
                job.state = .cancelled
            }
        }
        runningJobs.removeAll()
        for job in jobs {
            if let staging = job.staging?.standardizedFileURL, protectedStaging.contains(staging) {
                continue
            }
            cleanupStaging(job)
        }
        endSleepAssertion()
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
        guard !isPaused, let ffmpeg else {
            updateBadge()
            updateSleepAssertion()
            return
        }
        let limit = max(1, settings.maxConcurrentJobs)
        while runningJobs.count < limit,
              let job = jobs.first(where: { $0.state == .queued }) {
            if runningJobs.isEmpty {
                batchCompletedOutputs = []
                batchDoneCount = 0
                batchFailedCount = 0
                requestNotificationPermissionIfNeeded()
            }
            runningJobs.append(job)
            job.state = .running(nil)
            job.detail = nil
            job.errorDetails = nil
            job.outputSizeBytes = nil
            job.elapsed = 0
            let started = Date()

            switch job.source {
            case .file(let input):
                guard FileManager.default.fileExists(atPath: input.path) else {
                    job.state = .failed("The source file is missing.")
                    finished(job)
                    continue
                }
                if job.inputSizeBytes == nil { job.inputSizeBytes = Self.fileSize(input) }
                job.phase = .converting
                job.inputFile = input
                runConversion(job, input: input, ffmpeg: ffmpeg, started: started)
            case .link(let link):
                job.phase = .downloading
                guard downloader != nil else {
                    job.state = .failed("yt-dlp not found. Install it with Homebrew: brew install yt-dlp")
                    finished(job)
                    continue
                }
                runDownload(job, link: link, ffmpeg: ffmpeg, started: started)
            }
        }
        updateBadge()
        updateSleepAssertion()
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
            let trailingErr = err.fileHandleForReading.readDataToEndOfFile()
            if !trailingErr.isEmpty { errors.append(trailingErr) }
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()

            let status = launchError == nil && !cancelledBefore ? process.terminationStatus : -1
            let stderr = errors.text
            let paths = Self.downloadedFiles(staging: staging, pathFile: pathFile)
            let downloadedSize = paths.first.flatMap(Self.fileSize)
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
                job.inputSizeBytes = downloadedSize
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
        job.appendNote("Queued \(paths.count) conversions")
        job.state = .done
        var claimed = claimedOutputs()
        for path in paths {
            let title = path.deletingPathExtension().lastPathComponent
            let output = OutputNamer.uniqueOutput(base: title, folder: linkFolder,
                                                  ext: job.format.ext, avoiding: claimed)
            claimed.insert(output.standardizedFileURL.path)
            let child = Job(source: .file(path), title: title, output: output,
                            format: job.format, options: job.options, phase: .converting)
            child.inputSizeBytes = Self.fileSize(path)
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
            "--no-write-description",
            "--no-write-playlist-metafiles",
            "--progress",
            "--newline",
            "--ffmpeg-location", ffmpeg.ffmpeg.deletingLastPathComponent().path,
            "--print-to-file", "after_move:filepath", pathFile.path,
            "-o", staging.appendingPathComponent("%(title)s.%(ext)s").path,
        ]
        args += Downloader.metadataArguments
        args += settings.downloadPlaylists ? ["--yes-playlist"] : ["--no-playlist"]
        if let browser = settings.cookiesBrowser.argument {
            args += ["--cookies-from-browser", browser]
        }
        if settings.embedSubtitles && job.format.kind == .video {
            args += ["--write-subs", "--sub-langs", "en.*", "--embed-subs"]
        }
        if job.format.kind == .audio {
            args += ["-f", "ba/b"]
            // Saved beside the audio as name.jpg, then embedded as cover art.
            args += job.format.canEmbedCover
                ? ["--write-thumbnail", "--convert-thumbnails", "jpg"]
                : ["--no-write-thumbnail"]
        } else {
            args.append("--no-write-thumbnail")
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

        let cover = format.canEmbedCover ? Self.thumbnail(for: input, staging: staging) : nil
        job.detail = "Inspecting…"
        Task.detached(priority: .userInitiated) { [self] in
            // Probe duration and stream presence off the main thread in one ffprobe call.
            let probe = ffmpeg.probe(of: input)
            if let probe {
                if format.kind == .audio, !probe.hasAudio {
                    await MainActor.run {
                        self.cleanupStaging(job)
                        job.state = .failed("This file has no audio track to convert.")
                        self.finished(job)
                    }
                    return
                }
                if format.kind == .video, !probe.hasVideo {
                    await MainActor.run {
                        self.cleanupStaging(job)
                        job.state = .failed("This file has no video track to convert.")
                        self.finished(job)
                    }
                    return
                }
            }

            await MainActor.run {
                if case .running = job.state { job.detail = "Converting…" }
            }

            let duration = probe?.duration
            var currentOptions = options
            var includeSubtitles = (probe?.hasSubtitles ?? true) && format.subtitleCodec != nil
            var currentCover = cover

            var result = await Self.runFFmpeg(job: job, input: input, output: output,
                                              format: format, options: currentOptions,
                                              ffmpeg: ffmpeg, environment: environment,
                                              duration: duration, started: started, queue: self,
                                              cover: currentCover,
                                              includeSubtitles: includeSubtitles)

            // Fallback 1: remux -> re-encode when codecs don't fit the container.
            if !result.cancelled, result.launchError == nil, result.status != 0,
               currentOptions.remux, format.canRemux {
                currentOptions.remux = false
                await MainActor.run {
                    job.appendNote("Streams didn't fit the container; re-encoded instead.")
                }
                try? FileManager.default.removeItem(at: output)
                result = await Self.runFFmpeg(job: job, input: input, output: output,
                                              format: format, options: currentOptions,
                                              ffmpeg: ffmpeg, environment: environment,
                                              duration: duration, started: started, queue: self,
                                              cover: currentCover,
                                              includeSubtitles: includeSubtitles)
            }

            // Fallback 2: VideoToolbox hardware encoder -> software encoder.
            if !result.cancelled, result.launchError == nil, result.status != 0,
               !currentOptions.remux,
               let hw = format.hardwareEncoder,
               let sw = format.encoders.first,
               OutputFormat.hw(sw, hw, currentOptions),
               format.encoders.allSatisfy(ffmpeg.encoders.contains) {
                currentOptions.hardware = false
                try? FileManager.default.removeItem(at: output)
                result = await Self.runFFmpeg(job: job, input: input, output: output,
                                              format: format, options: currentOptions,
                                              ffmpeg: ffmpeg, environment: environment,
                                              duration: duration, started: started, queue: self,
                                              cover: currentCover,
                                              includeSubtitles: includeSubtitles)
                if result.status == 0 {
                    await MainActor.run {
                        job.appendNote("Hardware encoder failed; used software encoder instead.")
                    }
                }
            }

            // Fallback 3: drop incompatible subtitle tracks rather than failing the video.
            if !result.cancelled, result.launchError == nil, result.status != 0,
               includeSubtitles {
                includeSubtitles = false
                try? FileManager.default.removeItem(at: output)
                result = await Self.runFFmpeg(job: job, input: input, output: output,
                                              format: format, options: currentOptions,
                                              ffmpeg: ffmpeg, environment: environment,
                                              duration: duration, started: started, queue: self,
                                              cover: currentCover,
                                              includeSubtitles: false)
                if result.status == 0 {
                    await MainActor.run {
                        job.appendNote("Couldn't embed subtitles; converted without them.")
                    }
                }
            }

            // Fallback 4: cover art is a bonus — an unreadable thumbnail mustn't cost the audio.
            if !result.cancelled, result.launchError == nil, result.status != 0,
               currentCover != nil {
                currentCover = nil
                try? FileManager.default.removeItem(at: output)
                result = await Self.runFFmpeg(job: job, input: input, output: output,
                                              format: format, options: currentOptions,
                                              ffmpeg: ffmpeg, environment: environment,
                                              duration: duration, started: started, queue: self,
                                              cover: nil,
                                              includeSubtitles: includeSubtitles)
                if result.status == 0 {
                    await MainActor.run { job.appendNote("Couldn't add the cover art.") }
                }
            }

            let finalResult = result
            let outputSize = finalResult.status == 0 ? Self.fileSize(output) : nil
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
                    job.outputSizeBytes = outputSize
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
            var needsFrameExtraction = !Self.isImage(input)

            if !needsFrameExtraction {
                do {
                    try NativeImage.convert(input: input, output: output, format: format,
                                            resolution: options.resolution,
                                            quality: options.quality)
                } catch NativeImageError.unreadable {
                    // Exotic formats like QOI/WebP that ImageIO can't decode can still
                    // be decoded through ffmpeg to a temporary PNG first.
                    needsFrameExtraction = true
                } catch {
                    failure = error.localizedDescription
                }
            }

            if needsFrameExtraction, failure == nil {
                let args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                            "-i", input.path, "-frames:v", "1", "-f", "image2", frame.path]
                let extracted = await Self.runTrackedFFmpeg(job: job, executable: ffmpeg.ffmpeg,
                                                            arguments: args,
                                                            environment: environment)
                if extracted.cancelled {
                    // Handled below on MainActor.
                } else if let launchError = extracted.launchError {
                    failure = launchError
                } else if extracted.status == 0 {
                    do {
                        try NativeImage.convert(input: frame, output: output, format: format,
                                                resolution: options.resolution,
                                                quality: options.quality)
                    } catch {
                        failure = error.localizedDescription
                    }
                } else {
                    failure = ErrorHints.message(for: extracted.stderr)
                        ?? Self.lastMeaningfulLine(extracted.stderr)
                        ?? "Couldn't extract a frame from the video."
                }
            }

            let finalFailure = failure
            let outputSize = finalFailure == nil ? Self.fileSize(output) : nil
            await MainActor.run {
                job.process = nil
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
                    job.outputSizeBytes = outputSize
                    job.state = .done
                    job.detail = nil
                }
                self.cleanupStaging(job)
                self.finished(job)
            }
        }
    }

    nonisolated private static func runTrackedFFmpeg(job: Job, executable: URL,
                                                     arguments: [String],
                                                     environment: [String: String]) async -> FFmpegResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        let errors = ErrorTail()
        err.fileHandleForReading.readabilityHandler = { handle in
            errors.append(handle.availableData)
        }

        let cancelledBefore = await MainActor.run { job.state == .cancelled }
        if cancelledBefore {
            err.fileHandleForReading.readabilityHandler = nil
            try? err.fileHandleForReading.close()
            return FFmpegResult(launchError: nil, status: 0, stderr: "", cancelled: true)
        }

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

        err.fileHandleForReading.readabilityHandler = nil
        let trailing = err.fileHandleForReading.readDataToEndOfFile()
        if !trailing.isEmpty { errors.append(trailing) }
        try? err.fileHandleForReading.close()

        let status = launchError == nil ? process.terminationStatus : -1
        let cancelled = await MainActor.run {
            job.process = nil
            return job.state == .cancelled
        }
        return FFmpegResult(launchError: launchError, status: status, stderr: errors.text,
                            cancelled: cancelled)
    }

    nonisolated private static func runFFmpeg(job: Job, input: URL, output: URL,
                                              format: OutputFormat, options: EncodeOptions,
                                              ffmpeg: FFmpeg, environment: [String: String],
                                              duration: Double?, started: Date,
                                              queue: ConversionQueue,
                                              cover: URL? = nil,
                                              includeSubtitles: Bool = true) async -> FFmpegResult {
        let args = format.arguments(input: input.path, output: output.path, options: options,
                                    cover: cover?.path, includeSubtitles: includeSubtitles)

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
        if cancelledBefore {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            return FFmpegResult(launchError: nil, status: 0, stderr: "", cancelled: true)
        }

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
        let trailingErr = err.fileHandleForReading.readDataToEndOfFile()
        if !trailingErr.isEmpty { errors.append(trailingErr) }
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()

        let status = launchError == nil ? process.terminationStatus : -1
        let stderr = errors.text
        let cancelled = await MainActor.run {
            job.process = nil
            return job.state == .cancelled
        }
        return FFmpegResult(launchError: launchError, status: status, stderr: stderr,
                            cancelled: cancelled)
    }

    private func finished(_ job: Job) {
        runningJobs.removeAll { $0 === job }
        if job.state == .done {
            batchDoneCount += 1
            if let output = job.output { batchCompletedOutputs.append(output) }
        } else if case .failed = job.state {
            batchFailedCount += 1
        }

        save()
        startNext()

        if runningJobs.isEmpty && activeCount == 0 {
            if settings.revealWhenDone, !batchCompletedOutputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(batchCompletedOutputs)
            }
            if settings.notifyWhenDone, batchDoneCount + batchFailedCount > 0 {
                postCompletionNotification(done: batchDoneCount, failed: batchFailedCount,
                                           lastTitle: job.title)
            }
            batchCompletedOutputs = []
            batchDoneCount = 0
            batchFailedCount = 0
        }
        updateBadge()
        updateSleepAssertion()
    }

    // MARK: - Sleep prevention & notifications

    private func updateSleepAssertion() {
        if !runningJobs.isEmpty {
            if sleepActivity == nil {
                sleepActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                    reason: "DropConvert is processing media"
                )
            }
        } else {
            endSleepAssertion()
        }
    }

    private func endSleepAssertion() {
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    private func requestNotificationPermissionIfNeeded() {
        guard settings.notifyWhenDone,
              !notificationPermissionRequested,
              Bundle.main.bundleIdentifier != nil else { return }
        notificationPermissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postCompletionNotification(done: Int, failed: Int, lastTitle: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        if failed == 0 {
            content.title = done == 1 ? "Conversion complete" : "Converted \(done) files"
            content.body = done == 1 ? lastTitle : "All queued items finished."
        } else if done == 0 {
            content.title = failed == 1 ? "Conversion failed" : "\(failed) conversions failed"
            content.body = failed == 1 ? lastTitle : "Open DropConvert to inspect details."
        } else {
            content.title = "Queue finished"
            content.body = "\(done) succeeded, \(failed) failed."
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func updateBadge() {
        let active = jobs.filter { !$0.state.isFinished }
        guard !active.isEmpty else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        if runningJobs.count > 1 {
            NSApp.dockTile.badgeLabel = "\(active.count)"
        } else if let running = runningJobs.first,
                  case .running(let fraction) = running.state, let fraction {
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
        let tmpPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
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
            if case .file(let url) = record.source {
                let parent = url.deletingLastPathComponent().standardizedFileURL
                if parent.path.hasPrefix(tmpPath + "/DropConvert-") {
                    job.staging = parent
                }
                if !FileManager.default.fileExists(atPath: url.path) {
                    job.state = .failed("The source file is missing.")
                } else {
                    job.inputSizeBytes = Self.fileSize(url)
                }
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

    /// A .jpg named like another file in the folder is that file's thumbnail.
    nonisolated private static func isThumbnail(_ url: URL, among names: [String]) -> Bool {
        guard url.pathExtension.lowercased() == "jpg" else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        return names.contains {
            $0 != url.lastPathComponent && ($0 as NSString).deletingPathExtension == stem
        }
    }

    /// The thumbnail yt-dlp saved beside a downloaded file (same name, .jpg).
    /// Only downloads have one, so files outside the staging folder never do.
    nonisolated private static func thumbnail(for input: URL, staging: URL?) -> URL? {
        guard let staging,
              input.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/")
        else { return nil }
        let image = input.deletingPathExtension().appendingPathExtension("jpg")
        guard image.standardizedFileURL != input.standardizedFileURL,
              FileManager.default.fileExists(atPath: image.path) else { return nil }
        return image
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
                guard MediaFiles.isMedia(url), !isThumbnail(url, among: names) else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                append(url)
            }
        }
        return result
    }

    nonisolated private static func referencedStagingNames(in records: [JobRecord]) -> Set<String> {
        let tmpPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        var names = Set<String>()
        for record in records where record.state == "queued" {
            guard case .file(let url) = record.source else { continue }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path.hasPrefix(tmpPath + "/DropConvert-") {
                names.insert(parent.lastPathComponent)
            }
        }
        return names
    }

    /// Removes staging folders left behind by an earlier crash or quit, while
    /// preserving any folder still referenced by queued playlist items.
    nonisolated private static func removeStaleStaging(keeping protected: Set<String> = []) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix("DropConvert-") && !protected.contains(name) {
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
        var head = "Downloading"
        if let index = update.itemIndex, let count = update.itemCount {
            head += " item \(index)/\(count)"
        }
        if let fraction = update.fraction { head += " · \(Int(fraction * 100))%" }
        var parts = [head]
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
