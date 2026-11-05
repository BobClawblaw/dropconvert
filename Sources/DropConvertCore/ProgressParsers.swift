import Foundation

public struct ConversionProgress: Equatable, Sendable {
    public var seconds: Double?
    public var speed: String?
    public var finished: Bool
}

public struct DownloadProgress: Equatable, Sendable {
    public var fraction: Double?
    public var speed: String?
    public var eta: String?
}

/// Reads ffmpeg's `-progress` key=value stream.
public final class FFmpegProgressParser: @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()
    private var latestSeconds: Double?
    private var latestSpeed: String?
    private var finished = false

    public init() {}

    public func feed(_ data: Data) -> ConversionProgress? {
        lock.lock(); defer { lock.unlock() }
        buffer += String(decoding: data, as: UTF8.self)
        var changed = false
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.hasPrefix("out_time_us="), let value = Double(line.dropFirst(12)) {
                latestSeconds = value / 1_000_000
                changed = true
            } else if line.hasPrefix("speed=") {
                let value = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, value != "N/A" {
                    latestSpeed = value
                    changed = true
                }
            } else if line == "progress=end" {
                finished = true
                changed = true
            }
        }
        if buffer.utf8.count > 8_192 { buffer = String(buffer.suffix(4_096)) }
        guard changed else { return nil }
        return ConversionProgress(seconds: latestSeconds, speed: latestSpeed, finished: finished)
    }
}

/// Reads yt-dlp's `[download] xx.x% ... at ... ETA ...` lines.
public final class DownloadProgressParser: @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()

    public init() {}

    public func feed(_ data: Data) -> DownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        buffer += String(decoding: data, as: UTF8.self)
        var latest: DownloadProgress?
        while let index = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = buffer[..<index]
            buffer.removeSubrange(...index)
            if let progress = Self.progress(in: line) { latest = progress }
        }
        if buffer.utf8.count > 8_192 { buffer = String(buffer.suffix(4_096)) }
        return latest
    }

    private static func progress(in line: Substring) -> DownloadProgress? {
        guard line.hasPrefix("[download]") else { return nil }
        let tokens = line.split(separator: " ").map(String.init)
        var fraction: Double?
        for token in tokens where token.hasSuffix("%") {
            if let value = Double(token.dropLast()) {
                fraction = min(max(value / 100, 0), 1)
                break
            }
        }
        var speed: String?
        var eta: String?
        for (index, token) in tokens.enumerated() {
            if token == "at", index + 1 < tokens.count {
                speed = tokens[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: ",."))
            }
            if token == "ETA", index + 1 < tokens.count {
                eta = tokens[index + 1]
            }
        }
        guard fraction != nil || speed != nil || eta != nil else { return nil }
        return DownloadProgress(fraction: fraction, speed: speed, eta: eta)
    }
}

/// Keeps the last few stderr lines so a failure can say why.
public final class ErrorTail: @unchecked Sendable {
    private var buffer = ""
    private var lines: [String] = []
    private let lock = NSLock()

    public init() {}

    public func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer += String(decoding: data, as: UTF8.self)
        while let index = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<index]).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...index)
            if !line.isEmpty { lines.append(line) }
        }
        if buffer.utf8.count > 8_192 { buffer = String(buffer.suffix(4_096)) }
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        while lines.reduce(0, { $0 + $1.utf8.count + 1 }) > 32_768, lines.count > 1 {
            lines.removeFirst()
        }
    }

    public var text: String {
        lock.lock(); defer { lock.unlock() }
        var all = lines
        if !buffer.isEmpty { all.append(buffer) }
        return all.joined(separator: "\n")
    }

    public var lastLine: String? {
        lock.lock(); defer { lock.unlock() }
        if let last = lines.last { return last }
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }
}
