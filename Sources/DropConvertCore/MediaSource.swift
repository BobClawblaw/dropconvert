import Foundation

/// Where a job came from: a file on disk or a link to download.
public enum MediaSource: Codable, Sendable, Equatable {
    case file(URL)
    case link(URL)

    public var isLink: Bool {
        if case .link = self { return true }
        return false
    }

    public var url: URL {
        switch self {
        case .file(let url), .link(let url): return url
        }
    }

    public var displayName: String {
        switch self {
        case .file(let url):
            return url.lastPathComponent
        case .link(let url):
            let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Link"
            if host.contains("youtu"),
               let id = Self.youtubeID(in: url) {
                return "YouTube · \(id)"
            }
            let last = url.lastPathComponent
            return last.isEmpty || last == "/" ? host : "\(host)/\(last)"
        }
    }

    private static func youtubeID(in url: URL) -> String? {
        if url.host?.lowercased() == "youtu.be" {
            return url.pathComponents.dropFirst().first
        }
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value {
            return value
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
            return parts[1]
        }
        return nil
    }
}
