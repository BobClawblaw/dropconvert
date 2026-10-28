import Foundation
import ServiceManagement

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

    init() {
        formatID = defaults.string(forKey: "format") ?? "mp4-h264"
        quality = Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .medium
        resolution = Resolution(rawValue: defaults.integer(forKey: "resolution")) ?? .original
        hardware = defaults.object(forKey: "hardware") as? Bool ?? true
        remux = defaults.bool(forKey: "remux")
        revealWhenDone = defaults.object(forKey: "reveal") as? Bool ?? true
        outputFolder = defaults.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}
