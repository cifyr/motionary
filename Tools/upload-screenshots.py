#!/usr/bin/env python3
"""Replaces one App Store version's screenshots with the rendered frames.

    Tools/store-frames.py                  # renders build/store-frames
    ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_APP_ID=... \
        Tools/upload-screenshots.py 1.2

Only the named version is touched, so a live version keeps the frames it was
approved with, and the source PNGs stay on disk. 6.5, 6.7 and 6.9 inch iPhones
all take one set: APP_IPHONE_67. There is no APP_IPHONE_69, and asking for one
is rejected.
"""
import hashlib, os, pathlib, sys, time, urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from asc import app_id, call, errors

ROOT = pathlib.Path(__file__).resolve().parent.parent
FRAMES_DIR = ROOT / "build" / "store-frames"
DISPLAY = "APP_IPHONE_67"


def frames():
    found = sorted(FRAMES_DIR.glob("*.png"))
    if not found:
        raise SystemExit(f"no frames in {FRAMES_DIR}; run Tools/store-frames.py first")
    return found


def version_id(wanted):
    status, body = call("GET", f"/v1/apps/{app_id()}/appStoreVersions?limit=200")
    if status >= 300:
        raise SystemExit(f"listing versions failed: {errors(body)}")
    for d in body["data"]:
        if d["attributes"]["versionString"] == wanted:
            return d["id"], d["attributes"]["appStoreState"]
    have = ", ".join(d["attributes"]["versionString"] for d in body["data"])
    raise SystemExit(f"no version {wanted} on the app record; it has {have}")


def upload(path, set_id):
    """Reserve, PUT every part the API asks for, then commit with a checksum.
    The commit is what makes the asset real; without it the screenshot sits in
    the set as an empty reservation and the web UI shows it as broken."""
    data = path.read_bytes()
    status, body = call("POST", "/v1/appScreenshots", {"data": {
        "type": "appScreenshots",
        "attributes": {"fileSize": len(data), "fileName": path.name},
        "relationships": {"appScreenshotSet": {
            "data": {"type": "appScreenshotSets", "id": set_id}}}}})
    if status >= 300:
        print(f"  {path.name}: could not reserve, {errors(body)}")
        return None
    shot = body["data"]["id"]
    for op in body["data"]["attributes"]["uploadOperations"]:
        request = urllib.request.Request(
            op["url"], data=data[op["offset"]:op["offset"] + op["length"]], method=op["method"])
        for header in op["requestHeaders"]:
            request.add_header(header["name"], header["value"])
        urllib.request.urlopen(request, timeout=180).read()
    status, body = call("PATCH", f"/v1/appScreenshots/{shot}", {"data": {
        "type": "appScreenshots", "id": shot,
        "attributes": {"uploaded": True,
                       "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    state = (body.get("data", {}).get("attributes", {}).get("assetDeliveryState") or {}).get("state")
    print(f"  {path.name}  {len(data) // 1024}KB  {status} {state}")
    return shot


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: Tools/upload-screenshots.py <version, e.g. 1.2>")
    version, state = version_id(sys.argv[1])
    print(f"==> version {sys.argv[1]} ({state})")

    status, body = call("GET", f"/v1/appStoreVersions/{version}/appStoreVersionLocalizations")
    if status >= 300:
        raise SystemExit(f"reading localizations failed: {errors(body)}")
    localization = body["data"][0]["id"]

    status, body = call(
        "GET",
        f"/v1/appStoreVersionLocalizations/{localization}/appScreenshotSets?include=appScreenshots")
    target = next((d["id"] for d in body.get("data", [])
                   if d["attributes"].get("screenshotDisplayType") == DISPLAY), None)
    for shot in [x for x in body.get("included", []) if x["type"] == "appScreenshots"]:
        code, _ = call("DELETE", f"/v1/appScreenshots/{shot['id']}")
        print(f"  removed {shot['attributes'].get('fileName')}: {code}")

    if target is None:
        status, body = call("POST", "/v1/appScreenshotSets", {"data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": DISPLAY},
            "relationships": {"appStoreVersionLocalization": {
                "data": {"type": "appStoreVersionLocalizations", "id": localization}}}}})
        if status >= 300:
            raise SystemExit(f"creating the set failed: {errors(body)}")
        target = body["data"]["id"]

    uploaded = [shot for shot in (upload(p, target) for p in frames()) if shot]

    # Creation order is not display order, so it is stated.
    status, body = call("PATCH", f"/v1/appScreenshotSets/{target}/relationships/appScreenshots",
                        {"data": [{"type": "appScreenshots", "id": i} for i in uploaded]})
    print(f"==> ordered {len(uploaded)} frames: {status} {errors(body)}")

    # The web UI has shown screenshots that the API reports as absent, so the
    # set is read back rather than trusted.
    time.sleep(5)
    status, body = call(
        "GET",
        f"/v1/appStoreVersionLocalizations/{localization}/appScreenshotSets?include=appScreenshots")
    final = [x for x in body.get("included", []) if x["type"] == "appScreenshots"]
    print(f"==> the set now holds {len(final)}")
    for shot in final:
        attributes = shot["attributes"]
        print(f"  {attributes.get('fileName')}  "
              f"{(attributes.get('assetDeliveryState') or {}).get('state')}")


if __name__ == "__main__":
    main()
