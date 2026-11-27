import Darwin
import DropConvertCore
import Foundation

/// Stops a tool and the children it spawned, so cancelling a download also
/// stops the ffmpeg merge it started.
enum ProcessTree {
    static func interrupt(_ process: Process, wait: Bool = false) {
        signal(process, signal: SIGINT, name: "INT", wait: wait)
    }

    static func terminate(_ process: Process, wait: Bool = false) {
        signal(process, signal: SIGTERM, name: "TERM", wait: wait)
    }

    private static func signal(_ process: Process, signal: Int32, name: String, wait: Bool) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, signal)
        let pkill = URL(fileURLWithPath: "/usr/bin/pkill")
        if wait {
            _ = ProcessRunner.run(pkill, ["-\(name)", "-P", "\(pid)"], timeout: 2)
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = ProcessRunner.run(pkill, ["-\(name)", "-P", "\(pid)"], timeout: 2)
            }
        }
    }
}
