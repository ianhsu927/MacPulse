#!/bin/bash
# Build a self-contained macOS application using Apple's Command Line Tools.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$PROJECT_DIR/outputs"
OPTIMIZATION="-O"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || { echo "--output requires a destination directory." >&2; exit 2; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --debug)
            OPTIMIZATION="-Onone"
            shift
            ;;
        --help|-h)
            echo "Usage: ./build.sh [--output directory] [--debug]"
            echo "Requires macOS and Apple Command Line Tools; defaults to outputs/MacPulse.app inside this project."
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

mkdir -p "$OUTPUT_DIR" "$PROJECT_DIR/.build/ModuleCache" "$PROJECT_DIR/.build/ClangModuleCache"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ClangModuleCache"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
ICON_SOURCE="$PROJECT_DIR/Assets/GenerateIcon.swift"
ICON_FILE="$PROJECT_DIR/Assets/MacPulse.icns"
ICON_SET="$PROJECT_DIR/.build/MacPulse.iconset"

if [[ ! -f "$ICON_FILE" || "$ICON_SOURCE" -nt "$ICON_FILE" ]]; then
    mkdir -p "$ICON_SET"
    "$SWIFTC" -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$SDK_PATH" \
        -module-cache-path "$SWIFT_MODULECACHE_PATH" \
        -framework AppKit "$ICON_SOURCE" -o "$PROJECT_DIR/.build/generate-icon"
    "$PROJECT_DIR/.build/generate-icon" "$ICON_SET"
    iconutil --convert icns --output "$ICON_FILE" "$ICON_SET"
fi

shopt -s nullglob
SOURCES=("$PROJECT_DIR"/Sources/*.swift)
[[ ${#SOURCES[@]} -gt 0 ]] || { echo "No Swift files found in Sources." >&2; exit 1; }

# File Provider can attach Finder metadata to files under Documents while they
# are being signed. Stage the generated bundle outside that managed directory.
STAGING_DIR="$(mktemp -d /private/tmp/macpulse-build.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGING_APP="$STAGING_DIR/MacPulse.app"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"

echo "Building MacPulse…"
"$SWIFTC" -swift-version 5 -parse-as-library "$OPTIMIZATION" \
    -target arm64-apple-macosx14.0 -sdk "$SDK_PATH" \
    -module-cache-path "$SWIFT_MODULECACHE_PATH" \
    -framework SwiftUI -framework Charts -framework AppKit -framework IOKit \
    -lsqlite3 "${SOURCES[@]}" -o "$STAGING_APP/Contents/MacOS/MacPulse"

cp -X "$PROJECT_DIR/Info.plist" "$STAGING_APP/Contents/Info.plist"
cp -X "$ICON_FILE" "$STAGING_APP/Contents/Resources/MacPulse.icns"
plutil -lint "$STAGING_APP/Contents/Info.plist"
# Generated/copied files may carry Finder metadata; strip it from this bundle
# before signing. Only the app staging directory is affected.
xattr -cr "$STAGING_APP"
codesign --force --sign - --timestamp=none "$STAGING_APP"
codesign --verify --deep --strict "$STAGING_APP"

rm -rf "$OUTPUT_DIR/MacPulse.app"
ditto --norsrc --noextattr --noqtn "$STAGING_APP" "$OUTPUT_DIR/MacPulse.app"
# The destination's File Provider may asynchronously attach its own metadata
# just after copying. Clear only this generated app; retry briefly if necessary.
SIGNATURE_VERIFIED=false
for ATTEMPT in 1 2 3 4; do
    if [[ "$ATTEMPT" -gt 1 ]]; then sleep 1; fi
    xattr -cr "$OUTPUT_DIR/MacPulse.app"
    if codesign --verify --deep --strict "$OUTPUT_DIR/MacPulse.app" 2> "$STAGING_DIR/verification.log"; then
        SIGNATURE_VERIFIED=true
        break
    fi
done
if [[ "$SIGNATURE_VERIFIED" != true ]]; then
    # File Provider may immediately restore Finder metadata on an app that was
    # just opened. Verify the actual destination contents in a clean temporary
    # copy; altered executables/resources still fail the strict signature check.
    VERIFY_APP="$STAGING_DIR/OutputVerification.app"
    ditto --norsrc --noextattr --noqtn "$OUTPUT_DIR/MacPulse.app" "$VERIFY_APP"
    xattr -cr "$VERIFY_APP"
    codesign --verify --deep --strict "$VERIFY_APP"
fi
echo "Built: $OUTPUT_DIR/MacPulse.app"
