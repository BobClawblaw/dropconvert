import Darwin
import DropConvertCore
import Foundation

/// Stops a tool and the children it spawned, so cancelling a download also
/// stops the ffmpeg merge it started.
enum ProcessTree {
    static func interrupt(_ process: Process) {
        signal(process, signal: SIGINT, name: "INT")
    }

    static func terminate(_ process: Process) {
        signal(process, signal: SIGTERM, name: "TERM")
    }

    private static func signal(_ process: Process, signal: Int32, name: String) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, signal)
        let pkill = URL(fileURLWithPath: "/usr/bin/pkill")
        _ = ProcessRunner.run(pkill, ["-\(name)", "-P", "\(pid)"], timeout: 2)
    }
}
