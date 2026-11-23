#!/bin/sh
# Downloads the prebuilt sherpa-onnx iOS framework (onnxruntime linked in) used by the SenseVoice
# subtitle engine. Run once after cloning, before `xcodegen generate`.
set -e
VERSION=2.0.3
cd "$(dirname "$0")/.."
DEST=Vendor/SherpaOnnxC.xcframework
if [ -d "$DEST" ] && grep -q "$VERSION" "$DEST/ios-arm64/SherpaOnnxC.framework/Info.plist" 2>/dev/null; then
  echo "sherpa-onnx $VERSION already present"; exit 0
fi
mkdir -p Vendor
TMP=$(mktemp -d)
curl -fL -o "$TMP/x.zip" "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v$VERSION-ios-shared-onnxruntime-static.xcframework.zip"
unzip -q "$TMP/x.zip" -d "$TMP"
rm -rf "$DEST"
mv "$TMP/SherpaOnnxC.xcframework" "$DEST"
rm -rf "$TMP"
echo "sherpa-onnx $VERSION -> $DEST"
