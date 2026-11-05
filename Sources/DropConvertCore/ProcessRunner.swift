import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs a child process and captures both streams. Used for tool discovery,
/// version checks, and yt-dlp updates.
public enum ProcessRunner {
    public static func run(_ executable: URL, _ arguments: [String],
                           environment: [String: String]? = nil,
                           timeout: TimeInterval? = nil) -> ProcessResult? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.set(out.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        do {
            try process.run()
        } catch {
            out.fileHandleForReading.closeFile()
            err.fileHandleForReading.closeFile()
            group.wait()
            return nil
        }

        let timedOut = LockedBool()
        let timer: DispatchWorkItem? = timeout.map { seconds in
            DispatchWorkItem {
                guard process.isRunning else { return }
                timedOut.set(true)
                process.terminate()
            }
        }
        if let timer, let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        }

        group.wait()
        process.waitUntilExit()
        timer?.cancel()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outBox.get(), as: UTF8.self),
            stderr: String(decoding: errBox.get(), as: UTF8.self),
            timedOut: timedOut.get())
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
