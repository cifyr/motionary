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
import os, re, sys

# Whitespace-tolerant, and the same pattern BundleWriter uses. The two regexes
# here used to demand `</key><array>` with nothing between them, which neither
# plist has ever been formatted as - so this step silently rewrote nothing
# while printing that it had listed N fonts, and a design bundled this way
# would install with its lanes undeclared and draw nothing.
PATTERN = r'(?s)<key>UIAppFonts</key>\s*<array>.*?</array>'


def rewrite(path, names):
    text = open(path).read()
    entries = "".join(f"\n    <string>{n}</string>" for n in names)
    new, count = re.subn(
        PATTERN, f'<key>UIAppFonts</key>\n  <array>{entries}\n  </array>', text
    )
    if count != 1:
        sys.exit(f"    {path}: expected one UIAppFonts array, matched {count}; "
                 "it may have been reformatted - fonts NOT updated")
    open(path, 'w').write(new)


fonts = sorted([f for f in os.listdir('Resources') if f.startswith('MFont') and f.endswith('.ttf')],
               key=lambda n: int(re.search(r'L(\d+)-', n).group(1)))
# The blink fonts drive which lane is visible and are not part of any design.
blink = ['Custom-Regular.otf', 'Blnk10-Regular.otf', 'Blnk05-Regular.otf',
         'Blnk15-Regular.otf', 'Blnk20-Regular.otf', 'Blnk30-Regular.otf']
rewrite('Widget/Info.plist', blink + fonts)
# The app gets none of the lane fonts. It never draws the lane stack - it plays
# the rendered video - and it no longer carries the files at all, so naming
# them would declare fonts the bundle does not hold and log a failure per font
# at every launch.
rewrite('App/Info.plist', blink)
print(f"    the widget's UIAppFonts now lists {len(fonts)} lane fonts; the app's lists none")
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
