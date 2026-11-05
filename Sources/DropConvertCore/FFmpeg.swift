import Foundation

/// Finds ffmpeg/ffprobe and lists the encoders the build offers.
public struct FFmpeg: Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL?
    public let encoders: Set<String>
    public let version: String?

    public init(ffmpeg: URL, ffprobe: URL?, encoders: Set<String>, version: String? = nil) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.encoders = encoders
        self.version = version
    }

    public static func locate() -> FFmpeg? {
        guard let ffmpeg = ToolLocator.locate(named: "ffmpeg") else { return nil }
        let listing = output(ffmpeg, ["-hide_banner", "-encoders"]) ?? ""
        // Lines look like " V....D libx264   libx264 H.264 ...".
        let encoders = listing.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6,
                  let first = parts[0].first, "VAS".contains(first) else { return nil }
            return String(parts[1])
        }
        let ffprobe = ToolLocator.locate(named: "ffprobe")
        let version = ToolLocator.version(of: ffmpeg, arguments: ["-version"])
        return FFmpeg(ffmpeg: ffmpeg, ffprobe: ffprobe, encoders: Set(encoders), version: version)
    }

    /// Duration in seconds, or nil when the container doesn't say.
    public func duration(of file: URL) -> Double? {
        guard let ffprobe,
              let out = Self.output(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                                              "-of", "default=noprint_wrappers=1:nokey=1", file.path]),
              let seconds = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds > 0 else { return nil }
        return seconds
    }

    public func hasAudioStream(of file: URL) -> Bool {
        guard let ffprobe else { return false }
        let out = Self.output(ffprobe, ["-v", "error", "-select_streams", "a",
                                        "-show_entries", "stream=index",
                                        "-of", "csv=p=0", file.path])
        return !(out?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public func hasVideoStream(of file: URL) -> Bool {
        guard let ffprobe else { return false }
        let out = Self.output(ffprobe, ["-v", "error", "-select_streams", "v",
                                        "-show_entries", "stream=index",
                                        "-of", "csv=p=0", file.path])
        return !(out?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// PATH for child tools launched from Finder, where the environment is minimal.
    public static func environment(adding directories: [URL]) -> [String: String] {
        ToolLocator.environment(adding: directories)
    }

    private static func output(_ tool: URL, _ args: [String]) -> String? {
        guard let result = ProcessRunner.run(tool, args,
                                             environment: ToolLocator.environment(),
                                             timeout: 30),
              result.succeeded else { return nil }
        return result.stdout
    }
}
