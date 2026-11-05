import Combine
import DropConvertCore
import Foundation

@MainActor
final class Job: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued
        case running(Double?) // fraction done, nil when the duration is unknown
        case done
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: true
            case .queued, .running: false
            }
        }
    }

    enum Phase: Equatable {
        case downloading
        case converting
    }

    let id = UUID()
    let source: MediaSource
    @Published var format: OutputFormat
    @Published var options: EncodeOptions
    @Published var title: String
    @Published var output: URL?
    @Published var state: State = .queued
    @Published var phase: Phase
    @Published var elapsed: TimeInterval = 0
    @Published var detail: String?
    @Published var note: String?
    @Published var errorDetails: String?
    var process: Process?
    var inputFile: URL?
    var staging: URL?

    init(source: MediaSource, title: String, output: URL?, format: OutputFormat,
         options: EncodeOptions, phase: Phase) {
        self.source = source
        self.title = title
        self.output = output
        self.format = format
        self.options = options
        self.phase = phase
    }

    var isRemote: Bool { source.isLink }

    var stateDescription: String {
        switch state {
        case .queued: "queued"
        case .running(let fraction):
            fraction.map { "running \(Int($0 * 100))%" } ?? "running"
        case .done: "done"
        case .failed(let message): "failed: \(message)"
        case .cancelled: "cancelled"
        }
    }
}
