import AppKit
import SwiftUI

@main
@MainActor
enum DropConvertMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        // A Dock icon and app menu make the app reachable even when macOS
        // hides the menu-bar item in a crowded menu bar.
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSDraggingDestination {
    let settings = Settings()
    let linkDraft = LinkDraft()
    lazy var queue = ConversionQueue(settings: settings)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var progressObserver: Any?
    private var mainWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMainMenu()

        // macOS text views use Command-V, but support the Windows-style
        // Control-V (and friends) that some people reach for.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.control) else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v":
                // Use the field editor when it has focus (so selection is
                // replaced normally), otherwise append to the shared draft.
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder.tryToPerform(#selector(NSText.paste(_:)), with: nil) {
                    return nil
                }
                self.linkDraft.appendClipboard()
                return nil
            case "c":
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                return nil
            case "x":
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                return nil
            case "a":
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                return nil
            default:
                return event
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = Self.icon(busy: false)
        button.toolTip = "DropConvert: drop videos or images, or paste video links"
        button.target = self
        button.action = #selector(togglePopover)

        // The status button's window takes the drop; NSWindow hands drag
        // events to a delegate that implements NSDraggingDestination.
        button.window?.registerForDraggedTypes([.fileURL, .URL])
        button.window?.delegate = self

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: ContentView(close: { [weak self] in self?.popover.performClose(nil) })
                .environmentObject(queue)
                .environmentObject(settings)
                .environmentObject(linkDraft))

        progressObserver = queue.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refreshIcon() }
        }

        // If the menu bar is full, macOS parks the status item off-screen.
        // Open the regular window instead so the app stays usable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.statusItemIsVisible else { return }
            self.showMainWindow()
        }

        // `--show` opens the popover at launch, which is handy for screenshots
        // and for launching the app from a script.
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPopover() }
        }
        if CommandLine.arguments.contains("--window") {
            DispatchQueue.main.async { [weak self] in self?.showMainWindow() }
        }
        if CommandLine.arguments.contains("--about") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showAbout() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        queue.shutdown()
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        let links = urls.filter { !$0.isFileURL }
        if !files.isEmpty { queue.add(files) }
        if !links.isEmpty { queue.addLinks(links) }
        showPopover()
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private var statusItemIsVisible: Bool {
        guard let frame = statusItem.button?.window?.frame else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        guard statusItemIsVisible else {
            showMainWindow()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// The same controls in a regular window, opened from the Dock icon, the
    /// app menu, or when the menu-bar item is hidden.
    private func showMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "DropConvert"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 420)
        let hosting = NSHostingController(
            rootView: ContentView(close: { [weak window] in window?.close() })
                .environmentObject(queue)
                .environmentObject(settings)
                .environmentObject(linkDraft))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        // `center()` follows the app's current screen, which can be a
        // secondary display. Pin the window to the main display instead.
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    @objc private func showMainWindowAction() {
        showMainWindow()
    }

    @objc func showAbout() {
        if let window = aboutWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 430),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "About DropConvert"
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: AboutView(close: { [weak window] in window?.close() }))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = window
    }

    private func makeMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "About DropConvert", action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let show = NSMenuItem(title: "Show DropConvert", action: #selector(showMainWindowAction),
                              keyEquivalent: "")
        show.target = self
        appMenu.addItem(show)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DropConvert",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func refreshIcon() {
        statusItem.button?.image = Self.icon(busy: queue.activeCount > 0)
        statusItem.button?.toolTip = queue.statusText
    }

    private static func icon(busy: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: busy ? "film.stack.fill" : "film.stack",
                            accessibilityDescription: "DropConvert")
        image?.isTemplate = true
        return image
    }

    // MARK: Drops on the menu-bar icon

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !droppedURLs(sender).isEmpty else { return [] }
        statusItem.button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        statusItem.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        let urls = droppedURLs(sender)
        let files = urls.filter(\.isFileURL)
        let links = urls.filter { !$0.isFileURL }
        guard !files.isEmpty || !links.isEmpty else { return false }
        if !files.isEmpty { queue.add(files) }
        if !links.isEmpty { queue.addLinks(links) }
        showPopover()
        return true
    }
}
