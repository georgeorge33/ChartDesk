# Chartdesk

A native macOS browser for chart images you already have on disk. Built for LIDO plates saved
as PNGs, laid out the way Navigraph Charts is: airports on the left, chart list in the middle,
plate on the right.

macOS 26+. SwiftUI and AppKit, no dependencies. Nothing is sent anywhere. The things that
reach out do so when you ask: checking for updates, loading a SimBrief flight, and fetching
weather.

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

**Scroll to zoom** — centred on the pointer, so the feature under it stays put. **Drag to pan**,
double-click to toggle fit and 100%. Pinch works too. Zoom resets when you change chart.

**Pinned** charts sit at the top of the sidebar, grouped by airport — your working set for a
flight. Recent airports follow underneath.

When a SimBrief flight is loaded, plates for the **planned runway float to the top** of the list
and their runway badge is highlighted — the header says which runway, so the ordering explains
itself. The sidebar footer warns when the newest file in your library is more than 60 days old,
which is two LIDO cycles.

A **UTC clock** sits in the bottom corner of the window — every clearance, report and OFP is in
Zulu, and the menu bar clock is not.

Export and print use exactly what you're looking at: rotation and anything you've drawn on.

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

## Weather and ATIS

A panel at the foot of the chart list shows the selected airport's **METAR**, **TAF**, real
**ATIS** and **VATSIM ATIS**. Drag its top edge to give it more room, or collapse it — collapsed
it stops requesting rather than just hiding.

| | Source |
|---|---|
| METAR, TAF | [Aviation Weather Center](https://aviationweather.gov) — worldwide |
| Real ATIS | FAA D-ATIS via `datis.clowd.io` — **US fields only** |
| VATSIM ATIS | the VATSIM data feed — only while a controller is online |

VATSIM's own METAR endpoint serves the same observation byte for byte, and VATSIM publishes no
TAF at all, so neither is fetched — it would be duplicate traffic for identical text. What
VATSIM uniquely has is the controller's ATIS, which genuinely differs: different runways in use,
and only present when the position is staffed.

METAR and TAF come first in the panel on purpose. A full ATIS runs to ten lines of hold-short
and crane advisories, which would push the two things you actually glance at out of view.

Results are cached for a minute, which keeps a Refresh meaningful and stays well inside
VATSIM's fifteen-second polling guidance.

### What the colours mean

METAR, TAF and ATIS are marked in two tiers. Two rather than a colour per field, because six
colours is a legend you have to memorise:

**Blue** — the information letter and the wind, marked whatever their value, because they are
what you read every single time.

**Orange** — a value worth a second look:

| | Marked when |
|---|---|
| Visibility | below 3 SM or 5000 m, or an RVR group is reported at all |
| Ceiling | a BKN, OVC or VV layer below 1000 ft |
| Temperature | at or below 3°C, or at or above 30°C |
| Pressure | QNH below 1000 or above 1030 hPa (29.53 / 30.42 inHg) |
| Weather | thunderstorms, freezing precipitation, fog, hail, squalls, or anything heavy |

Each is a boundary where the answer to *can I do this?* changes rather than a round number:
below 3 SM an approach stops being visual, below a 1000 ft ceiling you are on instruments, 3°C
is where ice becomes a question and 30°C is where performance does, and outside 1000–1030 hPa
the altimetry error is worth thinking about. Mist, haze and light rain are deliberately left
plain — marking those would mark half the reports in Europe. Everything staying plain is the
point: the marks only mean something if most of the report is unmarked.

Weather codes are read only in the coded run at the top of a report. Past the pressure group an
American ATIS is plain English, where `VA` is a visual approach and `GS` is a glideslope rather
than volcanic ash and hail.

An ATIS also shows how long ago it was issued, from its own time group — **+29 mins**. Past an
hour that turns orange: a new letter goes out at least hourly, so there is probably a newer one.

### Wind and crosswind

The same panel resolves the wind against the runways you use. **Pick one from the RWY menu** and
the diagram draws it on the left, always pointing up the page whatever its heading, because on
approach the only thing that matters is the wind *relative to the runway* — and a compass rose
makes you do that rotation in your head.

The menu is filled from the charts you hold. A plate named `IAC ILS Z RWY 04R` is proof that 04R
exists — and that 22L does, being the other end of the same strip — so nothing has to be typed.
An airport with no charts, looked up by ICAO, offers all 36 instead.

Beside it the wind is drawn as its two components: one arrow along the runway for the head or
tail, one across it for the direct crosswind. Both are to one scale, so a long arrow down the
page beside a stub is a wind on the nose, and the reverse is the one to think about. Each points
the way the air moves, which is also the way it pushes you, and a tailwind turns orange. The same
figures are in the list underneath, one row per runway.

Drag the grip at the top of the panel to make the whole weather section taller or shorter.

> [!IMPORTANT]
> Set the **variation** from the chart. METAR wind is referenced to true north while runway
> numbers are magnetic, so at Boston's 15°W the two differ by 15°. On runway 04R in a 050/20
> wind that is the difference between 3.5 and 8.5 knots of crosswind.

The star marks the most headwind of the runways you listed. It is not what ATC will give you —
Boston often runs 04L/04R when the wind favours 09, and 09 is frequently closed.

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
order. Eighteen are available and eight start on the bar; rotate left, actual size, reveal in
Finder, copy, export, print and the mark controls are all waiting in the sheet. The same menu
switches between icon-only and icon-and-text.

The window drags from anywhere in the toolbar that isn't a button.

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
| `⇧⌘R` `⇧⌘L` | rotate right / left |
| `⇧⌘C` `⌘E` `⌘P` | copy image, export PNG, print |
| `⇧⌘A` | annotate |
| `⌃1`–`⌃6` | pen, highlighter, arrow, box, text, eraser |
| `⌘Z` `⇧⌘Z` | undo / redo a mark |
| `⇧⌘M` | hide or show marks |
| `⇧⌘B` | load SimBrief flight |

---

## Where your data lives

Everything below `~/Library/Application Support/Chartdesk/`:

| | |
|---|---|
| `annotations.json` | marks drawn on charts |
| `category-overrides.json` | manual category moves |
| `flight.json` | the last SimBrief flight |

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
