# FFmpeg for DoubleClips iOS (.mkv, .avi, .webm, .flv, .wmv, ...)

iOS can't open those containers, so the app converts each such file ONCE into a normal MP4 / M4A next to it
(`Clips/<name>.mkv.converted.mp4`) and plays that. The conversion engine is FFmpeg, through ffmpeg-kit.
The Swift side is already in the project (`Media/`); until the frameworks below are added it builds and runs exactly as before and
tells you "FFmpeg isn't installed in this build" when you open an unsupported file.

## 1. Build ffmpeg-kit (once)

ffmpeg-kit was retired upstream (no prebuilt binaries), so build it yourself on a Mac with Xcode:

```bash
cd tools/ffmpeg-kit
./build-ffmpeg-kit-ios.sh                 # 20-45 min; result in tools/ffmpeg-kit/xcframeworks/
WITH_AV1=1 ./build-ffmpeg-kit-ios.sh      # same + AV1 decoding (libdav1d)
```

It builds LGPL only (no `--enable-gpl`), device arm64 + Apple Silicon simulator. I could not run it where I wrote it, so if a step
fails send me the last 40 lines of output. Known weak spots of a retired project: very new Xcode versions and moved download URLs
of the helper libraries.

## 2. Add them to the app

1. Drag **all** `*.xcframework` from `tools/ffmpeg-kit/xcframeworks/` into the DoubleClips target: *General > Frameworks, Libraries,
   and Embedded Content*, set each to **Embed & Sign** (they are dynamic frameworks: that is also what keeps the LGPL satisfied).
2. Add these system libraries to *Link Binary With Libraries*: `libz.tbd`, `libbz2.tbd`, `libiconv.tbd`, `VideoToolbox.framework`,
   `AudioToolbox.framework`, `CoreMedia.framework`, `AVFoundation.framework`.
3. Build. `import ffmpegkit` now resolves, `FFmpegBackend.isAvailable` becomes true. If a ffmpeg-kit call in
   `Media/FFmpegBackend.swift` doesn't match the version you built, that file is the only place to adjust.

## 3. Licence (LGPL)

Because the app links FFmpeg you must: keep the frameworks dynamic (step 2), show the FFmpeg / ffmpeg-kit licence text and a link to the
source somewhere reachable (Settings > About / Open-source licences), and not add GPL libraries (x264, x265, xvid, ...) to the build.

## What gets converted, how

| Stream | Source | Result |
|---|---|---|
| video | H.264 (8-bit 4:2:0) or HEVC (4:2:0, 8/10-bit) | copied into the MP4: seconds, lossless |
| video | anything else (VP8/VP9, AV1 with `WITH_AV1`, MPEG-4 / Xvid / DivX, WMV, 4:2:2, High10 ...) | re-encoded: hardware H.264 (`h264_videotoolbox`), 4:2:0, square pixels |
| audio | AAC, MP3, AC-3, E-AC-3, ALAC | copied |
| audio | Opus, Vorbis, FLAC, WMA, DTS, PCM ... | AAC 192 kbps stereo |
| other | subtitles, extra audio tracks, chapters | dropped (first video + first audio only) |
