import Foundation

enum Quality: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Picks the value for this quality from a (high, medium, low) triple.
    func pick<T>(_ high: T, _ medium: T, _ low: T) -> T {
        switch self {
        case .high: high
        case .medium: medium
        case .low: low
        }
    }
}

enum Resolution: Int, CaseIterable, Identifiable {
    case original = 0, p2160 = 2160, p1080 = 1080, p720 = 720, p480 = 480
    var id: Int { rawValue }
    var label: String { self == .original ? "Original" : "\(rawValue)p" }
}

/// What one conversion needs to know besides the files.
struct EncodeOptions {
    var quality: Quality
    var resolution: Resolution
    var hardware: Bool
    var remux: Bool
    var encoders: Set<String>

    func has(_ encoder: String) -> Bool { encoders.contains(encoder) }
}

struct OutputFormat: Identifiable, Hashable {
    enum Kind: String { case video = "Video", image = "Animated image", audio = "Audio only" }

    let id: String
    let name: String
    let ext: String
    let kind: Kind
    /// Encoders the software path needs; the format is offered when these exist
    /// or when `hardwareEncoder` does.
    let encoders: [String]
    let hardwareEncoder: String?
    /// Codec arguments (after `-i input`, before the output path).
    let build: (EncodeOptions) -> [String]

    var canRemux: Bool { kind != .image }

    func isAvailable(_ encoders: Set<String>) -> Bool {
        self.encoders.allSatisfy(encoders.contains) || hardwareEncoder.map(encoders.contains) == true
    }

    /// Full ffmpeg argument list for one file.
    func arguments(input: String, output: String, options o: EncodeOptions) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                    "-progress", "pipe:1", "-nostats", "-i", input]
        if o.remux && canRemux {
            args += kind == .audio ? ["-map", "0:a:0", "-vn", "-c", "copy"]
                                   : ["-map", "0:v?", "-map", "0:a?", "-c", "copy"]
        } else {
            args += kind == .audio ? ["-map", "0:a:0", "-vn"] : ["-map", "0:v:0", "-map", "0:a:0?"]
            args += build(o)
        }
        if ext == "mp4" || ext == "mov" || ext == "m4v" || ext == "m4a" {
            args += ["-movflags", "+faststart"]
        }
        return args + [output]
    }

    static func == (a: OutputFormat, b: OutputFormat) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Codec building blocks

/// Scale to the chosen height (never up) and keep both sides even, which the
/// 4:2:0 encoders require.
private func scaleFilter(_ o: EncodeOptions) -> [String] {
    if o.resolution == .original {
        return ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
    }
    return ["-vf", "scale=-2:'min(\(o.resolution.rawValue),trunc(ih/2)*2)'"]
}

private func h264(_ o: EncodeOptions, hw: Bool) -> [String] {
    let codec = hw ? ["-c:v", "h264_videotoolbox", "-q:v", "\(o.quality.pick(75, 60, 45))"]
                   : ["-c:v", "libx264", "-preset", "medium", "-crf", "\(o.quality.pick(18, 23, 28))"]
    return scaleFilter(o) + codec + ["-pix_fmt", "yuv420p"]
}

private func hevc(_ o: EncodeOptions, hw: Bool) -> [String] {
    let codec = hw ? ["-c:v", "hevc_videotoolbox", "-q:v", "\(o.quality.pick(75, 60, 45))"]
                   : ["-c:v", "libx265", "-preset", "medium", "-crf", "\(o.quality.pick(20, 26, 30))"]
    return scaleFilter(o) + codec + ["-pix_fmt", "yuv420p", "-tag:v", "hvc1"]
}

private func av1(_ o: EncodeOptions) -> [String] {
    scaleFilter(o) + ["-c:v", "libsvtav1", "-preset", "8", "-crf", "\(o.quality.pick(26, 34, 42))",
                      "-pix_fmt", "yuv420p"]
}

private func vp9(_ o: EncodeOptions) -> [String] {
    scaleFilter(o) + ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "\(o.quality.pick(28, 33, 40))",
                      "-row-mt", "1", "-deadline", "good", "-cpu-used", "2", "-pix_fmt", "yuv420p"]
}

private func aac(_ o: EncodeOptions) -> [String] { ["-c:a", "aac", "-b:a", o.quality.pick("256k", "192k", "128k")] }
private func opus(_ o: EncodeOptions) -> [String] { ["-c:a", "libopus", "-b:a", o.quality.pick("160k", "128k", "96k")] }
private func mp3(_ o: EncodeOptions) -> [String] { ["-c:a", "libmp3lame", "-q:a", o.quality.pick("0", "2", "5")] }

private func h264Format(_ id: String, _ name: String, _ ext: String, extra: [String] = []) -> OutputFormat {
    OutputFormat(id: id, name: name, ext: ext, kind: .video, encoders: ["libx264", "aac"],
                 hardwareEncoder: "h264_videotoolbox") { o in
        h264(o, hw: OutputFormat.hw("libx264", "h264_videotoolbox", o)) + aac(o) + extra
    }
}

private func hevcFormat(_ id: String, _ name: String, _ ext: String) -> OutputFormat {
    OutputFormat(id: id, name: name, ext: ext, kind: .video, encoders: ["libx265", "aac"],
                 hardwareEncoder: "hevc_videotoolbox") { o in
        hevc(o, hw: OutputFormat.hw("libx265", "hevc_videotoolbox", o)) + aac(o)
    }
}

extension OutputFormat {
    /// Hardware when asked for and present, or when the software encoder is missing.
    static func hw(_ software: String, _ hardware: String, _ o: EncodeOptions) -> Bool {
        o.has(hardware) && (o.hardware || !o.has(software))
    }

    static let all: [OutputFormat] = [
        h264Format("mp4-h264", "MP4 · H.264", "mp4"),
        hevcFormat("mp4-hevc", "MP4 · HEVC (H.265)", "mp4"),
        OutputFormat(id: "mp4-av1", name: "MP4 · AV1", ext: "mp4", kind: .video,
                     encoders: ["libsvtav1", "aac"], hardwareEncoder: nil) { av1($0) + aac($0) },
        h264Format("mov-h264", "MOV · H.264", "mov"),
        hevcFormat("mov-hevc", "MOV · HEVC (H.265)", "mov"),
        OutputFormat(id: "mov-prores", name: "MOV · ProRes 422", ext: "mov", kind: .video,
                     encoders: ["prores_ks"], hardwareEncoder: "prores_videotoolbox") { o in
            let profile = o.quality.pick("hq", "standard", "proxy")
            let video = hw("prores_ks", "prores_videotoolbox", o)
                ? ["-c:v", "prores_videotoolbox", "-profile:v", profile]
                : ["-c:v", "prores_ks", "-profile:v", profile, "-pix_fmt", "yuv422p10le"]
            return scaleFilter(o) + video + ["-c:a", "pcm_s16le"]
        },
        h264Format("m4v-h264", "M4V · H.264", "m4v"),
        h264Format("mkv-h264", "MKV · H.264", "mkv"),
        hevcFormat("mkv-hevc", "MKV · HEVC (H.265)", "mkv"),
        OutputFormat(id: "webm-vp9", name: "WebM · VP9", ext: "webm", kind: .video,
                     encoders: ["libvpx-vp9", "libopus"], hardwareEncoder: nil) { vp9($0) + opus($0) },
        OutputFormat(id: "webm-av1", name: "WebM · AV1", ext: "webm", kind: .video,
                     encoders: ["libsvtav1", "libopus"], hardwareEncoder: nil) { av1($0) + opus($0) },
        OutputFormat(id: "avi-mpeg4", name: "AVI · MPEG-4 Part 2", ext: "avi", kind: .video,
                     encoders: ["mpeg4", "libmp3lame"], hardwareEncoder: nil) { o in
            scaleFilter(o) + ["-c:v", "mpeg4", "-q:v", o.quality.pick("2", "4", "8"), "-tag:v", "XVID"] + mp3(o)
        },
        OutputFormat(id: "mpg-mpeg2", name: "MPG · MPEG-2", ext: "mpg", kind: .video,
                     encoders: ["mpeg2video", "mp2"], hardwareEncoder: nil) { o in
            scaleFilter(o) + ["-c:v", "mpeg2video", "-q:v", o.quality.pick("2", "4", "8"),
                              "-c:a", "mp2", "-b:a", "192k"]
        },
        h264Format("ts-h264", "MPEG-TS · H.264", "ts"),
        h264Format("flv-h264", "FLV · H.264", "flv"),
        h264Format("3gp-h264", "3GP · H.264", "3gp"),
        OutputFormat(id: "wmv", name: "WMV · Windows Media 8", ext: "wmv", kind: .video,
                     encoders: ["wmv2", "wmav2"], hardwareEncoder: nil) { o in
            scaleFilter(o) + ["-c:v", "wmv2", "-q:v", o.quality.pick("2", "4", "8"),
                              "-c:a", "wmav2", "-b:a", "192k"]
        },
        OutputFormat(id: "ogv", name: "OGV · Theora", ext: "ogv", kind: .video,
                     encoders: ["libtheora", "libvorbis"], hardwareEncoder: nil) { o in
            scaleFilter(o) + ["-c:v", "libtheora", "-q:v", o.quality.pick("9", "7", "5"),
                              "-c:a", "libvorbis", "-q:a", "5"]
        },
        OutputFormat(id: "gif", name: "GIF", ext: "gif", kind: .image,
                     encoders: ["gif"], hardwareEncoder: nil) { o in
            let height = o.resolution == .original ? 480 : min(o.resolution.rawValue, 720)
            let fps = o.quality.pick(20, 15, 10)
            return ["-an", "-vf",
                    "fps=\(fps),scale=-2:'min(\(height),ih)':flags=lanczos,split[a][b];" +
                    "[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a",
                    "-loop", "0"]
        },
        OutputFormat(id: "mp3", name: "MP3", ext: "mp3", kind: .audio,
                     encoders: ["libmp3lame"], hardwareEncoder: nil) { mp3($0) },
        OutputFormat(id: "m4a", name: "M4A · AAC", ext: "m4a", kind: .audio,
                     encoders: ["aac"], hardwareEncoder: nil) { aac($0) },
        OutputFormat(id: "wav", name: "WAV", ext: "wav", kind: .audio,
                     encoders: ["pcm_s16le"], hardwareEncoder: nil) { _ in ["-c:a", "pcm_s16le"] },
        OutputFormat(id: "flac", name: "FLAC", ext: "flac", kind: .audio,
                     encoders: ["flac"], hardwareEncoder: nil) { _ in ["-c:a", "flac"] },
    ]
}
