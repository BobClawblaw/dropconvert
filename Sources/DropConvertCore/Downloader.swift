import Foundation

public struct DownloaderUpdate: Sendable {
    public let succeeded: Bool
    public let message: String
}

/// Locates yt-dlp, which downloads links before ffmpeg converts them.
public struct Downloader: Sendable {
    public let ytDlp: URL
    public let version: String?

    public init(ytDlp: URL, version: String? = nil) {
        self.ytDlp = ytDlp
        self.version = version
    }

    public static func locate() -> Downloader? {
        guard let url = ToolLocator.locate(named: "yt-dlp") else { return nil }
        let version = ToolLocator.version(of: url, arguments: ["--version"])
        return Downloader(ytDlp: url, version: version)
    }

    public var isHomebrew: Bool {
        ytDlp.path.contains("/Cellar/") || ytDlp.path.contains("/homebrew/")
            || ytDlp.path.hasPrefix("/usr/local/")
    }

    /// Updates yt-dlp through Homebrew when possible, otherwise with `-U`.
    public func update() -> DownloaderUpdate {
        if isHomebrew {
            guard let brew = ToolLocator.locate(named: "brew") else {
                return DownloaderUpdate(succeeded: false,
                                        message: "yt-dlp is managed by Homebrew, but brew wasn't found.")
            }
            guard let result = ProcessRunner.run(brew, ["upgrade", "yt-dlp"],
                                                 environment: ToolLocator.environment(),
                                                 timeout: 300) else {
                return DownloaderUpdate(succeeded: false, message: "Couldn't run brew upgrade yt-dlp.")
            }
            let output = result.stdout + result.stderr
            return DownloaderUpdate(succeeded: result.succeeded,
                                    message: result.succeeded
                                        ? "yt-dlp is up to date."
                                        : Self.lastMeaningfulLine(output) ?? "brew upgrade yt-dlp failed.")
        }

        guard let result = ProcessRunner.run(ytDlp, ["-U"],
                                             environment: ToolLocator.environment(),
                                             timeout: 300) else {
            return DownloaderUpdate(succeeded: false, message: "Couldn't run yt-dlp -U.")
        }
        let output = result.stdout + result.stderr
        return DownloaderUpdate(succeeded: result.succeeded,
                                message: result.succeeded
                                    ? "yt-dlp is up to date."
                                    : Self.lastMeaningfulLine(output) ?? "yt-dlp -U failed.")
    }

    /// Pulls links out of pasted text. Accepts one per line, separated by
    /// whitespace, commas, or semicolons, and bare `youtu.be/...`-style hosts.
    /// YouTube variants are normalized so duplicates collapse.
    public static func links(in text: String) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;"))
        let punctuation = CharacterSet(charactersIn: "<>\"'()[]{}.,;:!?")

        for raw in text.components(separatedBy: separators) {
            var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            token = token.trimmingCharacters(in: punctuation)
            guard !token.isEmpty else { continue }
            if !token.contains("://") {
                // Only prepend https when it looks like a host/path, not prose.
                guard token.contains(".") else { continue }
                token = "https://" + token
            }
            guard var url = URL(string: token),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty,
                  Self.looksLikeHost(host) else { continue }
            url = canonicalYouTube(url) ?? url
            if seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        return urls
    }

    private static func looksLikeHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return true }
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2 else { return false }
        return tld.allSatisfy(\.isLetter)
    }

    private static func canonicalYouTube(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let isShort = host == "youtu.be"
        let isYouTube = isShort || host == "youtube.com" || host == "www.youtube.com"
            || host == "m.youtube.com"
        guard isYouTube else { return nil }

        var id: String?
        if isShort {
            id = url.pathComponents.dropFirst().first
        } else if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value {
            id = value
        } else {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
                id = parts[1]
            }
        }

        guard let id, !id.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/watch"
        var items = [URLQueryItem(name: "v", value: id)]
        // Keep playlist context so a "download full playlist" link still works.
        if let list = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "list" })?.value {
            items.append(URLQueryItem(name: "list", value: list))
        }
        components.queryItems = items
        return components.url
    }

    private static func lastMeaningfulLine(_ text: String) -> String? {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
    }
}
