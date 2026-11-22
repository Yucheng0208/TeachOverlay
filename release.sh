#!/bin/bash
# 打包發佈版本：乾淨編譯 → ZIP、DMG、SHA256
#
# 用法：
#   ./release.sh 1.0.0
#
# 選用（有 Apple Developer 帳號時）：
#   SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" \
#   NOTARY_PROFILE="notary-profile" ./release.sh 1.0.0
#   NOTARY_PROFILE 先用 xcrun notarytool store-credentials 建立。
set -euo pipefail
cd "$(dirname "$0")"

PLIST=Resources/Info.plist
CURRENT=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
VERSION="${1:-$CURRENT}"
BUILD=$(plutil -extract CFBundleVersion raw "$PLIST")
if [ "$VERSION" != "$CURRENT" ]; then
    BUILD=$((BUILD + 1))
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
    plutil -replace CFBundleVersion -string "$BUILD" "$PLIST"
fi
echo "==> TeachOverlay $VERSION ($BUILD)"

# 乾淨編譯
rm -rf .build build
./build-app.sh

APP=build/TeachOverlay.app
NAME="TeachOverlay-$VERSION-macOS-arm64"
DIST="dist/v$VERSION"
rm -rf "$DIST"
mkdir -p "$DIST"

# 公證（選用）
if [ -n "${SIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> 公證 App…"
    ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
    xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$DIST/notarize.zip"
fi

# ZIP
echo "==> ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

# DMG（App + 應用程式捷徑，拖曳安裝）
echo "==> DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TeachOverlay $VERSION" -srcfolder "$STAGE" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$DIST/$NAME.dmg" >/dev/null
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DIST/$NAME.dmg"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DIST/$NAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DIST/$NAME.dmg"
    fi
fi

# 校驗碼
(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt)

echo "完成：$DIST"
ls -lh "$DIST"
cat "$DIST/SHA256SUMS.txt"
