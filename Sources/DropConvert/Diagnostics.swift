import DropConvertCore
import Foundation

@MainActor
enum Diagnostics {
    static func text(queue: ConversionQueue, settings: Settings) -> String {
        var lines: [String] = []
        lines.append("DropConvert \(AppInfo.version) (\(AppInfo.build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("ffmpeg: \(queue.ffmpeg?.ffmpeg.path ?? "not found")")
        if let version = queue.ffmpeg?.version { lines.append("ffmpeg version: \(version)") }
        lines.append("yt-dlp: \(queue.downloader?.ytDlp.path ?? "not found")")
        if let version = queue.downloader?.version { lines.append("yt-dlp version: \(version)") }
        lines.append("")
        lines.append("Settings: format=\(settings.formatID) quality=\(settings.quality.rawValue) "
                     + "size=\(settings.resolution.label) hardware=\(settings.hardware) "
                     + "remux=\(settings.remux) cookies=\(settings.cookiesBrowser.rawValue) "
                     + "playlists=\(settings.downloadPlaylists) subtitles=\(settings.embedSubtitles)")
        lines.append("Output folder: \(settings.outputFolder?.path ?? "beside the source / Downloads")")
        lines.append("")
        lines.append("Jobs:")
        if queue.jobs.isEmpty {
            lines.append("  (none)")
        } else {
            for job in queue.jobs {
                lines.append("  [\(job.stateDescription)] \(job.title)")
                lines.append("    source: \(job.source.url.absoluteString)")
                lines.append("    format: \(job.format.name) (.\(job.format.ext))")
                if let output = job.output { lines.append("    output: \(output.path)") }
                if let note = job.note { lines.append("    note: \(note)") }
                if let details = job.errorDetails, !details.isEmpty {
                    let clipped = details.count > 2_000 ? String(details.prefix(2_000)) + "…" : details
                    lines.append("    details: \(clipped.replacingOccurrences(of: "\n", with: "\n      "))")
                }
            }
        }
        lines.append("")
        lines.append("Generated \(Date().formatted(date: .abbreviated, time: .standard))")
        return lines.joined(separator: "\n")
    }
}
