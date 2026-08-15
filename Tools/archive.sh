#!/bin/bash
# Archives the app for the App Store and, if the portal has the profiles for
# it, exports the .ipa ready to upload.
#
# Archiving and exporting fail for entirely different reasons, so they are
# reported separately: the archive is this machine's business and either works
# or has a real build error in it, while the export needs App Store
# distribution profiles for com.caden.Motionary and com.caden.Motionary.widget,
# which only exist once someone has made them in the developer portal. An
# export that fails on a missing profile is not a broken build.
#
#   Tools/archive.sh [output-directory]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/release}"
ARCHIVE="$OUT/Motionary.xcarchive"
cd "$ROOT"

mkdir -p "$OUT"

echo "==> Archiving (Release, generic iOS device)"
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" archive

echo
echo "==> What is in it"
APP="$ARCHIVE/Products/Applications/Motionary.app"
du -sh "$APP"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist" \
    | sed 's/^/    version /'
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist" \
    | sed 's/^/    build   /'

# The icon and the privacy manifest are both things App Store Connect rejects
# for silently, and both are easy to lose to a project regeneration - so the
# archive says whether they actually made it in rather than being taken on
# trust.
for required in "Assets.car" "PrivacyInfo.xcprivacy" "AppIcon60x60@2x.png"; do
    if [ -e "$APP/$required" ]; then
        echo "    ok      $required"
    else
        echo "    MISSING $required" >&2
    fi
done
if [ -e "$APP/PlugIns/MotionaryWidgetExtension.appex/PrivacyInfo.xcprivacy" ]; then
    echo "    ok      widget PrivacyInfo.xcprivacy"
else
    echo "    MISSING widget PrivacyInfo.xcprivacy" >&2
fi

echo
echo "==> Exporting"
if xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$ROOT/Tools/ExportOptions.plist" \
    -exportPath "$OUT" 2>&1 | tee "$OUT/export.log" | tail -5; then
    echo "==> $OUT/Motionary.ipa"
else
    echo
    echo "The archive is fine; the export is not. If the log above says" >&2
    echo "\"No profiles for 'com.caden.Motionary'\", the App Store distribution" >&2
    echo "profiles have not been created in the developer portal yet - that is" >&2
    echo "a portal prerequisite, not a build fault." >&2
    exit 1
fi
