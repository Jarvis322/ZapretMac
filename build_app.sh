#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/dist/Zapret Manager.app"
CONTENTS="$APP/Contents"

cd "$ROOT"
if [[ -d /Applications/Xcode-beta.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
swift build -c release
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp ".build/release/ZapretMac" "$CONTENTS/MacOS/ZapretMac"

# Uygulama simgesini üret (Icon/make_icon.swift) ve .icns olarak göm
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$ROOT/Icon/make_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$ICONSET"

plutil -create xml1 "$CONTENTS/Info.plist"
plutil -insert CFBundleName -string "Zapret Manager" "$CONTENTS/Info.plist"
plutil -insert CFBundleDisplayName -string "Zapret Manager" "$CONTENTS/Info.plist"
plutil -insert CFBundleIdentifier -string "com.zapret.manager" "$CONTENTS/Info.plist"
plutil -insert CFBundleExecutable -string "ZapretMac" "$CONTENTS/Info.plist"
plutil -insert CFBundleIconFile -string "AppIcon" "$CONTENTS/Info.plist"
plutil -insert CFBundlePackageType -string "APPL" "$CONTENTS/Info.plist"
plutil -insert CFBundleShortVersionString -string "0.3.0" "$CONTENTS/Info.plist"
plutil -insert CFBundleVersion -string "5" "$CONTENTS/Info.plist"
plutil -insert LSMinimumSystemVersion -string "14.0" "$CONTENTS/Info.plist"
plutil -insert NSHighResolutionCapable -bool true "$CONTENTS/Info.plist"

codesign --force --deep --sign - "$APP"
echo "$APP"

# DMG paketle (sürükle-bırak kurulum: uygulama + Applications kısayolu)
if [[ "${1:-}" == "--dmg" || "${MAKE_DMG:-}" == "1" ]]; then
    DMG="$ROOT/dist/Zapret Manager.dmg"
    STAGE="$(mktemp -d)/dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "Zapret Manager" -srcfolder "$STAGE" \
        -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "$DMG"
fi
