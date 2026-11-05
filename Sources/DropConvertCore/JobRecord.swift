import Foundation

/// A serializable snapshot of a job that hasn't finished, used to restore the
/// queue after a quit or crash.
public struct JobRecord: Codable, Sendable, Identifiable {
    public var id: UUID
    public var source: MediaSource
    public var formatID: String
    public var quality: String
    public var resolution: Int
    public var hardware: Bool
    public var remux: Bool
    public var title: String
    public var outputPath: String?
    public var state: String
    public var error: String?
    public var note: String?
    public var phase: String

    public init(id: UUID = UUID(), source: MediaSource, formatID: String, quality: String,
                resolution: Int, hardware: Bool, remux: Bool, title: String,
                outputPath: String?, state: String, error: String? = nil,
                note: String? = nil, phase: String) {
        self.id = id
        self.source = source
        self.formatID = formatID
        self.quality = quality
        self.resolution = resolution
        self.hardware = hardware
        self.remux = remux
        self.title = title
        self.outputPath = outputPath
        self.state = state
        self.error = error
        self.note = note
        self.phase = phase
    }
}
