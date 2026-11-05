# DropConvert

<p>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple&logoColor=white">
  <img alt="Universal" src="https://img.shields.io/badge/universal-arm64%20%7C%20x86__64-blue">
  <img alt="Video conversion" src="https://img.shields.io/badge/video-conversion-orange">
  <img alt="Image conversion" src="https://img.shields.io/badge/image-conversion-yellow">
  <img alt="YouTube download" src="https://img.shields.io/badge/YouTube-download-red?logo=youtube">
  <img alt="MP4" src="https://img.shields.io/badge/MP4-video-9cf">
  <img alt="AIFF" src="https://img.shields.io/badge/AIFF-audio-purple">
  <img alt="WAV" src="https://img.shields.io/badge/WAV-audio-teal">
  <img alt="ffmpeg" src="https://img.shields.io/badge/powered%20by-ffmpeg-green">
  <img alt="yt-dlp" src="https://img.shields.io/badge/powered%20by-yt--dlp-lightgrey">
</p>

A small macOS app: drop a video or image on its menu-bar icon (or into its popover) and it converts the file to the
format you picked, using ffmpeg. You can also paste a list of video links — YouTube and other yt-dlp sites — to
download and convert them. Results land beside the original, in a folder you choose, or in Downloads for links.

The app also has a Dock icon and a regular window with the same controls. If macOS hides the menu-bar item because
the menu bar is full, the window opens instead; reopen it from the Dock icon or the DropConvert menu.

## Download

Get the latest macOS build from the [GitHub releases page](https://github.com/BobClawblaw/dropconvert/releases).
The app is ad-hoc signed, so if macOS blocks it on first launch, right-click **DropConvert** and choose **Open**.

## About

DropConvert is a macOS menu-bar app with a Dock icon and a window fallback. It converts local videos and images with
ffmpeg, and downloads YouTube, Vimeo, and other yt-dlp-supported links before converting them to MP4, AIFF, WAV, or
any other format the app supports. The About window — available from the app menu or the gear menu — shows the
version and feature pills.

## Formats

| Kind | Formats |
|---|---|
| Video | MP4 (H.264, HEVC, AV1), MOV (H.264, HEVC, ProRes 422), M4V, MKV (H.264, HEVC), WebM (VP9, AV1), AVI (MPEG-4 Part 2), MPG (MPEG-2), MPEG-TS, FLV, 3GP, WMV, OGV (Theora) |
| Still image | JPG, PNG, WebP, TIFF, BMP, QOI |
| Animated image | GIF (two-pass palette) |
| Audio only | MP3, M4A (AAC), WAV, AIFF, FLAC |

Only formats your ffmpeg build can encode are listed (Homebrew's ffmpeg has no Theora encoder, for example, so OGV
stays hidden).

## Links

Paste links into the "Paste video links" box in the app — one per line, or separated by spaces or commas — then press
Download. Each link is fetched with yt-dlp and converted to the format selected above, so MP4, AIFF and WAV are all one
click away. A playlist link downloads just the video it points at; paste individual links to queue several.

Downloads are staged in a temporary folder and removed when the conversion finishes or is cancelled. Converted links
go to your chosen output folder, or to Downloads when no folder is set. They are named after the video title and
numbered when a file with that name already exists.

## Options

- **Quality:** Low / Medium / High, mapped to each encoder's own scale (CRF for x264/x265/VP9/AV1, `-q:v` for
  VideoToolbox and the MPEG-family encoders, profile for ProRes, bitrate for audio). Lossless formats (PNG, TIFF,
  BMP, QOI, WAV, AIFF, FLAC) have no quality setting, so the control is hidden for them.
- **Size:** Original, 2160p, 1080p, 720p or 480p — the longest side, which is never upscaled. For video, odd
  dimensions are trimmed to even ones so 4:2:0 encoders accept them; still images keep odd sizes (lossless formats)
  unless a smaller target is chosen.
- **Copy streams (no re-encode):** remuxes into the new container. It's fast and lossless, but it fails when the codecs
  don't fit the container (H.264 into WebM, say).
- **Hardware encoder (gear menu):** uses VideoToolbox for H.264, HEVC and ProRes. It's on by default and much faster;
  turn it off for libx264/libx265, which give smaller files at the same quality.
- Gear menu: output folder, show in Finder when done, launch at login, About.

Files and links convert one at a time, in the order they were added. Each one shows progress and can be cancelled or
retried. A failed or cancelled job leaves no partial file. Existing files are never overwritten: `clip.mp4` becomes
`clip 2.mp4`. DropConvert is also registered as an "Open With" app for videos and images in Finder, and accepts
dropped links.

## Requirements

- macOS 14 or later
- ffmpeg (`brew install ffmpeg`). DropConvert looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and
  `PATH`.
- yt-dlp (`brew install yt-dlp`) to download links.
- Xcode command-line tools with Swift 5.10 or later, to build

## Build

```sh
./scripts/build-app.sh            # builds build/DropConvert.app (ad-hoc signed)
./scripts/build-app.sh --install  # also copies it to /Applications and launches it
./scripts/build-dmg.sh            # builds build/DropConvert-<version>.dmg
```

The app icon (`Resources/AppIcon.icns`) is generated by `scripts/make-icon.swift`. Delete the file to regenerate it.

## License

MIT
