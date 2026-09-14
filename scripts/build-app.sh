#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/outputs"
APP="$OUTPUT/SnapWeave.app"
ZIP="$OUTPUT/SnapWeave-0.12.0-arm64.zip"

cd "$ROOT"
swift build -c release --product SnapWeave --arch arm64

rm -rf "$OUTPUT"/*.app(N) "$OUTPUT"/*.zip(N) "$OUTPUT"/*-使用说明.md(N) "$OUTPUT"/*-兼容性清单.md(N)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/arm64-apple-macosx/release/SnapWeave" "$APP/Contents/MacOS/SnapWeave"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/SnapWeave.icns" "$APP/Contents/Resources/SnapWeave.icns"
chmod +x "$APP/Contents/MacOS/SnapWeave"

SIGNING_MODE="${SIGNING_MODE:-adhoc}"

if [[ "$SIGNING_MODE" == "notarized" ]]; then
  : "${DEVELOPER_ID_APPLICATION:?notarized 构建需要 DEVELOPER_ID_APPLICATION}"
  codesign --force --deep --options runtime --sign "$DEVELOPER_ID_APPLICATION" \
    --identifier com.wonderlab.hengjie "$APP"
else
  codesign \
  --force \
  --deep \
  --sign - \
  --identifier com.wonderlab.hengjie \
  --requirements '=designated => identifier "com.wonderlab.hengjie"' \
  "$APP"
fi

if [[ "$SIGNING_MODE" == "notarized" ]]; then
  : "${NOTARY_PROFILE:?notarized 构建需要 NOTARY_PROFILE}"
  NOTARY_ZIP="$OUTPUT/.SnapWeave-notary.zip"
  rm -f "$NOTARY_ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$NOTARY_ZIP"
  xcrun stapler staple "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
rm -rf "$APP"

echo "压缩包：$ZIP"
