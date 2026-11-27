# Changelog

## [1.5.0] - 2026-11-27

### Added

- Configurable concurrent jobs (`1`, `2`, or `4`) in the gear menu.
- Idle system sleep prevention while jobs are actively downloading or converting.
- Optional macOS notifications when a conversion batch finishes (`Notify when done` in the gear menu).
- Drag completed files straight out of the queue into Finder, Mail, Slack, or other apps, plus "Open output" in the job menu.
- Drag-to-reorder rows in the queue and a **Retry failed** batch action.
- Before/after file size comparison with percentage savings on completed jobs.
- Quick-pick recent format chips below the format selector.
- Live playlist item progress (`Downloading item 2/15`) during multi-item yt-dlp downloads.
- Automatic software encoder fallback when VideoToolbox fails, and automatic subtitle-free fallback if a subtitle stream can't be muxed.
- One-click **Copy command** button on the missing-ffmpeg screen.
- GitHub Pages project site in `docs/` with automatic deployment workflow (`.github/workflows/pages.yml`).
- 10 new unit tests (53 total), including real ImageIO EXIF orientation & scaling tests.

### Fixed

- Embedded English subtitles are now actually preserved through ffmpeg (`mov_text` in MP4/MOV/M4V and stream-copied in MKV) instead of being dropped.
- Quitting the app now saves unfinished jobs as queued before cancelling live processes, and preserves staged playlist files across restarts so jobs genuinely resume.
- `Cmd+V` / `Ctrl+V` key interception is scoped to DropConvert's primary window and respects selected text, fixing paste inside `NSOpenPanel` ("Go to Folder"), About, and Details sheets.
- ImageIO HEIC/AVIF conversion now preserves EXIF orientation, camera metadata, and Display P3 color profiles, caches supported destination types, falls back to ffmpeg for exotic images like QOI, and supports cancelling video frame extraction.
- Orientation-aware short-side scaling (`1080p` keeps 1920×1080 landscape and 1080×1920 portrait instead of shrinking portrait media).
- Moved `ffprobe` stream checks, recursive folder scanning, and `pkill` child termination off the main thread, and combined `ffprobe` queries into a single call.
- Drained stderr pipes completely after process exit so trailing error lines aren't truncated.
- Case-insensitive output path deduplication prevents collisions on macOS APFS (`Clip.mov` + `clip.avi`).
- Homebrew detection for `yt-dlp` now checks symlink targets for `/Cellar/` instead of assuming all `/usr/local/` binaries are Homebrew-managed.
- Normalized `music.youtube.com` URLs alongside other YouTube variants.
- Main window no longer overrides manual user resizing when the queue changes.
- Custom output folders that become unavailable (e.g., unmounted drives) now show a clear warning instead of silently falling back.

## [1.4.0] - 2026-11-23

### Added

- Audio downloaded from YouTube and other yt-dlp sites is tagged, so Apple Music shows a proper title and artist.
  The title and artist come from YouTube's track and artist when it has them, otherwise from an "Artist - Title"
  video title, otherwise from the channel name (without "VEVO" or " - Topic"). Labels such as "(Official Video)"
  or "[Lyrics]" are dropped from the title. The year is set only from a release date, never the upload date, and
  the video description is left out; the video link goes in the comment.
- The video thumbnail is embedded as square, center-cropped cover art in MP3, M4A (AAC and ALAC), AIFF and FLAC
  downloads. If the image can't be used, the audio is converted without it and the job says so.
- MP3 files are written with ID3v2.3 tags, and AIFF files now carry tags at all.

## [1.3.2] - 2026-11-05

### Fixed

- Ctrl+V/Cmd+V now always inserts a line feed between the existing link box text and the clipboard
  contents. A URL copied without a trailing newline could previously fuse onto the previous link
  (for example, `clip.mp4https://…`), leaving the new link unparsed.

## [1.3.1] - 2026-11-05

### Fixed

- Ctrl+V now appends clipboard links even when the link box has lost focus. Previously it relied on the
  responder chain, so a paste could silently go nowhere until the Paste button was used. Ctrl+V and the
  Paste button now share the same link draft, and standard paste still replaces selected text when the
  field is focused.

## [1.3.0] - 2026-11-05

### Added

- Queue persistence: unfinished jobs survive a quit or crash and are restored on launch.
- Pause/resume for the queue, per-job format changes, reordering, and removal.
- Cookies-from-browser support for age-restricted, members-only, and bot-checked videos.
- Optional full-playlist downloads and English subtitle embedding.
- One-click yt-dlp update, with Homebrew detection and a clear result message.
- Friendly error hints for common yt-dlp and ffmpeg failures, plus a details sheet with copyable stderr.
- Automatic re-encode fallback when "Copy streams" fails because codecs don't fit the container.
- Preflight checks for missing audio/video streams, unwritable output folders, and low disk space.
- AVIF and HEIC still images through macOS ImageIO, plus ALAC, CAF, and OGG Opus audio.
- Recursive folder drops, a flexible window width, and accessibility labels on icon-only controls.
- Diagnostics report with tool paths, versions, settings, and recent job errors.
- 31 unit tests covering URL parsing, naming, format arguments, progress parsers, error hints, and persistence.
- CI and tag-driven release workflows, a single-source version file, and SHA-256 checksums.
- Optional Developer ID signing and notarization support in the build scripts.
- Homebrew tap/cask install path.

### Changed

- Split the app into a testable `DropConvertCore` library and a thin executable target.
- Tool discovery now falls back to the user's login shell, so Homebrew/pipx installs are found from Finder launches.
- ffmpeg/yt-dlp discovery runs off the main thread, with a progress indicator.
- Staging folders are cleaned on launch instead of after 24 hours.
- Quitting cancels running jobs and terminates the whole process tree, including yt-dlp's ffmpeg children.
- Enabled Swift strict-concurrency checking and removed the remaining compiler warnings.
- The app now reports the bundle version instead of a hardcoded fallback.

### Fixed

- The README's Gatekeeper instructions now match macOS 15 and later.
- WebP is documented as requiring an ffmpeg build with libwebp; the Homebrew build currently lacks it.
- Long titles are truncated to stay under the filesystem's 255-byte name limit.

## [1.2.1] - 2026-11-04

- Added the About window, version display, feature pills, and a compact content-sized window.
- Added YouTube/link downloads and AIFF output.

## [1.2.0] - 2026-11-04

- Added a universal DMG build and GitHub release assets.
