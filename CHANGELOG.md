# Changelog

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
