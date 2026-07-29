# Third-party notices

## WidgetAnimation

`Resources/MotionTemplate-Regular.ttf` and `Resources/Custom-Regular.otf` are
derived from Bryce Bostwick's MIT-licensed
[WidgetAnimation](https://github.com/brycebostwick/WidgetAnimation) sample, by
way of the moving-widget-lab project in this workspace. The shaping template
supplies the GSUB ligatures, cmap, and glyph outlines; Motionary replaces only
its `SVG ` and `name` tables at runtime.

## Trademarks

`Shared/AppCatalog.swift` lists third-party application names and URL schemes so
users can create shortcuts to apps they have installed. Those names and marks
remain the property of their owners and are not licensed by this project. No
third-party artwork is included: every tile is drawn from an SF Symbol.

## Iconify

The icon picker searches and downloads from the public
[Iconify](https://iconify.design) API (`api.iconify.design`), which needs no
account or key. Icons are fetched as SVG bodies, rasterised on device by
`Shared/Icons`, and cached in the app group so the widget never makes a network
request.

Iconify aggregates ~200 independent open-source icon sets, each under its own
licence — Apache 2.0, MIT, ISC, CC BY 4.0 and others. The picker shows the set
name and licence for whatever a search returns, taken from Iconify's
`/collections` endpoint. Anyone shipping a build is responsible for honouring
the licence of the sets they actually use.

Brand icons (notably the Simple Icons set) depict trademarks that remain the
property of their owners and are not licensed by this project.
