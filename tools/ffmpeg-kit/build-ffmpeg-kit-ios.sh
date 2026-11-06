#!/usr/bin/env bash
#
# Builds ffmpeg-kit (retired upstream, so there are no prebuilt binaries) for iOS as XCFRAMEWORKS you add to the DoubleClips target.
#
#   * LGPL only: NO --enable-gpl (that would pull x264 / x265 / xvid and make the whole app GPL). Video is encoded with Apple's hardware
#     encoder (h264_videotoolbox), audio with FFmpeg's own AAC encoder; every common container / codec is DEcoded by FFmpeg itself.
#   * Run it on a Mac with Xcode + command line tools. First run takes 20-45 minutes (it downloads and builds FFmpeg and its libraries).
#   * I could not run this script where I wrote it (no network, no Xcode), so treat it as a starting point: if a step fails, the output
#     names the library that broke; ffmpeg-kit's own `./ios.sh --help` lists every flag.
#
# Usage:   ./build-ffmpeg-kit-ios.sh                    (defaults below)
#          FFMPEG_KIT_REF=v6.0 WITH_AV1=1 ./build-ffmpeg-kit-ios.sh
#
# Environment:
#   FFMPEG_KIT_REF   git tag / branch of arthenica/ffmpeg-kit to build            (default: v6.0)
#   WITH_AV1         1 = also build libdav1d so AV1 files (.mkv / .webm) decode    (default: 0; needs meson + ninja)
#   WITH_INTEL_SIM   1 = also build the Intel-Mac simulator slice                  (default: 0; Apple Silicon Macs don't need it)
#   IOS_TARGET       minimum iOS version                                           (default: 15.0)
#   WORK             where to build                                                (default: ~/ffmpeg-kit-build)

set -euo pipefail

FFMPEG_KIT_REF="${FFMPEG_KIT_REF:-v6.0}"
WITH_AV1="${WITH_AV1:-0}"
WITH_INTEL_SIM="${WITH_INTEL_SIM:-0}"
IOS_TARGET="${IOS_TARGET:-15.0}"
WORK="${WORK:-$HOME/ffmpeg-kit-build}"
OUT="$(cd "$(dirname "$0")" && pwd)/xcframeworks"

echo "==> Checking tools"
command -v xcodebuild >/dev/null || { echo "Xcode is required (xcode-select --install and install Xcode)."; exit 1; }
command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }

# ffmpeg-kit asks xcrun for the iOS SDK path; without a full Xcode selected it stops with "SDK_PATH not defined".
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
case "$DEV_DIR" in
  ""|*CommandLineTools*)
    echo "xcode-select points to '${DEV_DIR:-nothing}', not to Xcode."
    echo "Fix:  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    echo "      sudo xcodebuild -license accept && xcodebuild -runFirstLaunch"
    exit 1 ;;
esac
for SDK in iphoneos iphonesimulator; do
  if ! xcrun --sdk "$SDK" --show-sdk-path >/dev/null 2>&1; then
    echo "The '$SDK' SDK can't be found by xcrun. Open Xcode > Settings > Components (Platforms) and install the iOS platform,"
    echo "then check:  xcrun --sdk $SDK --show-sdk-path"
    exit 1
  fi
  echo "    $SDK SDK: $(xcrun --sdk "$SDK" --show-sdk-path)"
done

echo "==> Installing build dependencies (Homebrew)"
brew install autoconf automake libtool pkg-config nasm cmake git curl wget gnu-sed bison gettext meson ninja || true
# bison / gettext are keg-only: put them first on PATH.
export PATH="$(brew --prefix bison)/bin:$(brew --prefix gettext)/bin:$PATH"
# ffmpeg-kit's macOS scripts call BSD `sed -i .tmp ...`. GNU sed (Homebrew's gnu-sed "gnubin", often added by shell profiles) reads ".tmp"
# as a command and stops with "sed: -e expression #1, char 1: unknown command: '.'". So: drop every gnubin entry, make /usr/bin win.
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'gnubin' | paste -sd: -)"
export PATH="/usr/bin:$PATH"
if sed --version >/dev/null 2>&1; then
  echo "A GNU sed is still first in PATH ($(command -v sed)); ffmpeg-kit needs the macOS one (/usr/bin/sed)."; exit 1
fi
echo "    sed: $(command -v sed) (BSD)"

echo "==> Getting ffmpeg-kit ($FFMPEG_KIT_REF)"
mkdir -p "$WORK"
if [ ! -d "$WORK/ffmpeg-kit/.git" ]; then
  git clone https://github.com/arthenica/ffmpeg-kit.git "$WORK/ffmpeg-kit"
fi
cd "$WORK/ffmpeg-kit"
git fetch --tags --quiet || true
git checkout "$FFMPEG_KIT_REF"

# Architectures: real devices (arm64) + the Apple Silicon simulator (arm64-simulator). Everything else off.
FLAGS=(
  --xcframework
  --target="$IOS_TARGET"
  --disable-armv7 --disable-armv7s --disable-arm64e --disable-i386
  --disable-x86-64-mac-catalyst --disable-arm64-mac-catalyst
  --enable-ios-videotoolbox     # h264_videotoolbox encoder + hardware decode paths
  --enable-ios-audiotoolbox
  --enable-ios-zlib --enable-ios-bzip2 --enable-ios-libiconv
)
[ "$WITH_INTEL_SIM" = "1" ] || FLAGS+=(--disable-x86-64)
# The simulator slice (Apple Silicon): some ffmpeg-kit versions need it switched on, others have it on by default.
if ./ios.sh --help 2>&1 | grep -q -- "--enable-arm64-simulator"; then FLAGS+=(--enable-arm64-simulator); fi
echo "==> ffmpeg-kit architecture / simulator options in this version:"
./ios.sh --help 2>&1 | grep -i -E "simulator|xcframework" || true
[ "$WITH_AV1" = "1" ] && FLAGS+=(--enable-dav1d)

echo "==> Building: ./ios.sh ${FLAGS[*]}"
if ! ./ios.sh "${FLAGS[@]}"; then
  echo
  echo "Build failed. Last lines of $(pwd)/build.log:"
  tail -40 build.log 2>/dev/null || true
  exit 1
fi

echo "==> Collecting the xcframeworks"
SRC="$(ls -d prebuilt/bundle-apple-xcframework-ios* 2>/dev/null | head -1 || true)"
[ -n "$SRC" ] || { echo "Build finished but prebuilt/bundle-apple-xcframework-ios* was not found."; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$SRC"/*.xcframework "$OUT"/

echo
echo "Done. XCFRAMEWORKS in: $OUT"
ls "$OUT"
echo
echo "Licence check (must say LGPL, never GPL):"
grep -rhoE "(--enable-gpl|--enable-nonfree|--enable-version3)" prebuilt/*/ffmpeg*/ 2>/dev/null | sort -u || true
echo "Next: tools/ffmpeg-kit/README.md, step 'Add them to the app'."
