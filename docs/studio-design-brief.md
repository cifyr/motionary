# Motionary Studio — editor design brief

A reusable prompt for design passes over the studio's layout editor, plus the
decisions the current implementation follows. Hand the "Brief" section to a
designer (or a model) whole; it pins down what may not change and where taste
is welcome.

## Brief

Design the layout editor for Motionary Studio, a native macOS (SwiftUI) tool
whose one job is: drop in a video clip, place app launcher tiles and decorative
pictures over it, theme them, and build the result onto an iPhone Home Screen.

The user is a solo developer moving fast. They open the editor a few times a
week, always mid-idea. Optimize for: nothing buried, nothing modal that could
be inline, and precision when a hand-drag is not precise enough.

Hard constraints — these may not change:

- The canvas is a fixed-geometry phone screen (pixel-exact; zoom is a constant).
  Its layer order is wallpaper, clip, pictures, tiles, and the dashed widget
  frame means "only this region animates and answers taps."
- One shared position transform for the clip and all its variants.
- Everything persists through `DesignDocument`; the editor is a pure view over
  it. Autosave and undo already exist and must keep working.
- AppKit idioms: sidebar inspectors, segmented tabs, keyboard nudge, native
  focus rings. No custom chrome for its own sake.

The three failures to design out:

1. **One long scrolling sidebar.** Scene settings, libraries, and the selected
   item's controls all stack in a single 240pt column; the selected tile's
   inspector lands at the bottom, below the fold.
2. **Adding apps is hidden and messy.** One button opens a popover catalogue,
   and every new tile drops on the same spot at the widget's center, stacking.
3. **Lining things up is invisible.** Snapping exists but there are no align
   actions, no keyboard nudge, no numeric position - a row of tiles is made by
   eye or not at all.

The design's organizing idea (keep it): **the inspector answers "what am I
editing right now."** Selection drives the top of the sidebar - a tile shows
tile controls, a picture shows picture controls, nothing selected means the
scene itself is selected. Libraries (apps, looks, pictures, clips) live below
in tabs and never reorder or disappear.

Deliver: the sidebar's structure, the selection inspector for each state, the
add-and-align flows, and the empty states' copy. Copy is design material:
plain verbs, sentence case, name things by what the user controls.

## Decisions implemented (first pass)

- Sidebar = **inspector over library**. Inspector switches on selection:
  Scene (nothing selected) / App tile / Picture. Library is a segmented
  control: **Apps · Looks · Pictures · Clips**.
- Scene inspector holds what used to float loose: clip size + fit, background,
  corner radius, snap and label toggles, the edge-crossing warning.
- **Apps tab is the catalogue**, searchable and always visible - click to add.
  New tiles land on a free spot inside the widget frame (`SnapEngine.
  freePlacement`), never on top of each other. Placed tiles list beneath it;
  click selects.
- Tile and picture inspectors gain an **align row** (left / center / right,
  top / middle / bottom against the widget frame) and a live position readout.
- **Arrow keys nudge** the selection 1px, Shift for 10px, clamped to the
  screen the same way a drag is.
- Looks = skins + skin sets. Pictures = placed pictures. Clips = variants,
  with click-to-preview.
