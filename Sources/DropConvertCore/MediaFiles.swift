import Foundation
import UniformTypeIdentifiers

/// Expands dropped folders into the media files they contain.
public enum MediaFiles {
    public static let mediaExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "flv",
        "3gp", "wmv", "ogv", "jpg", "jpeg", "png", "webp", "tiff", "tif", "bmp",
        "qoi", "gif", "heic", "avif", "mp3", "m4a", "wav", "aiff", "aif", "flac",
        "ogg", "opus", "caf", "alac",
    ]

    public static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if mediaExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
            || type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
    }

    public static func expand(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            result.append(url)
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles,
                                                               .skipsPackageDescendants]) else { continue }
                for case let child as URL in enumerator {
                    guard let values = try? child.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true,
                          values.isPackage != true,
                          isMedia(child) else { continue }
                    append(child)
                }
            } else if isMedia(url) {
                append(url)
            }
        }
        return result
    }
}
