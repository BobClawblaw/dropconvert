import Foundation

/// Locates yt-dlp, which downloads links before ffmpeg converts them.
struct Downloader {
    let ytDlp: URL

    static func locate() -> Downloader? {
        let fm = FileManager.default
        let dirs = FFmpeg.searchPaths
            + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        guard let url = dirs.lazy
            .map({ URL(fileURLWithPath: $0).appendingPathComponent("yt-dlp") })
            .first(where: { fm.isExecutableFile(atPath: $0.path) }) else { return nil }
        return Downloader(ytDlp: url)
    }

    /// Pulls links out of pasted text. Accepts one per line, separated by
    /// whitespace or commas, and bare `youtu.be/...`-style hosts.
    static func links(in text: String) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        let punctuation = CharacterSet(charactersIn: "<>\"'()[]")

        for raw in text.components(separatedBy: separators) {
            var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            token = token.trimmingCharacters(in: punctuation)
            guard !token.isEmpty else { continue }
            if !token.contains("://") {
                // Only prepend https when it looks like a host/path, not prose.
                guard token.contains(".") else { continue }
                token = "https://" + token
            }
            guard let url = URL(string: token),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty else { continue }
            if seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        return urls
    }
}
