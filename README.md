# Chartdesk

A native macOS browser for chart images you already have on disk. Built for LIDO plates saved
as PNGs, laid out the way Navigraph Charts is: airports on the left, chart list in the middle,
plate on the right.

macOS 13+. SwiftUI and AppKit, no dependencies. Nothing is sent anywhere, and the only two
things that reach out do so when you ask: checking for updates, and loading a SimBrief flight.

> [!NOTE]
> This app is created fully with Claude Opus 5 Max.

> [!CAUTION]
> For flight simulation use. Not for real-world navigation.

## Getting started

```sh
./build.sh --install
```

Compiles, bundles, signs and installs to `/Applications`. You need Xcode, or at minimum its
command line tools (`xcode-select --install`). On a machine without Xcode, `./update.sh`
downloads the latest build instead.

Then click **Choose Charts Folder…** and point it at your plates. The folder is **read only** —
Chartdesk never renames, moves, or writes anything inside it. macOS remembers the permission,
so the same library reopens every launch.

Both layouts work:

```
Charts/                            Charts/
  EGLL – London Heathrow/            EGLL AGC.png
    AGC.png                          EGLL IAC ILS Z 27R.png
    IAC ILS Z RWY 27R.png            EIDW STAR 28.png
  EIDW/                              EIDW AFC.png
    SID RWY 28.png
```

Codes come from the folder name when there is one, otherwise the file name. Anything with no
recognisable code lands in an **Unsorted** group rather than disappearing.

Supported: `png`, `jpg`, `jpeg`, `tif`, `tiff`, `gif`, `bmp`, `heic`, `webp`.

---

## Reading charts

The viewer is a real `NSScrollView` — pinch to zoom, two-finger scroll to pan, double-click to
toggle fit and 100%. Zoom holds through a night-mode toggle and resets when you change chart.

**Night mode** inverts the plate for a dark cockpit. Straight inversion turns chart blue into
orange, so Settings ▸ Viewing has *Remove colour when inverted* for a clean negative instead.

**Pinned** charts sit at the top of the sidebar, grouped by airport — your working set for a
flight. Recent airports follow underneath.

Export and print use exactly what you're looking at: rotation, night mode, and anything you've
drawn on.

### How charts get sorted

Five tabs matching the plate types LIDO issues. The parser scores tokens in the file name and
enclosing folders; file names win, folders break ties.

| Tab | Codes it looks for |
|---|---|
| **APT** Airport | AFC, AGC, ADC, APC, LVC, AOI, AOC, GMC, PDC, parking, stand, taxi, ground |
| **DEP** Departure | SID, SIDPT, EOSID, DEP, departure |
| **ARR** Arrival | STAR, STARPT, ARR, arrival, transition |
| **APP** Approach | IAC, VAC, MVC, ILS, LOC, RNP, RNAV, VOR, NDB, GLS, visual, circling, minima |
| **REF** Reference | TXT, text pages, general, ATC, info, noise, escape, emergency, briefing |

Runways are pulled from names like `IAC ILS Z RWY 27R` or `RNP 09R` and shown as a badge.
Approaches sort by runway number then L/C/R.

Anything filed wrong: **right-click ▸ Move to Category**, which sticks across rescans. For a
whole batch, the token tables at the top of `ChartNameParser.swift` are plain string lists —
a one-line edit and a rebuild.

---

## Marking up a chart

**⇧⌘A** turns on annotate mode. Five tools — pen, highlighter, arrow, box, text — in eight
colours and three weights, plus an eraser. `⌃1`–`⌃6` switch tools, `⌘Z` undoes, `⎋` leaves.

Marks belong to the chart, not the window. They save as you draw and follow the plate when you
rotate it, so a note beside runway 27 stays beside runway 27. Labels stay horizontal, since a
sideways note is no use to anybody.

Copies, exports and printouts burn the marks in at full chart resolution. **⇧⌘M** hides them
everywhere at once without deleting anything.

Weights are a share of the chart's width rather than a pixel count, so *Medium* looks the same
on a small plate and a large one.

---

## Flights from SimBrief

Put your SimBrief username in Settings ▸ General and press **⇧⌘B**. The airports your flight
needs appear at the top of the sidebar — origin, destination and every alternate — each showing
how many charts you have, or a warning that you have none:

```
BAW117  EGLL → KJFK · B772
  ORI  EGLL   RWY 27R          24
  DES  KJFK   RWY 04R          31
  ALT  KBOS                    12
  ALT  LFPG   not in your library  ⚠
```

That last line is the point. Discovering on the ground that you have no plates for your
alternate is exactly the thing worth catching early — click it to open the MSFS flight
planner.

It's a section, not a folder — nothing is copied and nothing is written to your chart library.
Load it again any time to pick up a replanned flight, or turn on loading at launch.

---

## Rearranging the toolbar

Right-click the toolbar ▸ **Customize Toolbar…** and drag buttons on, off, or into a different
order. Nineteen are available and nine start on the bar; rotate left, actual size, reveal in
Finder, copy, export, print and the mark controls are all waiting in the sheet. The same menu
switches between icon-only and icon-and-text.

The window drags from anywhere in the toolbar that isn't a button.

---

## Taxi routes

> [!WARNING]
> **Deprecated — scheduled for removal in 1.0.** Lining a chart up with the ground is fiddly and
> the drawn routes aren't dependable enough to read a clearance from. It still ships and still
> works, and any route already drawn onto a chart is an ordinary mark that will outlive the
> feature — but don't build anything on it.

**⇧⌘T** on a ground chart builds a taxi route by tapping taxiways. The layout comes from
OpenStreetMap, fetched once per airport with `python3 Tools/taxi_import.py KBOS`, and each chart
has to be lined up with the ground first — either by dragging the network onto the pavement or
by clicking two taxiway crossings.

---

## Keyboard

| | |
|---|---|
| `⌘O` `⌘R` | choose folder, rescan |
| `⌘F` `⌥⌘F` | search airports, filter charts |
| `⌘1`–`⌘5` | APT, DEP, ARR, APP, REF |
| `⌘↑` `⌘↓` | previous / next chart |
| `⌘D` | pin or unpin |
| `⌘+` `⌘-` `⌘0` `⌘9` | zoom in, out, fit, 100% |
| `⇧⌘N` | night mode |
| `⇧⌘R` `⇧⌘L` | rotate right / left |
| `⇧⌘C` `⌘E` `⌘P` | copy image, export PNG, print |
| `⇧⌘A` | annotate |
| `⌃1`–`⌃6` | pen, highlighter, arrow, box, text, eraser |
| `⌘Z` `⇧⌘Z` | undo / redo a mark |
| `⇧⌘M` | hide or show marks |
| `⇧⌘B` | load SimBrief flight |
| `⇧⌘T` | plan a taxi route *(deprecated)* |

---

## Where your data lives

Everything below `~/Library/Application Support/Chartdesk/`:

| | |
|---|---|
| `annotations.json` | marks drawn on charts |
| `category-overrides.json` | manual category moves |
| `flight.json` | the last SimBrief flight |
| `georeference.json` · `taxi/` | chart calibrations, airport layouts *(deprecated)* |

Pins, recents, the toolbar arrangement, view settings and the folder permission live in
preferences for `local.chartdesk.app`. Your charts stay untouched wherever you put them.

To start fresh: `defaults delete local.chartdesk.app` and delete that folder.

---

## Building and releasing

`build.sh` calls `swiftc` directly rather than going through SwiftPM. There are no dependencies
to resolve, so SwiftPM adds nothing, and its XCBuild backend refuses to start without a full
Xcode selected. The script finds the SwiftUI macro plugins itself.

```sh
./build.sh                # leave it in build/
./build.sh --run          # build and launch in place
./build.sh --install      # install to /Applications and launch
./build.sh --doctor       # what toolchain and plugins it can see
./build.sh --spm          # use SwiftPM anyway
```

To work on the code, open `Package.swift` in Xcode — editing and indexing work normally there.
Run `./build.sh` when you want a real bundle, since a bare executable gets no Dock presence or
menu bar.

CI builds on every push, so a second machine never needs Xcode: `./update.sh` installs the
newest release, or the newest green CI build if there's no release yet. To cut a release, tag
it — `git tag v1.1 && git push --tags` — and the workflow stamps the version, builds, and
attaches `Chartdesk.app.zip`, using that version's CHANGELOG section as the notes.

---

## Troubleshooting

**"Swift compiler not found"** — install the command line tools with `xcode-select --install`,
then run `./build.sh --doctor`.

**`external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`** — on
current SDKs `@State` and friends are macros, and the SwiftUIMacros plugin ships inside Xcode's
platform directory rather than the Command Line Tools. A CLT-only machine cannot build any
SwiftUI app that uses them. `build.sh` looks in the toolchain, the SDK, and any `Xcode*.app` in
`/Applications` — installed but unselected is enough. Find it with `./build.sh --find-macros`,
or point at it directly with `CHARTDESK_PLUGIN_DIR=/path/to/host/plugins ./build.sh`.
Toolchains from swift.org don't help; the plugin is part of Apple's SDK.

**`Could not initialize build system`** — SwiftPM's XCBuild backend failing before it reads any
of our code. The default `./build.sh` path avoids it. If you want `swift build` working:
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, `rm -rf .build`, then
`swift build -c release --build-system native`.

**Ad-hoc signing fails** — iCloud stamps Finder info onto anything under a synced Desktop or
Documents folder, which `codesign` refuses. `build.sh` strips it and retries; if it still fails,
build from a folder outside iCloud.

**No charts appear** — check the folder holds image files rather than PDFs. PDF plates aren't
supported yet.

**A chart won't open** — the viewer shows why, with a Reveal in Finder button. Usually a
truncated download or a `.png` that's secretly something else.

---

> [!CAUTION]
> **For flight simulation use. Not for real-world navigation.**
