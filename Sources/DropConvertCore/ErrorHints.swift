import Foundation

/// Turns the noisiest yt-dlp and ffmpeg failures into a sentence a person can act on.
public enum ErrorHints {
    public static func message(for stderr: String) -> String? {
        let text = stderr.lowercased()
        func has(_ needle: String) -> Bool { text.contains(needle) }

        if has("sign in to confirm") || has("confirm you're not a bot")
            || has("confirm you’re not a bot") {
            return "YouTube wants a sign-in check. Turn on cookies for your browser in the gear menu, or update yt-dlp."
        }
        if has("private video") {
            return "This video is private."
        }
        if has("members-only") || has("join this channel") {
            return "This video is members-only. Turn on cookies for your browser in the gear menu."
        }
        if has("age-restricted") || has("age restricted") {
            return "This video is age-restricted. Turn on cookies for your browser in the gear menu."
        }
        if has("video unavailable") || has("this video is unavailable") {
            return "The video is unavailable — it may have been removed or blocked in your region."
        }
        if has("http error 403") {
            return "The site refused the download (403). Try updating yt-dlp or using cookies."
        }
        if has("http error 429") {
            return "The site is rate-limiting downloads (429). Wait a minute and try again."
        }
        if has("unsupported url") {
            return "yt-dlp doesn't support this link."
        }
        if has("requested format is not available") || has("requested format not available") {
            return "That quality isn't offered for this video. Pick another size and try again."
        }
        if has("ffmpeg not found") || has("ffmpeg-location") {
            return "ffmpeg wasn't found. Install it with Homebrew: brew install ffmpeg."
        }
        if has("no space left on device") {
            return "The disk is full. Free some space and try again."
        }
        if has("permission denied") || has("operation not permitted") {
            return "DropConvert can't write to the output folder. Choose another folder in the gear menu."
        }
        if has("file name too long") {
            return "The output name is too long for the filesystem."
        }
        if has("matches no streams") || has("does not contain any stream") {
            return "This file has no audio or video stream to convert."
        }
        if has("invalid data found when processing input") {
            return "The file may be corrupt or not a media file."
        }
        if has("could not find tag") || has("not currently supported in container")
            || has("not supported in container") {
            return "These streams don't fit the chosen container. Turn off “Copy streams” to re-encode."
        }
        if has("temporary failure in name resolution") || has("network is unreachable")
            || has("could not resolve host") {
            return "The network is unreachable. Check your connection and try again."
        }
        if has("ssl") && (has("certificate") || has("verify failed")) {
            return "The site's certificate couldn't be verified. Check your network or VPN."
        }
        if has("unable to open") && has("output") {
            return "ffmpeg couldn't create the output file. Check the folder and free space."
        }
        return nil
    }
}
