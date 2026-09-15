#!/bin/bash
# Publishes a design to the scene catalogue, so that any installed copy of the
# app can download it without a new App Store release.
#
# This is the same package the Bonjour delivery and the Files import already
# accept - DesignPackage.write on one end, DesignDelivery.receive on the other.
# All that is added here is somewhere to put it and an index that names it.
#
#   Tools/publish-scene.sh [design-uuid-or-name]     newest design by default
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="$HOME/Library/Application Support/Motionary/Designs"
BASE_URL="https://vwkl9yq0e3a6cbr1.public.blob.vercel-storage.com"
ASKED="${1:-}"
cd "$ROOT"

# Explicit token, and never from inside site/. The CLI auto-loads that
# directory's .env.local, which carries a VERCEL_OIDC_TOKEN without the
# BLOB_STORE_ID that would have to accompany it, and then refuses every call.
TOKEN="$(grep -m1 '^BLOB_READ_WRITE_TOKEN=' site/.env.local 2>/dev/null | cut -d= -f2- | tr -d '"')"
if [ -z "$TOKEN" ]; then
    echo "failed: no BLOB_READ_WRITE_TOKEN in site/.env.local" >&2
    echo "        run: cd site && vercel env pull .env.local" >&2
    exit 1
fi

# Resolving the design here rather than letting --deliver pick the newest: the
# catalogue entry needs the id and the name anyway, and asking Studio for them
# would mean parsing its progress output.
read -r DESIGN_ID DESIGN_NAME <<EOF
$(/usr/bin/python3 - "$STORE" "$ASKED" <<'PY'
import json, os, sys
store, asked = sys.argv[1], sys.argv[2]
found = []
for d in os.listdir(store):
    path = os.path.join(store, d, "design.json")
    if not os.path.exists(path):
        continue
    j = json.load(open(path))
    found.append((os.path.getmtime(path), j.get("id", d), j.get("name", "Untitled")))
if not found:
    sys.exit("failed: no designs in the store")
if asked:
    match = [f for f in found if asked.lower() in (f[1].lower(), f[2].lower())]
    if not match:
        sys.exit(f"failed: no design called {asked}\n" +
                 "\n".join(f"  {i}  {n}" for _, i, n in found))
    found = match
else:
    found.sort(reverse=True)
print(found[0][1], found[0][2])
PY
)
EOF

echo "==> Publishing $DESIGN_NAME ($DESIGN_ID)"

# Checked before the package build, which takes a while, rather than after it.
for tool in ffmpeg ffprobe; do
    if ! command -v "$tool" >/dev/null; then
        echo "failed: $tool is needed for the gallery preview; brew install ffmpeg" >&2
        exit 1
    fi
done

STUDIO=build/mac/Build/Products/Debug/MotionaryStudio.app/Contents/MacOS/MotionaryStudio
if [ ! -x "$STUDIO" ]; then
    echo "==> Building the studio"
    xcodebuild -project Motionary.xcodeproj -scheme MotionaryStudio \
        -derivedDataPath build/mac build >/dev/null
fi

# Every file this publishes gets the time in its path. The CDN caches a blob URL
# for thirty days, so overwriting a scene in place would keep handing out the
# old package, still and preview to anyone who fetched them before; a new path
# is a URL nothing has cached. The catalogue is the one fixed URL, and it is
# served with a sixty second max-age for exactly that reason.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PACKAGE="$WORK/$DESIGN_ID.motionary"

echo "==> Building the package (composes wallpapers, takes a few minutes)"
"$STUDIO" --deliver "$PACKAGE" --design "$DESIGN_ID"
BYTES=$(stat -f%z "$PACKAGE")
echo "    $(du -h "$PACKAGE" | cut -f1)"

# A catalogue thumbnail, not the wallpaper itself: the full one is about 3MB
# and the list shows several at once.
PREVIEW="$WORK/$DESIGN_ID.jpg"
sips -s format jpeg -s formatOptions 70 -Z 900 \
    "$STORE/$DESIGN_ID/wallpaper.png" --out "$PREVIEW" >/dev/null

# The gallery's moving preview. The design's own preview.mp4 is only the clip
# layer - no tiles - so on its own it shows a sprite on a gradient rather than
# the Home Screen. This rebuilds the stack the widget draws: the wallpaper, the
# clip showing through inside the widget's rect, and the tiles back on top of
# it, found as wherever wallpaper.png differs from wallpaper-plain.png.
MOTION="$WORK/$DESIGN_ID.mp4"
DESIGN_DIR="$STORE/$DESIGN_ID"
read -r SW SH WX WY WW WH < <(/usr/bin/python3 - "$DESIGN_DIR/manifest.json" <<'PY2'
import json, sys
m = json.load(open(sys.argv[1]))
sw, sh = m["screenSize"]
(x, y), (w, h) = m["widgetRect"]
print(sw, sh, x, y, w, h)
PY2
)
read -r FRAMES RATE < <(ffprobe -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames,r_frame_rate -of csv=p=0 "$DESIGN_DIR/preview.mp4" \
    | awk -F, '{print $2, $1}')
echo "==> Rendering the gallery preview ($FRAMES frames at $RATE fps, widget ${WW}x${WH} at ${WX},${WY})"
# The stills loop at the clip's own rate and the output is resampled to it and
# cut at its frame count. Left at ffmpeg's 25fps, the merge emitted a frame at
# every still's tick as well as the clip's, so a trim by time added a frame
# (a 5 frame 0.31s loop became 6 frames, 0.37s) and a trim by count ended
# early (15s became 8.6s). No B-frames, so a loop a few frames long starts
# on its first frame.
# lut ramps the tile mask over a difference of 6 to 22 so the tiles' soft
# shadows fade into the clip instead of leaving a hard-edged halo.
ffmpeg -v error -y \
    -i "$DESIGN_DIR/preview.mp4" \
    -framerate "$RATE" -loop 1 -i "$DESIGN_DIR/wallpaper.png" \
    -framerate "$RATE" -loop 1 -i "$DESIGN_DIR/wallpaper-plain.png" \
    -filter_complex "
        [1:v]scale=${SW}:${SH},format=gbrp,split=2[wall][wallm];
        [2:v]scale=${SW}:${SH},format=gbrp[plain];
        [wallm][plain]blend=all_mode=difference,format=gray,lut=y='clip((val-6)*16\,0\,255)'[tiles];
        color=white:s=${SW}x${SH}:r=${RATE},format=gray,drawbox=x=${WX}:y=${WY}:w=${WW}:h=${WH}:color=black:t=fill[outside];
        [tiles][outside]blend=all_mode=lighten,format=gbrp[mask];
        [0:v]scale=${SW}:${SH},format=gbrp[clip];
        [clip][wall][mask]maskedmerge,fps=${RATE},scale=600:-2:flags=lanczos,format=yuv420p[out]" \
    -map "[out]" -frames:v "$FRAMES" -an -c:v libx264 -preset slow -crf 26 -bf 0 \
    -movflags +faststart "$MOTION"
GOT="$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$MOTION")"
if [ "$GOT" != "$FRAMES" ]; then
    echo "failed: gallery preview has $GOT frames, the clip has $FRAMES; not publishing a loop that stutters" >&2
    exit 1
fi
echo "    $(du -h "$MOTION" | cut -f1), $GOT frames"

echo "==> Uploading"
vercel blob put "$PACKAGE" --rw-token "$TOKEN" --access public \
    --pathname "scenes/$DESIGN_ID-$STAMP.motionary" \
    --content-type application/octet-stream >/dev/null
vercel blob put "$PREVIEW" --rw-token "$TOKEN" --access public \
    --pathname "previews/$DESIGN_ID-$STAMP.jpg" >/dev/null
vercel blob put "$MOTION" --rw-token "$TOKEN" --access public \
    --pathname "motion/$DESIGN_ID-$STAMP.mp4" --content-type video/mp4 >/dev/null

# The catalogue is rewritten whole each time, so the copy read here has to be
# the current one. The CDN keeps serving the previous upload for up to a minute,
# and reading that would silently drop whatever was published in between; the
# query string gets past it. A 404 means nothing is published yet.
CATALOG="$WORK/catalog.json"
STATUS="$(curl -sS -o "$CATALOG" -w '%{http_code}' "$BASE_URL/catalog.json?fresh=$(date +%s)" || echo 000)"
case "$STATUS" in
    200) ;;
    404)
        echo "    no catalogue yet, starting one"
        echo '{"version":1,"scenes":[]}' > "$CATALOG"
        ;;
    *)
        # Anything else is refused: starting from empty here would upload a
        # catalogue with only this scene in it and unlist everything else.
        echo "failed: reading the current catalogue returned HTTP $STATUS; nothing uploaded to it" >&2
        exit 1
        ;;
esac

/usr/bin/python3 - "$CATALOG" "$DESIGN_ID" "$DESIGN_NAME" "$BYTES" "$BASE_URL" "$STAMP" <<'PY'
import json, sys, datetime
path, did, name, size, base, stamp = sys.argv[1:7]
cat = json.load(open(path))
cat.setdefault("version", 1)
scenes = [s for s in cat.get("scenes", []) if s.get("id") != did]
scenes.append({
    "id": did,
    "name": name,
    "bytes": int(size),
    "published": datetime.date.today().isoformat(),
    "package": f"{base}/scenes/{did}-{stamp}.motionary",
    "preview": f"{base}/previews/{did}-{stamp}.jpg",
    "motion": f"{base}/motion/{did}-{stamp}.mp4",
    # Every scene carries this so a gate can be added later without shipping a
    # new app: anything the app does not recognise is shown as unavailable.
    "access": "free",
})
scenes.sort(key=lambda s: s["published"], reverse=True)
cat["scenes"] = scenes
json.dump(cat, open(path, "w"), indent=2)
print(f"    catalogue now lists {len(scenes)} scene(s)")
PY

# Sixty seconds rather than the thirty-day default: the packages never change
# under their own name, but the index that points at them does.
vercel blob put "$CATALOG" --rw-token "$TOKEN" --access public --allow-overwrite true \
    --pathname "catalog.json" --content-type application/json \
    --cache-control-max-age 60 >/dev/null

# A write to the store is not readable straight away: a catalogue read seconds
# after this upload came back without it. Waiting until it is means a second
# publish run immediately after this one reads a catalogue that includes this
# scene, instead of rewriting from the copy before it and dropping it.
echo "==> Waiting for the catalogue to show this publish"
for attempt in $(seq 1 30); do
    if curl -fsS "$BASE_URL/catalog.json?fresh=$(date +%s)-$attempt" 2>/dev/null | grep -q "$DESIGN_ID-$STAMP"; then
        echo "    visible after about $(( (attempt - 1) * 3 ))s"
        break
    fi
    if [ "$attempt" -eq 30 ]; then
        echo "failed: catalogue still does not list $DESIGN_ID-$STAMP after 90s; check it before publishing again" >&2
        exit 1
    fi
    sleep 3
done

echo
echo "==> Published"
echo "    catalogue  $BASE_URL/catalog.json"
echo "    package    $BASE_URL/scenes/$DESIGN_ID-$STAMP.motionary"
echo "    preview    $BASE_URL/previews/$DESIGN_ID-$STAMP.jpg"
echo "    motion     $BASE_URL/motion/$DESIGN_ID-$STAMP.mp4"
