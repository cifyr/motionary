#!/bin/bash
# Turns a GIF or video into the widget's bundled, animated design.
#
# Runtime-registered fonts resolve on iOS 27 and then draw nothing, so the lane
# fonts have to be in the extension's bundle and listed in UIAppFonts. That is a
# build step, not something the app can do to itself once installed. This runs
# the real pipeline in a simulator, copies what it produced into Resources, and
# rebuilds.
#
#   Tools/bundle-design.sh ~/Desktop/clip.gif [device-udid]
set -euo pipefail

SOURCE="${1:?usage: bundle-design.sh <gif-or-video> [device-udid]}"
DEVICE="${2:-E5721023-4387-5595-92CF-E091E43B4A28}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_NAME="iPhone 17 Pro"
BUNDLE_ID="com.caden.Motionary"

[ -f "$SOURCE" ] || { echo "no such file: $SOURCE" >&2; exit 1; }
cd "$ROOT"

echo "==> Staging $(basename "$SOURCE") as the seed"
cp "$SOURCE" Resources/Wizard.gif

SIM=$(xcrun simctl list devices available | grep "$SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$SIM" ] || { echo "no available $SIM_NAME simulator" >&2; exit 1; }
xcrun simctl boot "$SIM" 2>/dev/null || true

# The seeder only runs on an empty library, so the previous design has to go.
echo "==> Building the design in the simulator"
xcrun simctl uninstall "$SIM" "$BUNDLE_ID" 2>/dev/null || true
xcodegen generate >/dev/null
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath build/sim build >/dev/null
xcrun simctl install "$SIM" build/sim/Build/Products/Debug-iphonesimulator/Motionary.app
xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null

echo "==> Waiting for the font set"
GROUP_ROOT=~/Library/Developer/CoreSimulator/Devices/$SIM/data/Containers/Shared/AppGroup
for _ in $(seq 1 60); do
    DESIGN=$(find "$GROUP_ROOT" -maxdepth 4 -name manifest.json 2>/dev/null | head -1)
    [ -n "$DESIGN" ] && break
    sleep 3
done
[ -n "${DESIGN:-}" ] || { echo "the simulator never produced a manifest" >&2; exit 1; }
DESIGN_DIR="$(dirname "$DESIGN")"

echo "==> Bundling $(ls "$DESIGN_DIR/Fonts" | wc -l | tr -d ' ') lane fonts"
rm -f Resources/MFont*.ttf
cp "$DESIGN_DIR"/Fonts/*.ttf Resources/
cp "$DESIGN_DIR/manifest.json" Resources/prebuilt-manifest.json
cp "$DESIGN_DIR/widget-backdrop.jpg" Resources/prebuilt-backdrop.jpg
cp "$DESIGN_DIR/wallpaper.png" Resources/prebuilt-wallpaper.png

python3 - <<'PY'
import os, re
fonts = sorted([f for f in os.listdir('Resources') if f.startswith('MFont') and f.endswith('.ttf')],
               key=lambda n: int(re.search(r'L(\d+)-', n).group(1)))
inline = "".join(f"<string>{f}</string>" for f in fonts)
block = "".join(f"\n    <string>{f}</string>" for f in fonts)
s = open('Widget/Info.plist').read()
s = re.sub(r'<key>UIAppFonts</key><array>.*?</array>',
           f'<key>UIAppFonts</key><array><string>Custom-Regular.otf</string>{inline}</array>', s, flags=re.S)
open('Widget/Info.plist', 'w').write(s)
s = open('App/Info.plist').read()
s = re.sub(r'  <key>UIAppFonts</key>\n  <array>.*?</array>\n',
           f'  <key>UIAppFonts</key>\n  <array>\n    <string>Custom-Regular.otf</string>{block}\n  </array>\n',
           s, flags=re.S)
open('App/Info.plist', 'w').write(s)
print(f"    UIAppFonts now lists {len(fonts)} lane fonts")
PY

echo "==> Installing on the phone"
xcodegen generate >/dev/null
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS,id=$DEVICE" -allowProvisioningUpdates \
    -derivedDataPath build/device build >/dev/null
xcrun devicectl device install app --device "$DEVICE" \
    build/device/Build/Products/Debug-iphoneos/Motionary.app >/dev/null
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null

python3 - <<'PY'
import json
m = json.load(open('Resources/prebuilt-manifest.json'))
loop = m['loopFrameCount'] / m['framesPerSecond']
print(f"==> Done: {m['laneCount']} lanes, {m['framesPerSecond']}fps, "
      f"{m['loopFrameCount']}-frame loop ({loop:.2f}s), "
      f"{m['totalFontBytes']/1048576:.1f}MB of fonts")
PY
