import AppKit
import Combine

/// Shared text for the link box. Keeping it outside the view lets Ctrl+V work
/// even after the field has lost focus, instead of relying on the responder chain.
@MainActor
final class LinkDraft: ObservableObject {
    @Published var text = ""

    func appendClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = string
        } else {
            text += "\n" + string
        }
    }
}
