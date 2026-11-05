import Foundation

/// Finds command-line tools even when the app was launched from Finder, where
/// the process PATH is minimal. Falls back to the user's login shell.
public enum ToolLocator {
    public static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/opt/local/bin", "/opt/local/sbin",
            "\(home)/.local/bin", "\(home)/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
    }

    public static func locate(named name: String) -> URL? {
        let fm = FileManager.default
        var directories = searchPaths
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories += path.split(separator: ":").map(String.init)
        }

        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        // A login shell sees Homebrew, pipx, asdf, and similar setup.
        guard let shell = loginShell() else { return nil }
        let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        guard let result = ProcessRunner.run(
            shell, ["-lc", "command -v \(quoted)"],
            environment: environment(), timeout: 5),
            result.succeeded else { return nil }

        for line in result.stdout.split(separator: "\n").reversed() {
            let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, fm.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static func environment(adding directories: [URL] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var path = directories.map(\.path)
        for directory in searchPaths where !path.contains(directory) {
            path.append(directory)
        }
        if let existing = env["PATH"] {
            for directory in existing.split(separator: ":").map(String.init) where !path.contains(directory) {
                path.append(directory)
            }
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    public static func version(of tool: URL, arguments: [String]) -> String? {
        guard let result = ProcessRunner.run(tool, arguments, environment: environment(), timeout: 10),
              result.succeeded else { return nil }
        return result.stdout.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func loginShell() -> URL? {
        let fm = FileManager.default
        if let shell = ProcessInfo.processInfo.environment["SHELL"], fm.isExecutableFile(atPath: shell) {
            return URL(fileURLWithPath: shell)
        }
        for candidate in ["/bin/zsh", "/bin/bash"] where fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}
