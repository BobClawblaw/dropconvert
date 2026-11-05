import Foundation

/// Reads and writes the pending queue as JSON in Application Support.
public final class QueueStore {
    public let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.url = base.appendingPathComponent("DropConvert", isDirectory: true)
                .appendingPathComponent("queue.json")
        }
    }

    public func load() -> [JobRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([JobRecord].self, from: data)) ?? []
    }

    public func save(_ records: [JobRecord]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Persistence is a convenience; a failed write shouldn't stop a job.
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
