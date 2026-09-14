# Changelog

## 0.12.1

- An airport in the flight list that you have no charts for is now clickable, and opens that
  airport in the MSFS web flight planner. There is nothing to select on those rows, so they do
  the next most useful thing instead.
- Role badges read ORIG, DEST and ALTN rather than ORI, DES and ALT.

## 0.12.0

**Flights from SimBrief**

- Put your SimBrief username in Settings ▸ General and press **⇧⌘B**. The airports your flight
  needs appear at the top of the sidebar: origin, destination and every alternate, each showing
  how many charts you have for it.
- Airports you have no charts for are listed anyway, flagged, and not selectable. Finding out on
  the ground that you have nothing for your alternate is exactly what this is for.
- It is a **section, not a folder**. Nothing is copied and nothing is written to your chart
  library — Chartdesk still only ever reads it, so there is nothing to clean up when the flight
  changes.
- Works with either a Navigraph alias or a numeric pilot ID; which one you typed is worked out
  from the value.
- The last flight is kept on disk, so the section survives a relaunch with no internet. Optional
  loading at launch, and a Clear Flight command.
- SimBrief's own error wording is passed straight through — "No flight plan on file for the
  specified user" says more than anything paraphrased would.

**Internal**

- The OFP is read by hand rather than through `Codable`. SimBrief returns every value as a
  string and sends `alternate` as an object when there is one and an array when there are
  several, which `Codable` handles badly; reading it loosely also means a missing field costs
  one airport rather than the whole plan.
- This is the first network connection Chartdesk makes itself — updates go through the `gh`
  CLI. The README no longer claims otherwise.

**README**

- Rewritten shorter and reorganised to lead with using the app rather than building it. The
  deprecated taxi section is down from sixty lines to ten.

## 0.11.0

**Moving the window**

- The window can now be dragged from anywhere in the toolbar that isn't a button, rather than
  only the narrow gap between the title and the controls. The title, the subtitle and the whole
  empty run between them all work.
- Every view over the plate opts out, so a drag on the chart still pans, draws or aligns
  exactly as before rather than picking the window up.

**Taxi routing is deprecated**

- Taxi routing and chart calibration are **scheduled for removal in 1.0**. In practice the
  drag-to-align calibration is fiddly and the drawn routes are not dependable enough to read a
  clearance from, which is not a good basis for something used while flying.
- Nothing is removed or disabled in this release. It still works, existing calibrations and
  drawn routes are untouched, and routes already committed to a chart are ordinary marks — they
  will keep working after the code goes.
- Every file and section involved now carries a `DEPRECATED` marker naming 1.0, so it is
  obvious what goes and what stays: `TaxiNetwork.swift`, `TaxiRouteStore.swift`,
  `Georeference.swift`, `TaxiRoutePanel.swift`, `Tools/taxi_import.py`, and the marked sections
  of the canvas, overlay, commands and detail view.
- Annotations, the customisable toolbar and everything else are unaffected.

## 0.10.1

**Lining a chart up by dragging it**

- A chart can now be calibrated by **dragging the taxi network onto the pavement** instead of
  clicking points: drag to move, ⌥ drag to turn, ⇧ drag to resize. A trackpad's rotate and
  pinch gestures work too.
- This is not an approximation of the stored calibration — it *is* it. A georeference is a
  similarity transform, and `a + bi` taken as one complex number is exactly its rotation and
  scale while `tx + ty·i` is its translation, so each gesture is a single operation on those
  four numbers with nothing to fit and no least squares involved.
- Turning and resizing pivot on the middle of what you are looking at, so the feature under
  the pointer stays under the pointer.
- Recalibrating starts from wherever the chart already sits, so a small correction stays a
  small correction. A chart that has never been calibrated starts north-up and centred at a
  size that covers most of the plate — wrong, but obviously so and easy to drag from.
- Clicking crossings is still there and still more precise; the two are a switch at the top of
  the panel. Dragging shows you the whole airfield at once, which clicking cannot.

**Fixed**

- **Recalibrating destroyed the existing calibration before making a new one.** Cancelling
  half way — or quitting — left the chart with nothing, having had a working calibration a
  moment earlier. The draft now replaces the saved one only when you press Done.
- Calibrating a chart while it was rotated stored an inverted aspect ratio, because the figure
  was taken from the rendered image rather than the plate's own shape. Calibrations are stored
  against the unrotated plate, so a chart calibrated at 90° would have been wrong.

**Calibrating against taxiway crossings**

- A chart is now lined up by clicking **taxiway intersections** rather than runway thresholds.
  This is more accurate, not just more convenient: OpenStreetMap's runway geometry runs to the
  physical end of the pavement, while a chart marks the *displaced* threshold, and those are
  not the same point. Two centrelines crossing are the same point on both.
- Only crossings that identify a place without ambiguity are offered. A stub meets its parent
  twice — A1 touches A at both ends — so "A × A1" does not name a spot. At Boston that rules
  out 7 pairs and leaves 37.
- Chartdesk suggests which crossing to click next, always the one furthest from what you have
  already placed, because a fit is only as well conditioned as its points are spread out. At
  Boston the first two suggestions are 2.7 km apart, half the width of the field.
- **You can now place more than two points**, and the fit updates as you go. This matters more
  than it sounds. Two points always fit *exactly*, so the reported error is zero however badly
  you clicked: with 15 m of click error, two points are 29 m out at the worst vertex and the
  app would have said 0.0 m. Four points bring that to 10 m and report 5.5 m. The panel now
  says so rather than showing a reassuring zero.
- The whole taxi network snaps into place over the plate as soon as the second point lands, so
  a calibration is judged against the printing underneath it before it is saved.
- Points can be undone one at a time, and nothing is stored until you press Done.
- Calibrations made in 0.10.0 are unaffected — a saved calibration is a fitted transform, not
  a record of how it was made.

## 0.10.0

**Taxi routes on the ground chart**

- New **Markup → Plan Taxi Route…** (⇧⌘T) and a toolbar button. Build a clearance by pressing
  taxiways rather than typing them, and watch it draw on the plate as you go.
- Buttons rather than a text field on purpose. Boston has both a gate A1 and a taxiway A1,
  which any typed grammar would have to disambiguate; separate controls cannot be ambiguous.
  You also cannot press a taxiway that is not in the data, so "no such taxiway" stops being a
  possible outcome.
- After each press, the taxiways that do not connect to the one you chose are dimmed — at
  Boston that takes 31 buttons down to a handful, and at Heathrow 84 down to a handful. They
  stay pressable, because imperfect map data must never make a legitimate turn unreachable.
- Finish on a runway and the route ends on it. Routes travel the taxiways you picked, in the
  order you picked them, with unnamed pavement bridging the gaps.
- Any taxiway the route had to use that you did not ask for is named underneath it. A route
  the data chose is not the same as a route you chose, and the difference is worth seeing.
- **Draw on chart** turns the route into ordinary marks, so it persists, exports, prints,
  undoes and erases exactly like something drawn by hand.

**Lining a chart up with the ground**

- A chart is calibrated by clicking the two thresholds of any runway. The ground positions
  come from the imported data, so no coordinate is ever typed.
- The fit is a similarity — rotation, uniform scale and translation — rather than a full
  affine. Ground charts are conformal at airport scale, and a similarity cannot shear the
  airport into a wrong shape to chase a mis-clicked point. On Boston's chart, two clicks
  place all 2,237 imported vertices to within 0.15 m.
- While the planner is open the whole taxi network is drawn faintly over the plate, so a
  calibration can be checked against the printing underneath rather than trusted on a number.
- A fit that would make the airport far larger or far smaller than the chart is rejected with
  a reason rather than saved.
- Calibrations are stored per chart and follow the plate through rotation, like marks do.

**Importing airport data**

- New `Tools/taxi_import.py`, which fetches an airport's taxiways, taxilanes, runways, gates
  and holding positions from OpenStreetMap and caches them as JSON:

      python3 Tools/taxi_import.py KBOS

- Chartdesk itself still makes no network connections. It only reads what the importer
  leaves in `~/Library/Application Support/Chartdesk/taxi/`.
- The importer asks for the aerodrome boundary *and* a radius around it, then merges the two.
  Neither is sufficient alone: the boundary is precise but at Boston is drawn tightly enough
  to exclude every apron taxilane, which is exactly the pavement that joins a gate to the
  taxiways. Disconnected clusters are reported afterwards, so a neighbouring airfield
  arriving with the radius pass is visible rather than silent.
- Designators are trimmed to what a pilot would say. Heathrow names its taxiways "Taxiway A"
  in OpenStreetMap and Dublin has "F1 (Temp Closed)"; nobody reads back "taxiway alpha one
  temp closed".
- Gates are offered as a starting point, but at most airports the apron lead-ins are not
  mapped at all, so the stand does not join the taxi network. Where that is the case the gap
  is drawn as a thin straight line and labelled approximate rather than passed off as
  surveyed pavement.

**Internal**

- Imported ways are split at every node they share with another way, because a shared node is
  exactly where an aircraft could turn off.
- The route search is a layered Dijkstra whose state carries whether the current taxiway has
  been *travelled*, not merely reached. Without that flag the search reaches a taxiway and
  advances without ever using it, which looks plausible and is wrong.
- Unnamed pavement costs a little more than a named taxiway; a taxiway that was not requested
  costs a great deal more but is not forbidden, because OpenStreetMap occasionally leaves a
  designator off the one segment that joins two others.

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
