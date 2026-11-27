import Combine
import DropConvertCore
import Foundation
import ServiceManagement

enum CookieBrowser: String, CaseIterable, Identifiable {
    case off, safari, chrome, firefox, edge, brave, chromium

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .firefox: "Firefox"
        case .edge: "Edge"
        case .brave: "Brave"
        case .chromium: "Chromium"
        }
    }
    /// The value yt-dlp expects for `--cookies-from-browser`.
    var argument: String? { self == .off ? nil : rawValue }
}

/// The user's choices, kept in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var formatID: String { didSet { defaults.set(formatID, forKey: "format") } }
    @Published var quality: Quality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    @Published var resolution: Resolution { didSet { defaults.set(resolution.rawValue, forKey: "resolution") } }
    @Published var hardware: Bool { didSet { defaults.set(hardware, forKey: "hardware") } }
    @Published var remux: Bool { didSet { defaults.set(remux, forKey: "remux") } }
    @Published var revealWhenDone: Bool { didSet { defaults.set(revealWhenDone, forKey: "reveal") } }
    @Published var outputFolder: URL? { didSet { defaults.set(outputFolder?.path, forKey: "outputFolder") } }
    @Published var cookiesBrowser: CookieBrowser { didSet { defaults.set(cookiesBrowser.rawValue, forKey: "cookies") } }
    @Published var downloadPlaylists: Bool { didSet { defaults.set(downloadPlaylists, forKey: "playlists") } }
    @Published var embedSubtitles: Bool { didSet { defaults.set(embedSubtitles, forKey: "subtitles") } }
    @Published var maxConcurrentJobs: Int { didSet { defaults.set(maxConcurrentJobs, forKey: "maxConcurrentJobs") } }
    @Published var notifyWhenDone: Bool { didSet { defaults.set(notifyWhenDone, forKey: "notifyWhenDone") } }
    @Published var recentFormatIDs: [String] { didSet { defaults.set(recentFormatIDs, forKey: "recentFormats") } }

    init() {
        formatID = defaults.string(forKey: "format") ?? "mp4-h264"
        quality = Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .medium
        resolution = Resolution(rawValue: defaults.integer(forKey: "resolution")) ?? .original
        hardware = defaults.object(forKey: "hardware") as? Bool ?? true
        remux = defaults.bool(forKey: "remux")
        revealWhenDone = defaults.object(forKey: "reveal") as? Bool ?? true
        outputFolder = defaults.string(forKey: "outputFolder").map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        cookiesBrowser = CookieBrowser(rawValue: defaults.string(forKey: "cookies") ?? "") ?? .off
        downloadPlaylists = defaults.bool(forKey: "playlists")
        embedSubtitles = defaults.bool(forKey: "subtitles")
        let storedConcurrency = defaults.integer(forKey: "maxConcurrentJobs")
        maxConcurrentJobs = [1, 2, 4].contains(storedConcurrency) ? storedConcurrency : 1
        notifyWhenDone = defaults.object(forKey: "notifyWhenDone") as? Bool ?? true
        recentFormatIDs = defaults.stringArray(forKey: "recentFormats") ?? []
    }

    func recordFormatUse(_ id: String) {
        var updated = recentFormatIDs.filter { $0 != id }
        updated.insert(id, at: 0)
        if updated.count > 4 { updated = Array(updated.prefix(4)) }
        if updated != recentFormatIDs { recentFormatIDs = updated }
    }

    var outputFolderIsUnavailable: Bool {
        guard let folder = outputFolder else { return false }
        var isDir: ObjCBool = false
        let fm = FileManager.default
        return !(fm.fileExists(atPath: folder.path, isDirectory: &isDir)
                 && isDir.boolValue && fm.isWritableFile(atPath: folder.path))
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }
}
