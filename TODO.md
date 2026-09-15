# TODO

Where the project stands and what is next. Written for picking the work back up
cold, so it records the decisions still open as well as the work still to do.

Last release: **1.1, build 4**, approved and releasing. Two scenes published to
the catalogue: Spidey Swing and Video Games.

## Next release: 1.2

The scene library shipped in 1.1 but it sits at the bottom of the Design
options sheet, five swipes down, which is where nobody found it. 1.2 moves it
onto the Home Screen itself and teaches the library to talk about subscenes.

A subscene is a `ClipVariant`: another clip for the same scene, same layout and
same crop, picked on the phone. Studio calls them animation variants,
`BuildManifest.clipSequence` is the list, `VariantChoice` stores the pick.

### 1. A library page at the end of the pager

`App/HomeView.swift`

- Pages become the installed scenes plus one library page at the end.
- Swipes clamp rather than wrap, so the last right swipe lands on the library
  and one more does nothing.
- `ActiveDesign` is not rewritten while the library page is up, so the widget
  on the real Home Screen keeps showing the last scene.
- `PageDots` draws the final dot differently.
- The page is the dark ground, the `MORE SCENES` wordmark, and one
  `Download from library` button that opens `ScenesView` in its own
  `NavigationStack` as a full screen cover.
- On install: dismiss the cover, select the new scene, reload the pager.

Done when a fresh install can reach the library without opening any sheet, and
the widget does not change while the library page is on screen.

### 2. The library says how many subscenes a scene carries

`Tools/publish-scene.sh`, `App/SceneCatalog.swift`, `App/ScenesView.swift`

- The publish script reads the clip count out of the package header
  (`MOTNPKG1`, a `UInt32` length, then the JSON header carrying `manifest`)
  and writes `clips` and `clipNames` into `catalog.json`.
- Both fields optional, so 1.1 keeps decoding the catalogue.
- Card gets a `14 CLIPS` tag when `clips > 1`. The detail screen lists names.
- The live entries can be backfilled without re-uploading the packages: the
  header is readable with a range request, which is how the counts below were
  measured.

Counts today: Video Games 14 (Mario, Car, Pacman2, Pokemon2, FloatingCity,
Atari, Fight2, Fight1, Fish, LevelUp, Cat, Pacman1, Fight3, Pokemon1).
Spidey Swing 1, because its two variants were built with Playback set to
`Shuffle after every clip`, which compiles them into one shuffled programme
instead of a list the phone can pick from. Rebuild it on `One clip` if those
should be selectable.

### 3. Installed scenes leave the library

`App/ScenesView.swift`

- The grid filters out anything already on the phone.
- A quiet line says how many are hidden, so a short grid reads as filtered
  rather than broken, and a different line covers the case where everything
  published is installed.
- `SceneLibrary.use(_:)` and the `Use this scene` button go away with the card.
  Selecting an installed scene is a swipe on the pager now.

### 4. An installed scene shows that it has subscenes

`App/HomeView.swift`

**Open decision.** Two ways, pick one:

- *Vertical swipe.* Outside edit mode a vertical swipe steps through the
  scene's clips, with a short column of dots on the right edge whenever
  `clipSequence.count > 1` and the design is not shuffled. Horizontal moves
  between scenes, vertical within one. Recommended: the dots are what announce
  the subscenes, and the gesture is right there.
- *Badge only.* A static `14 clips` label near the page dots that says the
  subscenes exist without offering a way through them.

Either way the edit-mode swipe and the options sheet picker stay as they are.

### 5. Ship it

- `project.yml`: `MARKETING_VERSION` 1.2, `CURRENT_PROJECT_VERSION` 5.
- Tests: catalogue decode with and without `clips`, the pager clamp as a
  testable helper, a UI test that swipes to the library page, a UI test that
  steps subscenes.
- `docs/app-store-listing.md`: What's New for 1.2.
- Archive through Xcode Cloud, not locally. See the note below.

## Decisions waiting on Caden

- Part 4 above: vertical swipe or badge only.
- Merge `feat/scene-catalog` into `main`. The Xcode Cloud workflow's automatic
  start condition points at `main`, which does not yet carry the committed
  starter design or `ci_scripts`, so a push-triggered build fails until the
  merge happens.
- Delete roughly 80MB of unreferenced blobs: the first, unstamped uploads of
  both scenes, superseded by the stamped paths the catalogue points at.
- The App Preview video, deferred during the 1.1 submission. Record the app's
  own screen on the simulator, 15 to 30 seconds, upload under `IPHONE_67`.
  Check Apple's accepted preview resolutions before recording.

## Smaller things

- `docs/app-store-readiness.md` does not yet record the three things that
  actually cost the most time: that a beta macOS stamps `BuildMachineOSBuild`
  and Apple rejects the upload for it, the move to Xcode Cloud that solved it,
  and the Guideline 2.1 and 4.2 exchanges.

## Publishing a scene, the loop that works

Studio is at `build/mac/Build/Products/Debug/MotionaryStudio.app`, or build the
`MotionaryStudio` scheme.

1. Library, `New design`, pick an MP4, MOV or GIF. The loop caps at 320 frames,
   and a scene that will be published is limited by the blink mask's period, so
   10 seconds is the real ceiling.
2. Position the clip on the canvas. Inside the widget frame animates, outside
   becomes the wallpaper.
3. Drop tiles on the icon grid. Artwork from SF Symbols or Iconify.
4. `Animation variants`, `Add...`, one clip per subscene. Leave Playback on
   `One clip` so the phone can pick between them.
5. Build.
6. `Tools/publish-scene.sh "Scene Name"`. Builds the package, renders the still
   and the moving preview, uploads all three, rewrites `catalog.json`, then
   waits until the new catalogue is actually readable before returning.

Needs `ffmpeg` and `BLOB_READ_WRITE_TOKEN` in `site/.env.local`
(`cd site && vercel env pull .env.local`). Never run the Vercel CLI from inside
`site/`: it auto-loads a `VERCEL_OIDC_TOKEN` without the `BLOB_STORE_ID` that
would have to accompany it, and then refuses every call.

## Things worth not rediscovering

- **Archive through Xcode Cloud.** A local archive on this Mac stamps
  `BuildMachineOSBuild` with a macOS 27 beta build, and App Store Connect
  rejects the upload with ITMS-90111. There is no Xcode 27 release to fall back
  to, so the cloud is the route until macOS 27 ships.
- **Designs live outside the repo**, at
  `~/Library/Application Support/Motionary/Designs/<uuid>/`. One starter is
  committed so a clone can build the app.
- **The catalogue is one fixed URL** with a 60 second max-age; every package,
  still and preview carries a UTC stamp in its path because the CDN caches a
  blob URL for 30 days.
- Tests:
  `xcodebuild -scheme Motionary -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MotionaryTests test`
