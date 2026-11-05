import Foundation

/// Builds output paths that don't overwrite the source or another queued job.
public enum OutputNamer {
    public static func uniqueOutput(input: URL, ext: String, folder: URL?,
                                    avoiding claimed: Set<String>,
                                    fileManager: FileManager = .default) -> URL {
        let destination = folder ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        return uniqueOutput(base: base, folder: destination, ext: ext,
                            avoiding: claimed, excluding: input, fileManager: fileManager)
    }

    public static func uniqueOutput(base: String, folder: URL, ext: String,
                                    avoiding claimed: Set<String>,
                                    fileManager: FileManager = .default) -> URL {
        uniqueOutput(base: base, folder: folder, ext: ext,
                     avoiding: claimed, excluding: nil, fileManager: fileManager)
    }

    /// Trims a title so the resulting file name stays under the 255-byte
    /// filesystem limit, even after numbering and the extension are added.
    public static func safeBase(_ name: String, maxBytes: Int = 200) -> String {
        var clean = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "." || clean == ".." { clean = "video" }

        var result = ""
        for character in clean {
            let piece = String(character)
            if result.utf8.count + piece.utf8.count > maxBytes { break }
            result.append(character)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "video" : result
    }

    private static func uniqueOutput(base: String, folder: URL, ext: String,
                                     avoiding claimed: Set<String>, excluding input: URL?,
                                     fileManager: FileManager) -> URL {
        let clean = safeBase(base)
        let inputPath = input?.standardizedFileURL.path
        var counter = 0
        while counter < 10_000 {
            let name = counter == 0 ? clean : "\(clean) \(counter + 1)"
            let candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
            let path = candidate.standardizedFileURL.path
            if path != inputPath,
               !fileManager.fileExists(atPath: path),
               !claimed.contains(path) {
                return candidate
            }
            counter += 1
        }
        return folder.appendingPathComponent("\(clean) \(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}
