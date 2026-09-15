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

STUDIO=build/mac/Build/Products/Debug/MotionaryStudio.app/Contents/MacOS/MotionaryStudio
if [ ! -x "$STUDIO" ]; then
    echo "==> Building the studio"
    xcodebuild -project Motionary.xcodeproj -scheme MotionaryStudio \
        -derivedDataPath build/mac build >/dev/null
fi

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

echo "==> Uploading"
vercel blob put "$PACKAGE" --rw-token "$TOKEN" --access public --allow-overwrite true \
    --pathname "scenes/$DESIGN_ID.motionary" \
    --content-type application/octet-stream >/dev/null
vercel blob put "$PREVIEW" --rw-token "$TOKEN" --access public --allow-overwrite true \
    --pathname "previews/$DESIGN_ID.jpg" >/dev/null

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

/usr/bin/python3 - "$CATALOG" "$DESIGN_ID" "$DESIGN_NAME" "$BYTES" "$BASE_URL" <<'PY'
import json, sys, datetime
path, did, name, size, base = sys.argv[1:6]
cat = json.load(open(path))
cat.setdefault("version", 1)
scenes = [s for s in cat.get("scenes", []) if s.get("id") != did]
scenes.append({
    "id": did,
    "name": name,
    "bytes": int(size),
    "published": datetime.date.today().isoformat(),
    "package": f"{base}/scenes/{did}.motionary",
    "preview": f"{base}/previews/{did}.jpg",
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

echo
echo "==> Published"
echo "    catalogue  $BASE_URL/catalog.json"
echo "    package    $BASE_URL/scenes/$DESIGN_ID.motionary"
echo "    preview    $BASE_URL/previews/$DESIGN_ID.jpg"
