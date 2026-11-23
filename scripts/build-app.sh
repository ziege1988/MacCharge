#!/bin/bash
# Baut MacCharge.app (Universal: Apple Silicon + Intel) und ein ZIP für Releases.
# Nutzung:  ./scripts/build-app.sh [version]
# Benötigt: macOS 13+ mit Xcode bzw. Command Line Tools (kostenlos).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(cat VERSION)}"
VERSION="${VERSION#v}"
BUILD="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
APP="dist/MacCharge.app"

echo "▶︎ Baue MacCharge $VERSION ($BUILD)"
rm -rf dist && mkdir -p dist

if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MacCharge"
else
    echo "  Universal-Build nicht möglich – baue für die aktuelle Architektur"
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/MacCharge"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacCharge"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/Logo.png "$APP/Contents/Resources/Logo.png"

# App-Icon (.icns) aus dem 1024-px-PNG erzeugen
ICONSET="dist/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Ad-hoc-Signatur (kostenlos, kein Apple-Entwicklerkonto nötig)
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

# ZIP für GitHub Releases (ditto erhält Signatur & Attribute)
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/MacCharge-$VERSION.zip"
echo "✅ Fertig: $APP und dist/MacCharge-$VERSION.zip"
