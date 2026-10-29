#!/bin/bash
# Builds NetLens.app (universal, ad-hoc signed) into ./build.
# Usage: ./build.sh            build only
#        ./build.sh --install  build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/NetLens.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" \
    -module-name NetLens Sources/*.swift -o "build/obj/NetLens-$arch"
done
lipo -create build/obj/NetLens-arm64 build/obj/NetLens-x86_64 -output "$APP/Contents/MacOS/NetLens"
cp Info.plist "$APP/Contents/Info.plist"

if [ -f icon/icon.png ]; then
  ICONSET=build/obj/AppIcon.iconset
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size icon/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) icon/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP"
rm -rf build/obj
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x NetLens 2>/dev/null || true
  rm -rf /Applications/NetLens.app
  cp -R "$APP" /Applications/
  open /Applications/NetLens.app
  echo "Installed /Applications/NetLens.app"
fi
