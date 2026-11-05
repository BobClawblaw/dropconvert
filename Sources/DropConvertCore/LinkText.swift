import Foundation

/// Joins clipboard text into the link box with exactly one line feed between
/// entries, so pasting a URL without a trailing newline can't fuse it onto the
/// previous link.
public enum LinkText {
    public static func appending(_ clipboard: String, to existing: String) -> String {
        let incoming = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return existing }
        let base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? incoming : base + "\n" + incoming
    }
}
