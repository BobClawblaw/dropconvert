import AppKit
import DropConvertCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var queue: ConversionQueue
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var linkDraft: LinkDraft
    let close: () -> Void
    @State private var targeted = false
    @FocusState private var linkFocused: Bool
    @State private var detailJob: Job?
    @State private var draggingJobID: UUID?
    @State private var copiedInstallCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if queue.isLocating {
                locating
            } else if queue.ffmpeg == nil {
                missingFFmpeg
            } else {
                dropZone
                linkSection
                options
                if !queue.jobs.isEmpty { jobList }
            }
        }
        .padding(14)
        .frame(minWidth: 360, idealWidth: 380, maxWidth: .infinity)
        .onAppear { linkFocused = true }
        .sheet(item: $detailJob) { job in
            JobDetailView(job: job)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "film.stack").foregroundStyle(.secondary)
            Text("DropConvert").font(.headline)
            Text(AppInfo.versionLine).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Toggle("Use hardware encoder (VideoToolbox)", isOn: $settings.hardware)
                Toggle("Show in Finder when done", isOn: $settings.revealWhenDone)
                Toggle("Notify when done", isOn: $settings.notifyWhenDone)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Menu("Concurrent jobs") {
                    ForEach([1, 2, 4], id: \.self) { count in
                        let label = count == 1 ? "1 (Default)" : "\(count)"
                        Button(settings.maxConcurrentJobs == count ? "✓ \(label)" : label) {
                            settings.maxConcurrentJobs = count
                        }
                    }
                }
                Divider()
                Menu("Cookies for sign-in") {
                    ForEach(CookieBrowser.allCases) { browser in
                        Button(settings.cookiesBrowser == browser
                               ? "✓ \(browser.label)" : browser.label) {
                            settings.cookiesBrowser = browser
                        }
                    }
                }
                Toggle("Download full playlists", isOn: $settings.downloadPlaylists)
                Toggle("Embed English subtitles", isOn: $settings.embedSubtitles)
                Divider()
                Button(queue.isUpdatingDownloader ? "Updating yt-dlp…" : "Update yt-dlp…") {
                    queue.updateDownloader()
                }
                .disabled(queue.downloader == nil || queue.isUpdatingDownloader)
                Button("Copy diagnostics") { copyDiagnostics() }
                Divider()
                Button(outputFolderMenuLabel) {}
                    .disabled(true)
                Button("Choose output folder…", action: chooseFolder)
                if settings.outputFolder != nil {
                    Button("Save beside the original") { settings.outputFolder = nil }
                }
                Divider()
                Button("Check for ffmpeg and yt-dlp") { queue.relocate() }
                Divider()
                Button("About DropConvert") {
                    NSApp.sendAction(#selector(AppDelegate.showAbout), to: NSApp.delegate, from: nil)
                }
                Divider()
                Button("Quit DropConvert") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Settings")
        }
    }

    private var outputFolderMenuLabel: String {
        guard let folder = settings.outputFolder else { return "Save files beside the original" }
        if settings.outputFolderIsUnavailable {
            return "⚠︎ \(folder.lastPathComponent) (unavailable)"
        }
        return "Save to: \(folder.lastPathComponent)"
    }

    private var locating: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Looking for ffmpeg and yt-dlp…")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    private var missingFFmpeg: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("ffmpeg not found", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("DropConvert uses ffmpeg to convert. Install it with Homebrew, then check again:")
                .font(.callout).foregroundStyle(.secondary)
            Text("brew install ffmpeg yt-dlp")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button(copiedInstallCommand ? "Copied" : "Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install ffmpeg yt-dlp", forType: .string)
                    copiedInstallCommand = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedInstallCommand = false
                    }
                }
                Button("Check again") { queue.relocate() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 28, weight: .light))
            Text("Drop videos, images, or folders here").font(.callout.weight(.medium))
            Text("or paste links below · click to choose")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(targeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .contentShape(Rectangle())
        .onTapGesture(perform: chooseFiles)
        .onDrop(of: [.fileURL, .url], isTargeted: $targeted) { providers in
            Task { @MainActor in
                var files: [URL] = []
                var links: [URL] = []
                for provider in providers {
                    guard let url = try? await provider.loadURL() else { continue }
                    if url.isFileURL { files.append(url) } else { links.append(url) }
                }
                if !files.isEmpty { queue.add(files) }
                if !links.isEmpty { queue.addLinks(links) }
            }
            return true
        }
        .accessibilityLabel("Drop videos, images, or folders")
    }

    private var linkSection: some View {
        let links = parsedLinks
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Text("Paste video links").font(.callout.weight(.medium))
                Spacer()
                if !linkDraft.text.isEmpty {
                    Text("\(links.count) \(links.count == 1 ? "link" : "links")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("One URL per line — ⌘V or Ctrl-V",
                      text: $linkDraft.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(3...5)
                .focused($linkFocused)
                .padding(8)
                .frame(minHeight: 64, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
                    .allowsHitTesting(false))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.3))
                    .allowsHitTesting(false))
                .accessibilityLabel("Video links, one per line")
            HStack(spacing: 8) {
                if queue.downloader == nil {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("yt-dlp not found").font(.caption2).foregroundStyle(.orange)
                        Text("brew install yt-dlp")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Button("Check again") { queue.relocate() }.buttonStyle(.link)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        if settings.outputFolderIsUnavailable, let folder = settings.outputFolder {
                            Text("“\(folder.lastPathComponent)” unavailable · using Downloads")
                                .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                        } else {
                            Text("Saves to \(downloadFolderName)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let version = queue.downloader?.version {
                            Text("yt-dlp \(version)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer()
                Button("Paste") { pasteLinks() }
                Button("Download") { addLinks() }
                    .buttonStyle(.borderedProminent)
                    .disabled(queue.downloader == nil || links.isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            if let message = queue.downloaderUpdateMessage {
                Text(message).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
        }
    }

    private var options: some View {
        let formats = queue.availableFormats
        let format = formats.first { $0.id == settings.formatID } ?? formats.first
        let recentFormats = settings.recentFormatIDs.compactMap { id in
            formats.first(where: { $0.id == id })
        }
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Convert to", selection: $settings.formatID) {
                ForEach([OutputFormat.Kind.video, .still, .image, .audio], id: \.self) { kind in
                    Section(kind.rawValue) {
                        ForEach(formats.filter { $0.kind == kind }) { f in
                            Text("\(f.name)  (.\(f.ext))").tag(f.id)
                        }
                    }
                }
            }
            if recentFormats.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Recent:").font(.caption2).foregroundStyle(.secondary)
                        ForEach(recentFormats) { recent in
                            let selected = recent.id == format?.id
                            Button(recent.name) {
                                settings.formatID = recent.id
                            }
                            .buttonStyle(.plain)
                            .font(.caption2.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(selected
                                               ? Color.accentColor.opacity(0.18)
                                               : Color.secondary.opacity(0.1)))
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        }
                    }
                }
            }
            if settings.remux && format?.canRemux == true {
                Text("Streams are copied as they are. Fast and lossless, but fails when the codecs don't fit the container.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if format?.hasQuality == true {
                    Picker("Quality", selection: $settings.quality) {
                        ForEach(Quality.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if format?.kind != .audio {
                    Picker("Size", selection: $settings.resolution) {
                        ForEach(Resolution.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            if format?.canRemux == true {
                Toggle("Copy streams (no re-encode)", isOn: $settings.remux)
                    .toggleStyle(.checkbox)
            }
            if format?.engine == .imageIO {
                Text("HEIC and AVIF are written with macOS ImageIO. Videos use their first frame.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Text("Queue").font(.subheadline.weight(.semibold))
                if queue.isPaused {
                    Text("Paused").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button(queue.isPaused ? "Resume" : "Pause") {
                    queue.setPaused(!queue.isPaused)
                }
                .buttonStyle(.link)
                if queue.failedCount > 0 {
                    Button("Retry failed") { queue.retryAllFailed() }.buttonStyle(.link)
                }
                if queue.activeCount > 0 {
                    Button("Cancel all") { queue.cancelAll() }.buttonStyle(.link)
                }
                if queue.jobs.contains(where: { $0.state.isFinished }) {
                    Button("Clear finished") { queue.clearFinished() }.buttonStyle(.link)
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(queue.jobs.enumerated()), id: \.element.id) { index, job in
                        JobRow(job: job,
                               isFirst: index == 0,
                               isLast: index == queue.jobs.count - 1,
                               draggingJobID: $draggingJobID,
                               onDetails: { detailJob = $0 })
                    }
                }
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: queue.jobs.count < 5)
        }
    }

    private var parsedLinks: [URL] { Downloader.links(in: linkDraft.text) }

    private var downloadFolderName: String {
        settings.outputFolder?.lastPathComponent ?? "Downloads"
    }

    private func pasteLinks() {
        linkDraft.appendClipboard()
        linkFocused = true
    }

    private func addLinks() {
        let links = parsedLinks
        guard !links.isEmpty else { return }
        queue.addLinks(links)
        linkDraft.text = ""
        linkFocused = true
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .audio, .image]
        panel.message = "Choose videos, images, or folders to convert"
        NSApp.activate()
        if panel.runModal() == .OK { queue.add(panel.urls) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { settings.outputFolder = url }
    }

    private func copyDiagnostics() {
        let text = Diagnostics.text(queue: queue, settings: settings)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct JobRow: View {
    @EnvironmentObject var queue: ConversionQueue
    @ObservedObject var job: Job
    let isFirst: Bool
    let isLast: Bool
    @Binding var draggingJobID: UUID?
    let onDetails: (Job) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon.frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if job.isRemote {
                        Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(job.title).lineLimit(1).truncationMode(.middle)
                }
                if let output = job.output {
                    Text("→ \(output.lastPathComponent)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("→ \(job.format.name) · \(job.phase == .downloading ? "download first" : "waiting")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                detail
                if let note = job.note {
                    Text(note).font(.caption2).foregroundStyle(.orange)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            actions
        }
        .contentShape(Rectangle())
        .onDrag {
            if job.state == .done, let output = job.output {
                draggingJobID = nil
                return NSItemProvider(object: output as NSURL)
            }
            draggingJobID = job.id
            return NSItemProvider(object: job.id.uuidString as NSString)
        }
        .onDrop(of: [.utf8PlainText], delegate: JobReorderDropDelegate(
            targetID: job.id,
            draggingJobID: $draggingJobID,
            queue: queue
        ))
        .contextMenu { menuItems }
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
                .accessibilityLabel("Queued")
        case .running:
            ProgressView().controlSize(.small)
                .accessibilityLabel(job.phase == .downloading ? "Downloading" : "Converting")
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityLabel("Done")
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                .accessibilityLabel("Failed")
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                .accessibilityLabel("Cancelled")
        }
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .queued:
            Text(job.isRemote ? "Waiting to download" : "Waiting")
                .font(.caption2).foregroundStyle(.secondary)
        case .running(let fraction):
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let text = job.detail {
                Text(text).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        case .done:
            Text("\(job.isRemote ? "Downloaded and converted" : "Done") in \(Self.time(job.elapsed))\(Self.sizeSummary(input: job.inputSizeBytes, output: job.outputSizeBytes, url: job.output))")
                .font(.caption2).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption2).foregroundStyle(.red)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if job.errorDetails != nil {
                Button("Details") { onDetails(job) }
                    .buttonStyle(.link).font(.caption2)
            }
        case .cancelled:
            Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.state {
        case .queued, .running:
            Button { queue.cancel(job) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).help("Cancel").accessibilityLabel("Cancel")
        case .done:
            if let output = job.output {
                Button { NSWorkspace.shared.activateFileViewerSelecting([output]) } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless).help("Show in Finder").accessibilityLabel("Show in Finder")
            }
        case .failed, .cancelled:
            Button { queue.retry(job) } label: { Image(systemName: "arrow.clockwise.circle") }
                .buttonStyle(.borderless).help("Try again").accessibilityLabel("Try again")
        }
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    @ViewBuilder private var menuItems: some View {
        let isRunning: Bool = {
            if case .running = job.state { return true }
            return false
        }()
        if job.state == .done, let output = job.output {
            Button("Open output") { NSWorkspace.shared.open(output) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            Divider()
        }
        Menu("Convert to") {
            ForEach(queue.availableFormats) { format in
                Button(format.name) { queue.changeFormat(job, id: format.id) }
            }
        }
        .disabled(isRunning)
        Divider()
        Button("Move up") { queue.move(job, by: -1) }.disabled(isFirst)
        Button("Move down") { queue.move(job, by: 1) }.disabled(isLast)
        Divider()
        Button("Remove") { queue.remove(job) }
    }

    private static func time(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func sizeSummary(input: Int64?, output: Int64?, url: URL?) -> String {
        let outBytes: Int64? = output ?? url.flatMap {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        }
        guard let outBytes else { return "" }
        let outText = ByteCountFormatter.string(fromByteCount: outBytes, countStyle: .file)
        guard let input, input > 0 else { return " · " + outText }
        let inText = ByteCountFormatter.string(fromByteCount: input, countStyle: .file)
        let pct = Int(((Double(outBytes - input) / Double(input)) * 100).rounded())
        let sign = pct > 0 ? "+" : ""
        return " · \(inText) → \(outText) (\(sign)\(pct)%)"
    }
}

private struct JobReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggingJobID: UUID?
    let queue: ConversionQueue

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggingJobID, sourceID != targetID else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            queue.move(fromID: sourceID, toID: targetID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggingJobID != nil else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingJobID = nil
        return true
    }
}

private struct JobDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.title).font(.headline)
            Text(job.source.url.absoluteString)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let note = job.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                Text(job.errorDetails ?? "No extra details.")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.errorDetails ?? "", forType: .string)
                }
                .disabled(job.errorDetails == nil)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 300)
    }
}

private extension NSItemProvider {
    @MainActor func loadURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: url) }
            }
        }
    }
}
