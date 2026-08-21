#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PRODUCT_NAME="usbliter8 remote"
APP_DISPLAY_NAME="usbliter8 remote"
EXECUTABLE_NAME="$APP_DISPLAY_NAME"
ARM_SCRATCH="$ROOT_DIR/.build-arm64"
X86_SCRATCH="$ROOT_DIR/.build-x86_64"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_DISPLAY_NAME.app"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
export DEVELOPER_DIR

CODESIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    CODESIGN_ARGS+=(--timestamp)
fi

HOST_TOOLS="$ROOT_DIR/Sources/usbliter8Remote/Resources/Tools"
for arch in arm64 x86_64; do
    test -x "$HOST_TOOLS/$arch/iproxy" || { echo "Missing $arch iproxy" >&2; exit 1; }
    test -x "$HOST_TOOLS/$arch/img4tool" || { echo "Missing $arch img4tool" >&2; exit 1; }
    lipo "$HOST_TOOLS/$arch/iproxy" -verify_arch "$arch" || { echo "Wrong architecture: $arch iproxy" >&2; exit 1; }
    lipo "$HOST_TOOLS/$arch/img4tool" -verify_arch "$arch" || { echo "Wrong architecture: $arch img4tool" >&2; exit 1; }
done
for tool in idevice_id ideviceinfo; do
    test -x "$HOST_TOOLS/arm64/$tool" || { echo "Missing arm64 $tool" >&2; exit 1; }
    test -x "$HOST_TOOLS/x86_64/$tool" || { echo "Missing x86_64 $tool" >&2; exit 1; }
    lipo "$HOST_TOOLS/arm64/$tool" -verify_arch arm64 || { echo "Wrong architecture: arm64 $tool" >&2; exit 1; }
    lipo "$HOST_TOOLS/x86_64/$tool" -verify_arch x86_64 || { echo "Wrong architecture: x86_64 $tool" >&2; exit 1; }
done

RAMDISK_RESOURCES="$ROOT_DIR/Sources/usbliter8Remote/Resources/Ramdisk"
test -f "$RAMDISK_RESOURCES/payload/manifest.json" || { echo "Missing encrypted Ramdisk payload" >&2; exit 1; }
test ! -e "$RAMDISK_RESOURCES/start.sh" || { echo "Plaintext Ramdisk start.sh must not be packaged" >&2; exit 1; }
test ! -e "$RAMDISK_RESOURCES/extracted" || { echo "Plaintext Ramdisk packages must not be packaged" >&2; exit 1; }

MNT2_RESOURCES="$ROOT_DIR/Sources/usbliter8Remote/Resources/Mnt2"
test -f "$MNT2_RESOURCES/payload/manifest.json" || { echo "Missing encrypted Mnt2 payload" >&2; exit 1; }
if find "$MNT2_RESOURCES" -type f -name '*.sh' -print -quit | grep -q .; then
    echo "Plaintext Mnt2 scripts must not be packaged" >&2
    exit 1
fi

EXTRACT_RESOURCES="$ROOT_DIR/Sources/usbliter8Remote/Resources/ExtractFile"
test -f "$EXTRACT_RESOURCES/payload/manifest.json" || { echo "Missing encrypted ExtractFile payload" >&2; exit 1; }
if find "$EXTRACT_RESOURCES" -type f \( -name '*.sh' -o -name '*.plist' \) -print -quit | grep -q .; then
    echo "Plaintext ExtractFile scripts/plists must not be packaged" >&2
    exit 1
fi

RESTORE_RESOURCES="$ROOT_DIR/Sources/usbliter8Remote/Resources/RestoreFile"
test -f "$RESTORE_RESOURCES/payload/manifest.json" || { echo "Missing encrypted RestoreFile payload" >&2; exit 1; }
if find "$RESTORE_RESOURCES" -type f \( -name '*.sh' -o -name '*.plist' \) -print -quit | grep -q .; then
    echo "Plaintext RestoreFile scripts/plists must not be packaged" >&2
    exit 1
fi

HELLO_RESOURCES="$ROOT_DIR/Sources/usbliter8Remote/Resources/HelloNoChange"
test -f "$HELLO_RESOURCES/payload/manifest.json" || { echo "Missing encrypted HelloNoChange payload" >&2; exit 1; }
if find "$HELLO_RESOURCES" -type f \( -name '*.sh' -o -name '*.php' -o -name '*.py' -o -name '*.plist' -o -name '*.tar.gz' \) -print -quit | grep -q .; then
    echo "Plaintext HelloNoChange private resources must not be packaged" >&2
    exit 1
fi

rm -rf "$ARM_SCRATCH" "$X86_SCRATCH" "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "==> Building arm64"
swift build -c release --arch arm64 --scratch-path "$ARM_SCRATCH"

echo "==> Building x86_64"
swift build -c release --arch x86_64 --scratch-path "$X86_SCRATCH"

ARM_BIN="$ARM_SCRATCH/arm64-apple-macosx/release/$PRODUCT_NAME"
X86_BIN="$X86_SCRATCH/x86_64-apple-macosx/release/$PRODUCT_NAME"

for required in "$ARM_BIN" "$X86_BIN"; do
    test -e "$required" || { echo "Missing build output: $required" >&2; exit 1; }
done

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod 755 "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
ditto "$ROOT_DIR/Sources/usbliter8Remote/Resources/Tools" "$APP_DIR/Contents/Resources/Tools"
ditto "$ROOT_DIR/Sources/usbliter8Remote/Resources/BootAssets" "$APP_DIR/Contents/Resources/BootAssets"
ditto "$ROOT_DIR/Sources/usbliter8Remote/Resources/Ramdisk" "$APP_DIR/Contents/Resources/Ramdisk"
ditto "$ROOT_DIR/Sources/usbliter8Remote/Resources/Mnt2" "$APP_DIR/Contents/Resources/Mnt2"
ditto "$ROOT_DIR/Sources/usbliter8Remote/Resources/ExtractFile" "$APP_DIR/Contents/Resources/ExtractFile"
ditto "$ROOT_DIR/Sources/usbliter8Remote/Resources/RestoreFile" "$APP_DIR/Contents/Resources/RestoreFile"
ditto "$ROOT_DIR/Sources/usbliter8Remote/Resources/HelloNoChange" "$APP_DIR/Contents/Resources/HelloNoChange"
ditto "$ROOT_DIR/Sources/usbliter8Remote/Resources/Branding" "$APP_DIR/Contents/Resources/Branding"
cp "$ROOT_DIR/Sources/usbliter8Remote/Resources/Branding/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.yx.deviceutility</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSUIElement</key>
    <false/>
    <key>LSBackgroundOnly</key>
    <false/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# The helpers already use @loader_path/@executable_path relative references.
# Sign nested binaries first, then the outer app, so Gatekeeper can inspect the bundle.
xattr -cr "$APP_DIR" 2>/dev/null || true
while IFS= read -r -d '' file; do
    case "$file" in
        *.dylib|*/idevice_id|*/ideviceinfo|*/irecovery|*/usbliter8ctl|*/img4tool|*/gaster|*/iproxy)
            codesign "${CODESIGN_ARGS[@]}" "$file" >/dev/null
            ;;
    esac
done < <(find "$APP_DIR/Contents/Resources" -type f -print0)
codesign "${CODESIGN_ARGS[@]}" "$APP_DIR" >/dev/null

printf '\nCreated: %s\n' "$APP_DIR"
printf 'Main binary: '; file "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
printf 'Bundle size: '; du -sh "$APP_DIR" | awk '{print $1}'
printf 'ARM helper: '; "$APP_DIR/Contents/Resources/Tools/arm64/idevice_id" --version
printf 'Intel helper: '; arch -x86_64 "$APP_DIR/Contents/Resources/Tools/x86_64/idevice_id" --version
printf 'Signing identity: %s\n' "$SIGN_IDENTITY"
printf 'Hardened Runtime: enabled\n'
