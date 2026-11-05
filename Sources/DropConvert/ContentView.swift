import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var queue: ConversionQueue
    @EnvironmentObject var settings: Settings
    let close: () -> Void
    @State private var targeted = false
    @State private var linkText = ""
    @FocusState private var linkFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if queue.ffmpeg == nil {
                missingFFmpeg
            } else {
                dropZone
                linkSection
                options
                if !queue.jobs.isEmpty { jobList }
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { linkFocused = true }
    }

    private var header: some View {
        HStack {
            Image(systemName: "film.stack").foregroundStyle(.secondary)
            Text("DropConvert").font(.headline)
            Spacer()
            Menu {
                Toggle("Use hardware encoder (VideoToolbox)", isOn: $settings.hardware)
                Toggle("Show in Finder when done", isOn: $settings.revealWhenDone)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Divider()
                Button(settings.outputFolder.map { "Save to: \($0.lastPathComponent)" } ?? "Save files beside the original") {}
                    .disabled(true)
                Button("Choose output folder…", action: chooseFolder)
                if settings.outputFolder != nil {
                    Button("Save beside the original") { settings.outputFolder = nil }
                }
                Divider()
                Button("Check for ffmpeg and yt-dlp") { queue.relocate() }
                Divider()
                Button("Quit DropConvert") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var missingFFmpeg: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("ffmpeg not found", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("DropConvert uses ffmpeg to convert. Install it with Homebrew, then check again:")
                .font(.callout).foregroundStyle(.secondary)
            Text("brew install ffmpeg").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            HStack {
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
            Text("Drop videos or images here").font(.callout.weight(.medium))
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
    }

    private var linkSection: some View {
        let links = parsedLinks
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Text("Paste video links").font(.callout.weight(.medium))
                Spacer()
                if !linkText.isEmpty {
                    Text("\(links.count) \(links.count == 1 ? "link" : "links")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("One URL per line — YouTube, Vimeo, … · ⌘V or Ctrl-V",
                      text: $linkText, axis: .vertical)
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
                    Text("Saves to \(downloadFolderName)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Paste") { pasteLinks() }
                    .disabled(queue.downloader == nil)
                Button("Download") { addLinks() }
                    .buttonStyle(.borderedProminent)
                    .disabled(queue.downloader == nil || links.isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }

    private var options: some View {
        let formats = queue.availableFormats
        let format = formats.first { $0.id == settings.formatID } ?? formats.first
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
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text("Queue").font(.subheadline.weight(.semibold))
                Spacer()
                if queue.activeCount > 0 {
                    Button("Cancel all") { queue.cancelAll() }.buttonStyle(.link)
                }
                if queue.jobs.contains(where: { $0.state.isFinished }) {
                    Button("Clear finished") { queue.clearFinished() }.buttonStyle(.link)
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(queue.jobs) { JobRow(job: $0) }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: queue.jobs.count < 5)
        }
    }

    private var parsedLinks: [URL] { Downloader.links(in: linkText) }

    private var downloadFolderName: String {
        settings.outputFolder?.lastPathComponent ?? "Downloads"
    }

    private func pasteLinks() {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        if linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            linkText = string
        } else {
            linkText += "\n" + string
        }
    }

    private func addLinks() {
        let links = parsedLinks
        guard !links.isEmpty else { return }
        queue.addLinks(links)
        linkText = ""
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .audio, .image]
        panel.message = "Choose videos or images to convert"
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
}

private struct JobRow: View {
    @EnvironmentObject var queue: ConversionQueue
    @ObservedObject var job: Job

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
            }
            Spacer(minLength: 4)
            actions
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .queued:
            Text(job.isRemote ? "Waiting to download" : "Waiting")
                .font(.caption2).foregroundStyle(.secondary)
        case .running(let fraction):
            if job.phase == .downloading {
                if let fraction {
                    ProgressView(value: fraction)
                    Text("Downloading \(Int(fraction * 100))% · \(Self.time(job.elapsed))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text("Downloading…").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                if let fraction {
                    ProgressView(value: fraction)
                    Text("Converting \(Int(fraction * 100))% · \(Self.time(job.elapsed))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text("Converting…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .done:
            Text("\(job.isRemote ? "Downloaded and converted" : "Done") in \(Self.time(job.elapsed))\(Self.size(job.output))")
                .font(.caption2).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption2).foregroundStyle(.red)
                .lineLimit(3).textSelection(.enabled)
        case .cancelled:
            Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.state {
        case .queued, .running:
            Button { queue.cancel(job) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).help("Cancel")
        case .done:
            if let output = job.output {
                Button { NSWorkspace.shared.activateFileViewerSelecting([output]) } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless).help("Show in Finder")
            }
        case .failed, .cancelled:
            Button { queue.retry(job) } label: { Image(systemName: "arrow.clockwise.circle") }
                .buttonStyle(.borderless).help("Try again")
        }
    }

    private static func time(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func size(_ url: URL?) -> String {
        guard let url,
              let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return "" }
        return " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private extension NSItemProvider {
    func loadURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: url) }
            }
        }
    }
}
