#!/usr/bin/env python3
"""Build the App Store listing's screenshots at the 6.9" size, 1320x2868.

What was there before was two raw simulator captures, and the Home Screen one
showed the widget over Apple's stock blue wallpaper - a lone rectangle on an
unrelated background, which is the opposite of what the app does. These frames
are built from the composition the app actually produces: the design's own
wallpaper, the clip showing through inside the widget's rect, and the tiles
baked back over it.

The ground behind each phone is that same picture, scaled past the frame and
blurred. The app's premise is a picture that carries on past the widget's edge,
so a ground that carries on past the device says it before the headline does.

Needs the designs in Application Support and the app screens captured by
MotionaryUITests/StoreShotTests, so it runs on the Mac that built them.

  Tools/store-frames.py [output-directory]      default: build/store-frames
"""

import html
import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
STORE = pathlib.Path.home() / "Library/Application Support/Motionary/Designs"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1320, 2868

# Every scene is cut for this screen, so the phone's aspect and the widget's
# rect inside it are read from the design rather than assumed.
SCENES = {
    "aesthetic": ("EDDFE0C5-DDE6-4721-B739-B2FD582D0A6C", 2.0),
    "games": ("58737EDB-8407-4F09-B3CB-BFF8CB51125E", 0.12),
}


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"failed: {' '.join(args[:3])}...\n{result.stderr[-600:]}")
    return result


def composite(design_id, seek, out):
    """One still of the real Home Screen for a design."""
    folder = STORE / design_id
    manifest = json.loads((folder / "manifest.json").read_text())
    sw, sh = manifest["screenSize"]
    (wx, wy), (ww, wh) = manifest["widgetRect"]
    # The tiles are wherever the baked wallpaper differs from the plain one, and
    # the lut ramps that difference so their soft shadows fade into the clip
    # instead of leaving a hard-edged halo.
    run("ffmpeg", "-v", "error", "-y", "-ss", str(seek), "-i", str(folder / "preview.mp4"),
        "-i", str(folder / "wallpaper.png"), "-i", str(folder / "wallpaper-plain.png"),
        "-filter_complex",
        f"[1:v]scale={sw}:{sh},format=gbrp,split=2[wall][wallm];"
        f"[2:v]scale={sw}:{sh},format=gbrp[plain];"
        f"[wallm][plain]blend=all_mode=difference,format=gray,lut=y='clip((val-6)*16\\,0\\,255)'[tiles];"
        f"color=white:s={sw}x{sh},format=gray,"
        f"drawbox=x={wx}:y={wy}:w={ww}:h={wh}:color=black:t=fill[outside];"
        f"[tiles][outside]blend=all_mode=lighten,format=gbrp[mask];"
        f"[0:v]scale={sw}:{sh},format=gbrp[clip];"
        f"[clip][wall][mask]maskedmerge,format=rgb24[out]",
        "-map", "[out]", "-frames:v", "1", str(out))
    return manifest


CSS = """
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: %(W)spx; height: %(H)spx; overflow: hidden; background: #000; }
.frame { position: relative; width: %(W)spx; height: %(H)spx; overflow: hidden; }

.ground {
  position: absolute; inset: -8%%;
  background-image: var(--scene);
  background-size: cover; background-position: var(--ground-pos, center);
  filter: blur(46px) saturate(1.5) brightness(var(--ground-light));
  transform: scale(1.14);
}
/* Darkest where the type sits, and never so dark at the top that the scene's
   own colour is lost - that colour is what ties a frame to what it shows. */
.shade {
  position: absolute; inset: 0;
  background:
    linear-gradient(180deg, rgba(0,0,0,.66) 0%%, rgba(0,0,0,.40) 22%%, rgba(0,0,0,.10) 38%%, rgba(0,0,0,.26) 100%%),
    radial-gradient(130%% 58%% at 50%% 66%%, rgba(0,0,0,0) 30%%, rgba(0,0,0,.42) 100%%);
}
/* Light pooling behind the device, so the scene reads as spilling out of it. */
.halo {
  position: absolute; left: 50%%; top: var(--phone-top); width: var(--phone-w);
  aspect-ratio: 1206 / 2622; transform: translateX(-50%%) scale(1.06);
  background: var(--scene); background-size: cover; background-position: top center;
  filter: blur(120px) saturate(1.9) brightness(1.25); opacity: .85;
}

.copy { position: absolute; top: 150px; left: 94px; right: 94px; }
h1 {
  /* Condensed Black carries a poster's weight and packs into a narrow column,
     which is what keeps a headline readable at App Store thumbnail size. */
  font-family: "HelveticaNeue-CondensedBlack", "Helvetica Neue", sans-serif;
  font-size: var(--size, 138px); line-height: .88; letter-spacing: -.022em;
  color: #fff;
  text-shadow: 0 4px 44px rgba(0,0,0,.6), 0 1px 3px rgba(0,0,0,.5);
}
p.sub {
  margin-top: 34px; max-width: 26ch;
  font-family: "Helvetica Neue", sans-serif; font-weight: 400;
  font-size: 42px; line-height: 1.34; letter-spacing: -.005em;
  color: rgba(255,255,255,.80);
  text-shadow: 0 2px 22px rgba(0,0,0,.65);
}

/* Cropped by the bottom edge on purpose: a whole phone floating in the middle
   reads as a product photo, a cropped one reads as a thing in use. */
.phone {
  position: absolute; left: 50%%; transform: translateX(-50%%);
  top: var(--phone-top, 912px); width: var(--phone-w, 920px);
  aspect-ratio: 1206 / 2622;
  border-radius: 84px; padding: 13px;
  background: linear-gradient(160deg, #6f7176 0%%, #24262b 22%%, #15171b 58%%, #3d4045 88%%, #191b1f 100%%);
  box-shadow:
    0 6px 0 rgba(255,255,255,.10) inset,
    0 70px 130px -30px rgba(0,0,0,.85),
    0 18px 44px rgba(0,0,0,.55);
}
.screen {
  position: relative; width: 100%%; height: 100%%;
  border-radius: 72px; overflow: hidden;
  background-image: var(--scene); background-size: cover;
  background-position: var(--scene-pos, top center);
}
.screen::after {
  content: ""; position: absolute; inset: 0; border-radius: 72px;
  background: linear-gradient(104deg, rgba(255,255,255,.16) 0%%, rgba(255,255,255,0) 18%%);
}
.island {
  position: absolute; top: 20px; left: 50%%; transform: translateX(-50%%);
  width: 232px; height: 68px; border-radius: 34px; background: #000;
}
.status {
  position: absolute; top: 34px; left: 0; right: 0; height: 40px;
  display: flex; align-items: center; justify-content: space-between; padding: 0 62px;
  font-family: "SF Pro Text", "Helvetica Neue", sans-serif; font-weight: 600;
  font-size: 34px; color: #fff;
  text-shadow: 0 1px 6px rgba(0,0,0,.75), 0 0 2px rgba(0,0,0,.6);
}
.status .glyphs { display: flex; align-items: center; gap: 12px; }
.status svg { display: block; }

/* The widget's boundary. Everything outside it is dimmed, so the extent reads
   before either label does. */
.seam {
  position: absolute; border: 5px solid rgba(255,255,255,.95);
  box-shadow: 0 0 0 4000px rgba(0,0,0,.42);
  left: var(--seam-x); top: var(--seam-y);
  width: var(--seam-w); height: var(--seam-h);
}
.seam-tag, .seam-note {
  position: absolute; left: -5px; padding: 10px 18px 12px;
  background: rgba(255,255,255,.92);
  font-family: "Helvetica Neue", sans-serif; font-weight: 700; font-size: 34px;
  letter-spacing: -.01em; color: #101114; white-space: nowrap;
}
.seam-tag { top: -5px; transform: translateY(-100%%); }
.seam-note { bottom: -5px; transform: translateY(100%%); }
""" % {"W": W, "H": H}

STATUS = """
<div class="status">
  <span>9:41</span>
  <span class="glyphs">
    <svg width="38" height="28" viewBox="0 0 38 28"><g fill="#fff">
      <rect x="0" y="18" width="6" height="10" rx="2"/><rect x="10" y="12" width="6" height="16" rx="2"/>
      <rect x="20" y="6" width="6" height="22" rx="2"/><rect x="30" y="0" width="6" height="28" rx="2"/>
    </g></svg>
    <svg width="34" height="26" viewBox="0 0 34 26"><path fill="#fff" d="M17 24.5 13.3 20a5.4 5.4 0 0 1 7.4 0zM9.6 16a11.3 11.3 0 0 1 14.8 0l2.5-3a15.3 15.3 0 0 0-19.8 0zM2.3 8.2A22.4 22.4 0 0 1 31.7 8.2l2.3-2.8a26.4 26.4 0 0 0-34 0z"/></svg>
    <svg width="48" height="24" viewBox="0 0 48 24"><rect x="1" y="3" width="40" height="18" rx="5" fill="none" stroke="#fff" stroke-opacity=".6" stroke-width="2"/><rect x="4" y="6" width="34" height="12" rx="3" fill="#fff"/><path fill="#fff" fill-opacity=".5" d="M44 9v6a4 4 0 0 0 0-6z"/></svg>
  </span>
</div>
"""


def render(out_dir, name, scene, headline, sub=None, size=138, phone_w=920, phone_top=912,
           ground_light=0.74, ground_pos="center", scene_pos="top center", seam=None):
    seam_html = seam_style = ""
    if seam:
        tag, note, manifest = seam
        sw, sh = manifest["screenSize"]
        (wx, wy), (ww, wh) = manifest["widgetRect"]
        seam_style = (f"--seam-x:{wx / sw:.4%}; --seam-y:{wy / sh:.4%};"
                      f"--seam-w:{ww / sw:.4%}; --seam-h:{wh / sh:.4%};")
        seam_html = (f'<div class="seam"><div class="seam-tag">{html.escape(tag)}</div>'
                     f'<div class="seam-note">{html.escape(note)}</div></div>')

    uri = pathlib.Path(scene).resolve().as_uri()
    doc = f"""<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head><body>
    <div class="frame" style="--scene:url('{uri}'); --size:{size}px; --phone-w:{phone_w}px;
         --phone-top:{phone_top}px; --ground-light:{ground_light}; --ground-pos:{ground_pos};
         --scene-pos:{scene_pos}; {seam_style}">
      <div class="ground"></div><div class="shade"></div><div class="halo"></div>
      <div class="copy"><h1>{headline}</h1>{f'<p class="sub">{html.escape(sub)}</p>' if sub else ''}</div>
      <div class="phone"><div class="screen">{STATUS}<div class="island"></div>{seam_html}</div></div>
    </div></body></html>"""

    src = out_dir / f".{name}.html"
    src.write_text(doc)
    png = out_dir / f"{name}.png"
    run(CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
        f"--window-size={W},{H}", "--force-device-scale-factor=1",
        f"--screenshot={png}", src.as_uri())
    src.unlink()
    print(f"  {png.name}")


def main():
    out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build/store-frames"
    out.mkdir(parents=True, exist_ok=True)
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            sys.exit(f"failed: {tool} is needed to build the composites; brew install ffmpeg")
    if not pathlib.Path(CHROME).exists():
        sys.exit("failed: Google Chrome renders the frames and is not installed")

    shots = out / "source"
    shots.mkdir(exist_ok=True)
    manifests = {}
    for name, (design_id, seek) in SCENES.items():
        if not (STORE / design_id).exists():
            sys.exit(f"failed: design {design_id} is not in the store; build it in Studio first")
        manifests[name] = composite(design_id, seek, shots / f"{name}.png")
        print(f"  composited {name}")

    # Captured by MotionaryUITests/StoreShotTests, which photographs the screens
    # these frames are made of.
    for needed in ("store-editing.png", "gallery.png"):
        if not (shots / needed).exists():
            print(f"  note: {shots / needed} is missing - run StoreShotTests and "
                  f"ScenesGalleryTests, then copy their shots here")

    render(out, "01-hero", shots / "aesthetic.png",
           "Your whole<br>Home Screen,<br>and it moves.",
           sub="A clip plays inside the widget. The wallpaper carries the rest of the picture.")
    render(out, "02-launch", shots / "games.png",
           "Tap the picture.<br>It opens the app.",
           sub="Every spot on a scene is a launcher you choose: an app, a link, or a search.",
           ground_light=0.78, ground_pos="50% 88%")
    render(out, "03-seam", shots / "games.png",
           "The widget and<br>the wallpaper<br>line up exactly.",
           sub="Inside the frame it animates. Outside, the same picture carries on.",
           ground_light=0.78, ground_pos="50% 88%",
           seam=("This part animates", "The picture carries on", manifests["games"]))
    if (shots / "store-editing.png").exists():
        render(out, "04-spots", shots / "store-editing.png",
               "Every spot is<br>yours to change.",
               sub="Swap the icon, point it at a different app, or leave the spot empty.")
    if (shots / "gallery.png").exists():
        render(out, "05-library", shots / "gallery.png",
               "New scenes,<br>no update<br>needed.",
               sub="Designs published after you install appear in the app, "
                   "playing before you download.",
               ground_light=0.52)
    print(f"\n==> {out}")


if __name__ == "__main__":
    main()
