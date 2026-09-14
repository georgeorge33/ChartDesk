# Changelog

## 0.9.4

**Marking up charts**

- New **Markup** menu and an **Annotate** button on the toolbar (⇧⌘A). Turning it on puts a
  palette over the plate and lets you draw straight onto the chart.
- Five tools — **Pen**, **Highlighter**, **Arrow**, **Box** and **Text** — plus an
  **Eraser** that removes whatever mark you click or drag across. ⌃1 to ⌃6 pick one.
- Eight colours and three weights. Weight is stored as a share of the chart's width rather
  than a pixel count, so "Medium" looks equally thick on a 900-pixel plate and a
  4000-pixel one.
- The **Text** tool drops a label where you click. Type and press Return to keep it, Escape
  to throw it away. Labels carry their own halo, so they stay readable over a white plate
  and over an inverted one.
- Marks are recorded against the *unrotated* chart, so rotating the plate carries them round
  with it. Labels stay horizontal through a rotation — a sideways note is not much use.
- **Undo** and **Redo** (⌘Z / ⇧⌘Z) work per chart and go fifty steps back, so undoing on one
  plate can never reach back and alter another.
- Copy, export and print burn the marks into the image, the same way they already honour
  night mode and rotation. What you see is what you get.
- **Hide Marks** (⇧⌘M) takes every mark off the screen *and* out of copies, exports and
  printouts, without deleting anything.
- Marks are saved to `~/Library/Application Support/Chartdesk/annotations.json`, keyed by the
  same library-relative chart id that pins and category corrections use, so they survive a
  rescan, a relaunch and a rename of the app. Your chart files are still only ever read.
- New **Settings → Markup** pane: the tool, colour and weight new marks start with, the
  show-marks switch, a count of what is stored, and a Clear All Marks button.
- The window subtitle counts the marks on the chart you are looking at, and a chart in the
  middle column can be cleared from its right-click menu.
- Annotate mode only takes the mouse while it is switched on. With it off, panning,
  pinch-zoom and double-click-to-fit behave exactly as they did before.

**A toolbar you can edit**

- The toolbar above the chart is now yours to arrange: **View → Customize Toolbar…**,
  right-click the toolbar, or **Settings → General → Toolbar → Customize…**. Drag buttons on,
  off, or into a different order. macOS remembers the arrangement.
- Nineteen buttons are available and nine are on the bar to begin with. The ten waiting in
  the customisation sheet are rotate left, reset rotation, actual size, show/hide marks, undo
  mark, clear marks, reveal in Finder, copy image, export as PNG, and print.
- The toolbar can also be set to icon-only or icon-and-text from the same right-click menu.

**Fixed**

- Ad-hoc signing still failed for a checkout inside an iCloud-synced Desktop or Documents
  folder. 0.9.2 cleared extended attributes with `xattr -cr`, which misses
  `com.apple.FinderInfo` on the bundle directory itself — the one attribute `codesign`
  actually refuses. It is now deleted by name, and signing retries once, because iCloud can
  stamp the bundle again between the strip and the signature.

**Internal**

- The scroll view's document is now a container holding the chart image and the annotation
  layer at the same size, so marks magnify and pan with the plate rather than being drawn
  and positioned by hand.
- `AnnotationRenderer` draws in a single top-left-origin convention for both the screen and
  the burned-in export. The export context is flagged flipped *and* given the matching
  transform, which is the state a flipped view draws in, so text comes out the right way up
  in both without a special case.
- Exports build their bitmap explicitly instead of leaving it to `tiffRepresentation`, which
  guarantees one bitmap pixel per chart pixel whatever the screen's scale factor.
- Edit → Undo and Redo are pointed at marks. Marking up is the only undoable thing in
  Chartdesk, and the standard pair was previously doing nothing.
- The toolbar is assembled from three builders: `ToolbarContentBuilder` accepts at most ten
  children and there are nineteen items.

## 0.9.3

**Performance window**

- New **View → Performance…** window (⌥⌘P) showing what Chartdesk is costing the machine,
  refreshed once a second.
- **This Process** — CPU use with a peak reading, thread count, memory footprint with a peak
  reading, and how long the app has been running. Memory is `phys_footprint`, the same figure
  Activity Monitor shows in its Memory column.
- **System** — GPU utilisation, the GPU's name, core count and installed memory.
- **Charts** — image cache occupancy, cache hit rate, the time taken to decode the last chart
  and the slowest decode so far, plus library totals. These are the numbers that actually
  explain a stall when opening a large plate.
- **Reset Peaks** and **Empty Image Cache** buttons.
- GPU use is reported for the whole system, not for Chartdesk alone, and the window says so.
  macOS exposes no public per-process GPU figure.
- Sampling only runs while the window is open, so the tracker costs nothing when closed.

**Internal**

- `ChartImageStore` now tracks cache hits, misses, occupancy and decode timings behind a lock.
  `NSCache` does not expose its own count, so occupancy is counted here and is an upper bound.
- `clearCache()` was previously dead code and is now reachable from the Performance window.

## 0.9.2

**In-app updates**

- Chartdesk now checks GitHub for a newer release on launch and offers to install it.
- Choosing **Update and Relaunch** downloads the new release, quits Chartdesk, replaces the
  copy in your Applications folder, and reopens it.
- The previous version is removed automatically, but only once the new one is safely in
  place — if the copy fails, the old version is restored rather than leaving you with
  nothing installed.
- New **Chartdesk → Check for Updates…** menu item for checking on demand. An automatic
  check stays silent unless there is something to install; a manual one always reports back.
- New **Settings → General → Startup** toggle, "Check for updates on launch", on by default.
- Updates go through the GitHub CLI, because the repository is private and there is no token
  the app could safely carry. If `gh` is missing or signed out, the updater stays quiet
  instead of nagging.

**Fixed**

- Ad-hoc signing no longer fails when the project lives in an iCloud-synced folder. iCloud
  stamps Finder information onto the app bundle, which `codesign` refuses; `build.sh` now
  clears it before signing.

## 0.9.1

**Navigraph colour scheme**

- Reworked the entire interface to match the Navigraph Charts app: a dark navy shell with a
  blue accent, sampled from the real app.
- Chartdesk is now always dark and no longer follows the macOS light/dark setting.
- The sidebar and the chart list are painted as distinct panels, with matching hairlines
  between them.
- Accent-coloured text and icons use a brighter blue than filled controls do. The fill colour
  is only 2.7:1 against the dark shell and fails accessibility contrast as a foreground
  colour, while remaining perfectly legible as a button background.
- The two floating overlays are solid panels instead of translucent material, which was
  picking up the desktop wallpaper and casting colour across the navy.
- The canvas preset formerly called "Match System" is now "Chart Navy" and matches the rest
  of the app. Existing saved preferences still load.

**Chart categories**

- Reordered the category tabs to ARR, APP, APT, DEP, REF to match the Navigraph Charts app.
- The filename parser now has its own classification order, independent of the tab order.
  Previously the two were the same list, so rearranging the tabs could silently change which
  category a chart was filed under.

**Fixed**

- The "No Chart Selected" placeholder ignored both the canvas background preference and night
  mode, so it did not match the canvas it replaced.

## 0.9

- First release.
