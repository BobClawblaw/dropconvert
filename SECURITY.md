# Security

DropConvert is a local macOS app. It runs `ffmpeg`, `ffprobe`, and `yt-dlp` as child processes and writes files only to the folders you choose.

## Reporting a vulnerability

Open a private security advisory on GitHub, or email the maintainer listed in the repository profile. Please include the app version, macOS version, and the command or link that triggered the problem.

## Release integrity

Release DMGs are published with a SHA-256 checksum. Verify it before installing:

```sh
shasum -a 256 DropConvert-1.3.1.dmg
```

Compare the result with the `.sha256` asset on the release page. Builds are ad-hoc signed unless a Developer ID identity is configured; see the README for Gatekeeper guidance.
