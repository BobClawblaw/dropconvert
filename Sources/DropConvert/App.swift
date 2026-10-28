import AppKit
import SwiftUI

@main
@MainActor
enum DropConvertMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSDraggingDestination {
    let settings = Settings()
    lazy var queue = ConversionQueue(settings: settings)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var progressObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = Self.icon(busy: false)
        button.toolTip = "DropConvert: drop videos here to convert them"
        button.target = self
        button.action = #selector(togglePopover)

        // The status button's window takes the drop; NSWindow hands drag
        // events to a delegate that implements NSDraggingDestination.
        button.window?.registerForDraggedTypes([.fileURL])
        button.window?.delegate = self

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: ContentView(close: { [weak self] in self?.popover.performClose(nil) })
                .environmentObject(queue)
                .environmentObject(settings))

        progressObserver = queue.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refreshIcon() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        queue.add(urls)
        showPopover()
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func refreshIcon() {
        statusItem.button?.image = Self.icon(busy: queue.activeCount > 0)
    }

    private static func icon(busy: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: busy ? "film.stack.fill" : "film.stack",
                            accessibilityDescription: "DropConvert")
        image?.isTemplate = true
        return image
    }

    // MARK: Drops on the menu-bar icon

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        statusItem.button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        statusItem.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        queue.add(urls)
        showPopover()
        return true
    }
}
