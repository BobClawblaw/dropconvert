import AppKit
import SwiftUI

/// The app's About window: version, a short description, and feature pills.
struct AboutView: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            icon
            Text("DropConvert").font(.title2.weight(.semibold))
            Text("Version \(AppInfo.version)").font(.caption).foregroundStyle(.secondary)
            Text("Convert videos and images locally, or paste YouTube and other links to download and convert them.")
                .font(.callout).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            pills
            Divider()
            HStack {
                Link("Project on GitHub",
                     destination: URL(string: "https://github.com/BobClawblaw/dropconvert")!)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder private var icon: some View {
        if let image = NSApp.applicationIconImage {
            Image(nsImage: image).resizable().frame(width: 64, height: 64)
        } else {
            Image(systemName: "film.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    private var pills: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Pill("Video conversion", color: .orange, icon: "film")
                Pill("Image conversion", color: .yellow, icon: "photo")
                Pill("YouTube download", color: .red, icon: "arrow.down.circle")
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Pill("MP4", color: .blue)
                Pill("AIFF", color: .purple)
                Pill("WAV", color: .teal)
                Pill("MOV", color: .blue)
                Pill("AVIF", color: .green)
                Pill("HEIC", color: .green)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Pill("ffmpeg", color: .gray)
                Pill("yt-dlp", color: .gray)
                Pill("macOS 14+", color: .gray)
                Pill("Universal", color: .gray)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct Pill: View {
    let text: String
    let color: Color
    let icon: String?

    init(_ text: String, color: Color, icon: String? = nil) {
        self.text = text
        self.color = color
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.caption2)
            }
            Text(text).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.15)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35)))
        .fixedSize()
    }
}
