# What stands between this and the App Store

Checked on 2026-08-14 against a Release archive, a clean-simulator first run on
two different iPhones, the signed binaries, and both Info.plists. Everything
below was run rather than reasoned about; where something could not be checked,
it says so.

## Blocks the upload

**There is no app icon.** No asset catalog exists anywhere in the project, and a
clean install shows a blank grey placeholder on the Home Screen. App Store
Connect will not accept a build without one.

**There is no `PrivacyInfo.xcprivacy`.** Required since May 2024. The app uses at
least two required-reason APIs — `UserDefaults` (`CA92.1`) and file timestamps
(`C617.1`) — and a build without the manifest declaring them is rejected
automatically.

**There are no App Store distribution profiles.** `xcodebuild -exportArchive`
fails on both targets:

```
error: exportArchive No profiles for 'com.caden.Motionary' were found
error: exportArchive No profiles for 'com.caden.Motionary.widget' were found
```

Archiving itself succeeds — this is a portal prerequisite, not a code fault.

## Very likely rejected

**About seventy recreated third-party brand icons ship in the bundle.** 269 PNGs,
90MB, covering Spotify, Instagram, Netflix, TikTok, Snapchat, WhatsApp, Discord,
Reddit, Uber, Amazon, Chrome, Gmail, YouTube, X, Roblox, Clash Royale, ChatGPT,
Teams, Zoom and more. Redrawing another company's mark and shipping it is what
icon-pack and theming apps are routinely rejected for. It is also the one item
here that is a legal question rather than a technical one.

**HealthKit is linked but not entitled.** `ReadoutGatherer` calls
`HKHealthStore.requestAuthorization` and `App/Info.plist` declares
`NSHealthShareUsageDescription`, but `App/Motionary.entitlements` contains only
the app group. Without `com.apple.developer.healthkit` the request fails at
runtime, so the steps readout is dead in any shipping build — and a binary that
links HealthKit without the entitlement draws review attention on its own.

**WeatherKit is linked, not entitled, and not attributed.** Same shape:
`WeatherService.shared.weather(for:)` is called, `com.apple.developer.weatherkit`
is absent, so it throws. Separately, WeatherKit's terms require the Apple Weather
trademark and a link to the legal attribution page wherever the data appears.
Neither string exists anywhere in the source.

## Serious, and by design rather than by accident

**The build is cut for exactly one phone.** `DeviceModel.all` holds a single
entry and `DeviceGeometry.model` is a compile-time constant, which the code says
plainly: "the iOS app and the extension are compiled for exactly one phone".
That is coherent for a personal build and incoherent for a store listing, where
every iPhone can install it:

| device | screen | wallpaper mismatch |
| --- | --- | --- |
| iPhone 17 Pro | 1206x2622 | exact |
| iPhone 16e | 1170x2532 | 36 x 90px oversized |
| iPhone 16 Plus | 1290x2796 | 84 x 174px short |
| iPhone 17 Pro Max | 1320x2868 | 114 x 246px short |

The widget rect, corner radius and icon grid are all calibrated to the 17 Pro as
well, so on any other phone the artwork does not sit under the icons it was
drawn for.

**The app is 506MB.** 90MB of icons and 44MB of lane fonts in the app, 254MB in
the widget extension. Under the 4GB ceiling, far over the size at which iOS warns
about a cellular download, and very large for something that draws one widget.

## Small

**`ITSAppUsesNonExemptEncryption` is not set.** Not a rejection, but every single
upload will stop and ask the export-compliance question until it is.

## What passed

- **The archive builds.** `ARCHIVE SUCCEEDED`, 506MB.
- **No private API in the shipping binaries.** The
  `_wantsCustomFontsEmbeddedInArchive` shim is correctly confined to
  `FONT_EMBED_PROBE`; `nm -u` finds it in neither the app nor the extension.
- **First run works on a clean device.** No empty state, no permission wall, no
  crash — the bundled starter design draws immediately. Verified on two
  simulators with no prior data.
- **643 unit tests and 2 UI tests pass.**
- **Launching other apps needs no `LSApplicationQueriesSchemes`.** The router
  calls `UIApplication.open` directly and never `canOpenURL`, so the absent
  declaration is correct rather than an oversight.
- **`UILaunchScreen` present, orientation locked to portrait, app group
  entitlements consistent across both targets.**

## Not checked

- Behaviour on a physical device other than the iPhone 17 Pro.
- Anything requiring App Store Connect credentials, including the real upload
  validation that runs server-side.
- VoiceOver, Dynamic Type and RTL layout.
- The widget under system memory pressure, as opposed to at rest.
