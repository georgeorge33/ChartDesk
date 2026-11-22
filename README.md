# Chartdesk

A native macOS browser for chart images you already have on disk. Built for LIDO plates saved
as PNGs from the MSFS flight planner, laid out the way Navigraph Charts is: airports on the
left, chart list in the middle, plate on the right.

Around the plates it keeps what you read beside them: the airport's weather and ATIS, the wind
worked out against each of its runways, and your SimBrief flight — its airports, its briefing,
and its route on Apple's map with the airspace and each airport's own taxiways.

macOS 26+. SwiftUI and AppKit, no dependencies.

> [!NOTE]
> This app is created fully with Claude Opus 5 Max.

> [!CAUTION]
> For flight simulation use. Not for real-world navigation.

Your charts never leave the Mac: they are files, read where they are. What does reach out, and
when:

| | When |
|---|---|
| Updates, from this repository's releases | when the app opens, and when you ask |
| METAR, TAF and ATIS | when you pick an airport |
| SimBrief | when you load a flight, or at launch if you turn that on |
| X-Plane Scenery Gateway | your flight's airports as soon as it is loaded, others as the map closes in on them |
| Apple Maps | while the route map is on screen |
| FAA navigation data | at launch, when a new 28-day cycle is out |

## Getting started

```sh
./build.sh --install
```

Compiles, bundles, signs and installs to `/Applications`. You need Xcode, or at minimum its
command line tools (`xcode-select --install`). On a machine without Xcode, `./update.sh`
downloads the latest build instead.

Chartdesk **updates itself when it opens**: a newer release is installed, with a progress bar
on the startup screen, and the app reopens on it. It takes release candidates as well as final
releases; on a candidate the version in the sidebar's bottom corner is orange, so a pre-release
cannot be mistaken for the real thing. Press that version number to check at any time. Settings ▸ General turns the automatic
install off, and **Check for Updates…** in the Chartdesk menu then asks before installing
anything. Updating goes through the GitHub CLI, so it needs `gh` installed and signed in.

Then click **Choose Charts Folder…** and point it at your plates. macOS remembers the
permission, so the same library reopens every launch. Apart from
[filing the charts you download](#filing-what-you-download) into it, which Settings can turn
off, Chartdesk never adds, renames or changes anything in the folder.

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

## Getting charts from the MSFS planner

The MSFS flight planner, `planner.flightsimulator.com`, carries LIDO plates for its airports.
`Tools/planner-chart-download.user.js` saves them at the size the server sends — 2480×3507 for
an A4 plate. With a userscript manager such as Tampermonkey or Violentmonkey,
[open the script's raw file](https://raw.githubusercontent.com/georgeorge33/ChartDesk/main/Tools/planner-chart-download.user.js)
to install it; it keeps itself up to date from this repository.

On the planner:

- **⌥-click** a chart, or press **⌥D**, to save it. A box offers the name first.
- **⌥S** saves every chart the airport has. It switches the viewer to Lido, walks the tabs once
  to count them, then opens and saves each in turn, with a bar and the time remaining. **⌥⇧S**
  asks which airport first, for when it has worked that out wrongly, and **Esc** stops after
  the chart in hand.
- **⤓ Chart** and **⤓ Airport**, in the bottom right corner, do the same with a click.

Parking, ground and facility charts are saved under their codes — APC, AGC, AFC — however the
planner titles them. Each lands in the browser's download folder as `KBOS/AGC.png`, ready to
be filed.

### Filing what you download

When Chartdesk opens, a banner says what is waiting in Downloads and files it after ten
seconds, or straight away with **File now**. **Not now** leaves it for that launch only. The
tray button in the sidebar's footer and **File ▸ File Downloaded Charts…** do the same whenever
you like.

`KMKE/AGC.png` and a flat `KMKE AGC.png` both land as `KMKE/AGC.png` in the library — a folder
per airport, the chart's code as the name. The airport code has to be four **capital** letters,
which is what keeps `Scan 1.png` and a folder called `Docs` out of your library; anything else
in Downloads is left where it is.

**A chart you already have is replaced by the download**, which is the newer of the two — that
is what downloading it again is for. The old one goes to the Trash, where it can be got back.
Two downloads of the same chart in one batch file the first and leave the second where it was.

Settings ▸ General ▸ Startup turns the launch offer off. `Tools/file-charts.sh` files them from
Terminal instead: set `CHART_LIBRARY` to your library, and `--dry-run` says what would move.

---

## Reading charts

**Scroll to zoom** — centred on the pointer, so the feature under it stays put. **Drag to pan**,
double-click to toggle fit and 100%. Pinch works too. Zoom resets when you change chart.

**↑ and ↓ step through the chart list**, opening each chart in turn and keeping it in view, and
**⌘↑ ⌘↓** do the same from the Chart menu. The open chart's row is green from end to end.

**Pinned Charts** appears in the sidebar, above Briefing and Route Map, once you pin something
with ⌘D. It lists them grouped by airport — your working set for a flight.

Every airport has **its name under its code**: from the chart folder's own name if it has one,
then from a bundled list of 45,000 airfields and seaplane bases from OurAirports, and last from
your SimBrief plan. The names can be searched for as well as the codes.

**An orange clock marks an airport whose charts are out of date** — the newest plate filed
there is 28 days old or more, a LIDO cycle — at the right of its row and before its code above
the chart list, so the airports to download again stand out without opening each one. The
sidebar's footer also warns when the newest file in the whole library is more than 60 days old.

A **UTC clock** sits at the top right of the chart list — every clearance, report and OFP is in
Zulu, and the menu bar clock is not.

Export and print use exactly what you're looking at: rotation and anything you've drawn on.

### How charts get sorted

Five tabs matching the plate types LIDO issues. The parser scores tokens in the file name and
enclosing folders; file names win, folders break ties.

| Tab | Codes it looks for |
|---|---|
| **APT** Airport | AFC, AGC, ADC, APC, LVC, AOI, AOC, GMC, parking, stand, apron, taxi, ground, deicing |
| **DEP** Departure | SID, SIDPT, EOSID, DEP, departure |
| **ARR** Arrival | STAR, STARPT, ARR, arrival, transition |
| **APP** Approach | IAC, VAC, MVC, ILS, LOC, RNP, RNAV, VOR, NDB, GLS, visual, circling, missed |
| **REF** Reference | TXT, RFC, MRC, MSA, minima, legend, noise, enroute, general, info, briefing |

A name that opens with an airport chart's code is an airport chart, whatever the rest of it
says: Milwaukee's `AFC STARS SIDS` is filed with the airport charts, not the departures.

Runways are pulled from names like `IAC ILS Z RWY 27R`, `RNP 09R` or `LOC 25` and shown as a
chip. A bare number only counts at the end of a name, after a procedure word — anywhere else it
is more often a date, a page or a frequency. Approaches sort by runway number then L/C/R.

Anything filed wrong: **right-click ▸ Move to Category**, which sticks across rescans. For a
whole batch, the token tables at the top of `ChartNameParser.swift` are plain string lists —
a one-line edit and a rebuild.

---

## The airport's tabs

Pick an airport and the middle column puts its code at the top, its name under it, and four
tabs below:

| | |
|---|---|
| **Info** | how many charts you hold in each category, the magnetic variation there today, the date of the newest plate — orange past 28 days — and the folder they are in |
| **Charts** | the category strip, a filter, and the list |
| **Weather** | METAR, TAF and ATIS |
| **Runways** | the wind against each runway, under the METAR it was read from |

The weather is fetched the moment you pick the airport, so it is there when you turn to it.

### Weather and ATIS

The Weather tab shows the airport's **METAR**, **TAF**, real **ATIS** and **VATSIM ATIS**. The
ICAO field at the top fetches any other airport's, so weather for a destination you hold no
charts for is one field away.

| | Source |
|---|---|
| METAR, TAF | [Aviation Weather Center](https://aviationweather.gov) — worldwide |
| Real ATIS | FAA D-ATIS via `atis.info` — **US fields only** |
| VATSIM ATIS | the VATSIM data feed — only while a controller is online |

VATSIM's own METAR endpoint serves the same observation byte for byte, and VATSIM publishes no
TAF at all, so neither is fetched — it would be duplicate traffic for identical text. What
VATSIM uniquely has is the controller's ATIS, which genuinely differs: different runways in use,
and only present when the position is staffed.

METAR and TAF come first on purpose. A full ATIS runs to ten lines of hold-short and crane
advisories, which would push the two things you actually glance at out of view.

**A flight category sits beside the METAR**: a coloured dot and the letters — green VFR, blue
MVFR, red IFR, magenta LIFR — decided by the worse of ceiling and visibility.

**An ATIS comes decoded.** Under the full text, the information letter, time, wind, visibility,
cloud, temperature, dew point and altimeter in a column, with the pressure in both units — read
from an American D-ATIS, a European one or plain English. Anything the decoder cannot read with
confidence is left out rather than guessed. Where there is nothing to show it says so: **D-ATIS
Unavailable**, **No VATSIM online**.

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

The Runways tab resolves the wind against the runways you use, under the METAR it came from, so
the gusts, visibility and cloud stay in view while you choose. **Pick one from the RWY menu** and
the diagram draws it on the left, always pointing up the page whatever its heading, because on
approach the only thing that matters is the wind *relative to the runway* — and a compass rose
makes you do that rotation in your head.

The menu holds that airport's own runways, from a bundled table of 32,000 airports. Your charts
add to it: a plate named `IAC ILS Z RWY 04R` is proof that 04R exists — and that 22L does, being
the other end of the same strip — so a runway the table has missed still appears. Only an airport
in neither, with no plate naming a runway, falls back to offering all 36.

The table is designators only, which is all the wind maths needs, and it comes from
[OurAirports](https://ourairports.com/data/) — public domain, and no guarantee of accuracy, so a
decommissioned runway can linger in it. Rebuild it with `Tools/make_runways.py`.

Beside it the wind is drawn as its two components: one arrow along the runway for the head or
tail, one across it for the direct crosswind. Both are to one scale, so a long arrow down the
page beside a stub is a wind on the nose, and the reverse is the one to think about. Each points
the way the air moves, which is also the way it pushes you, and a tailwind turns orange. The same
figures are in the list underneath, one row per runway.

**The variation is worked out for you.** METAR wind is referenced to true north while runway
numbers are magnetic, so the wind is turned by the airport's variation from NOAA's
[World Magnetic Model](https://www.ncei.noaa.gov/products/world-magnetic-model) for today, and
the tab says which variation it used. At Boston's 14°W it matters: on runway 04R in a 050/20
wind it is the difference between 3.5 and 8.1 knots of crosswind. The model is in the app —
WMM2025, which runs to 2030 — so this needs no network.

The star marks the most headwind of the runways listed. It is not what ATC will give you —
Boston often runs 04L/04R when the wind favours 09, and 09 is frequently closed.

---

## Marking up a chart

**⇧⌘A** turns on annotate mode. Five tools — pen, highlighter, arrow, box, text — in eight
colours and three weights, plus an eraser. `⌃1`–`⌃6` switch tools, `⌘Z` undoes, `⎋` leaves.

Marks belong to the chart, not the window. They save as you draw and follow the plate when you
rotate it, so a note beside runway 27 stays beside runway 27. Labels stay horizontal, since a
sideways note is no use to anybody.

Copies, exports and printouts burn the marks in at full chart resolution. **Markup ▸ Hide
Marks** hides them everywhere at once without deleting anything.

Weights are a share of the chart's width rather than a pixel count, so *Medium* looks the same
on a small plate and a large one.

---

## Flights from SimBrief

Put your SimBrief username or pilot ID in Settings ▸ General and press **⇧⌘B**. The airports
your flight needs appear at the top of the sidebar — origin, destination and every alternate —
each showing how many charts you have, or a warning that you have none:

```
BAW117  EGLL → KJFK · B772
  ORIG  EGLL   RWY 27R                         24
  DEST  KJFK   RWY 04R — no chart           ⚠  31
  ALTN  KBOS   Boston Logan International      12
  ALTN  LFPG   not in your library             ↗
```

That last line is the point. Discovering on the ground that you have no plates for your
alternate is exactly the thing worth catching early — click it to open the MSFS flight
planner.

**Plates for the planned runway float to the top** of that airport's list, and the header says
`RWY 04R planned`, so the ordering explains itself. When none of your plates serves the planned
runway, the header says **No plate for planned RWY 04R** in orange, and the flight's row says
`RWY 04R — no chart`.

It's a section, not a folder — nothing is copied and nothing is written to your chart library.
The ↻ beside the section reloads it to pick up a replanned flight and the × clears it, leaving
a **Load SimBrief Flight** row in its place to fetch it back. You can also turn on loading at
launch.

### The briefing

With a flight loaded, **Briefing** sits in the sidebar above Route Map: the OFP as SimBrief lays
it out, in whichever of its layouts you plan with, light on the app's dark backdrop and without
leaving for a browser. The column beside it says which flight it is, when SimBrief made the plan
and when it was fetched, with a button to fetch it again and SimBrief's PDF of the same
briefing.

Its sections are listed to its right — SimBrief's own outline: the OFP with its summary and
fuel, the flight log and winds, then the ATC flight plan, weather, NOTAMs and the rest. Press
one to go straight to it; the one you are reading is picked out as you scroll. Nothing in the
page is run, and a link in it opens in your browser.

---

## The route map

**Route Map** in the sidebar, or **⇧⌘M**, puts a map where the chart would be and the route in
the middle column: each fix with its airway or procedure, and its altitude, as a flight level
above the transition. With no flight loaded it still shows every airport you hold charts for.

The map is Apple's own — **Map**, with roads, places and relief, or **Satellite** — so it pans
and zooms the way the Maps app does: drag to pan, pinch or turn the wheel to zoom about the
pointer, **Fit** to frame the flight. It needs the network every time, because Apple does not
permit an app to keep a copy of what it draws.

**The flight plan is magenta**, which is what a planned track is on every chart that draws one,
with the SID and STAR legs in orange. Legs are great circles, which is the way the aeroplane
goes.

**Search for an airport with the map open and the map goes there**, framing the whole field: an
ICAO code the moment it is typed in full, or on Return the best match by code or name from
every airport the map knows. BOS is Logan, London is Heathrow.

### Altitude restrictions

On a US SID or STAR the route list states what the procedure demands, not only what SimBrief
predicts. On the HYLND7 out of Boston, HURBE reads **4000** in magenta with a bar beneath it —
at or above — while the fixes either side stay green predictions. That is Airbus F-PLN
formatting: magenta for a restriction and green for a prediction, a bar under a floor, over a
ceiling, both for a single altitude, and two stacked figures for a block. An altitude that
repeats the one above it shows a ditto instead; a restriction never does.

The data is the FAA's Coded Instrument Flight Procedures — public domain, reissued every 28
days, United States only. At launch the cycle in force is compared with the one on disk, and a
new one is fetched only when it has changed. Settings ▸ General ▸ Navigation Data shows the
cycle, with a **Check Now** button.

### Layers

The **Layers** button in the map's top right corner holds the base map — Map or Satellite —
and three things to draw over it.

**Airspace**, drawn the way ForeFlight draws it: each boundary a bright line over a faint glow
of its own colour, with a tag just inside the ring saying what it is, floor to ceiling —
`B: 2000-7000`, `D: SFC-2600`. A switch per class, A to E, and one for prohibited, restricted
and danger areas. Drawn from about 15° across, and only where a ring is big enough to read.

It comes from [openAIP](https://www.openaip.net), worldwide, and is not bundled — openAIP's
data is CC BY-NC and needs a key — so it is built on your own Mac with your own free key. Put
the key in `~/.chartdesk/openaip-key.txt`, or `OPENAIP_API_KEY`, and run:

```sh
python3 Tools/make_openaip.py
```

The table goes into Application Support, and the Layers panel says when it is not there.

**Airport layouts**, close in, drawn the way a ground chart draws them, from the
[X-Plane Scenery Gateway](https://gateway.x-plane.com/) — the airport database X-Plane itself
ships, 41,000 airports drawn by its community and checked by Laminar's moderators:

- **Runways painted like runways**: piano keys, touchdown zone and aiming point, a broken
  centreline, each end's number across its threshold, arrows on a displaced threshold and
  chevrons on a stopway.
- **The paint on the ground**: every taxiway centreline, lead-in, edge line and hold line in
  yellow, and closer in the white of the service roads and the red safety lines round the
  gates. Further out, a single line down each taxiway, with its letter.
- **Holding positions in red**, where the airport paints them, and otherwise where a taxi route
  passes into a runway's protected area.
- **Stand numbers** for every gate.

A layout is fetched from about 60 km across and drawn below 20 km, one airport at a time,
biggest first, a second or two each, and kept. Your flight's airports — origin, destination and
every alternate — are fetched as soon as the flight is loaded, whether the map is open or not.
A card on the map shows which airport is loading, how much of it has arrived and how many are
waiting. **Fetch Layouts for Your Airports**, in Layers, gets every airport you hold charts for
in one go. A field the Gateway has nothing for keeps just its runways, from the bundled table.

**Places**: state borders, and town and city names, as many as there is room for, the largest
first.

**Window ▸ Debug ▸ Airport Layouts** lists every layout on this Mac — its runways, taxiways,
stands and holding positions, how big it is and when it arrived — and can throw them all away.

---

## B612 Mono

Settings ▸ Viewing ▸ **Use B612 Mono** sets the app in the typeface Airbus drew for its cockpit
displays — the sidebar, the chart list, the weather, the map's labels and the SimBrief
briefing, whose columns still line up because this is the monospaced cut. It changes the moment
it is switched, and the briefing keeps your place. Menus and window titles stay in the system
font. B612 Mono comes inside the app, under the SIL Open Font License.

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
| `↑` `↓`, `⌘↑` `⌘↓` | previous / next chart |
| `⌘D` | pin or unpin |
| `⌘+` `⌘-` `⌘0` `⌘9` | zoom in, out, fit, 100% |
| `⇧⌘R` `⇧⌘L` | rotate right / left |
| `⇧⌘C` `⌘E` `⌘P` | copy image, export PNG, print |
| `⇧⌘A` | annotate |
| `⌃1`–`⌃6` | pen, highlighter, arrow, box, text, eraser |
| `⌘Z` `⇧⌘Z` | undo / redo a mark |
| `⇧⌘B` | load SimBrief flight |
| `⇧⌘M` | route map |
| `⌥⌘P` `⌥⌘L` | Performance, Airport Layouts |

---

## Where your data lives

Everything below `~/Library/Application Support/Chartdesk/`:

| | |
|---|---|
| `annotations.json` | marks drawn on charts |
| `category-overrides.json` | manual category moves |
| `flight.json` | the last SimBrief flight, with its briefing |
| `layouts/xplane/` | airport layouts from the X-Plane Scenery Gateway, one `ICAO.dat` per airport |
| `navdata/` | the FAA's altitude restrictions, for the cycle in force |
| `openaip/airspace.txt` | the openAIP airspace table, once you have built one |

Pins, the toolbar arrangement, view settings and the folder permission live in preferences for
`local.chartdesk.app`. Your charts stay wherever you put them; Settings ▸ General says how many
there are and how much room the folder takes.

Earlier versions kept a drawn map's coastline and tiles here too, nearly 4 GB of it; the app
clears what is left of them the first time it opens.

To start fresh: `defaults delete local.chartdesk.app` and delete that folder.

---

## Data and licences

| | Used for | Licence |
|---|---|---|
| X-Plane Scenery Gateway | airport layouts, fetched per airport | GPL v2 or later |
| openAIP | airspace, built on your Mac | CC BY-NC 4.0 |
| Apple Maps | the base map | Apple's terms |
| OurAirports | runways and airport names, bundled | public domain |
| Natural Earth | frontiers, state lines and towns, bundled | public domain |
| FAA CIFP | altitude restrictions, fetched each cycle | public domain |
| NOAA World Magnetic Model | magnetic variation, bundled | public domain |
| B612 Mono | the typeface, bundled | SIL OFL 1.1 |

[LICENSES.md](LICENSES.md) says what each one requires and where the app does it. Chartdesk
itself is [MIT licensed](LICENSE).

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

**Signing.** `build.sh` signs with a certificate called `Chartdesk Signing` when the keychain
has one — `CHARTDESK_SIGN_IDENTITY` names another — and ad hoc otherwise. Releases carry it so
that a permission you grant, like Downloads, belongs to the certificate rather than to one
build, and macOS stops asking again after every update. It is self-signed and vouches for
nobody: Gatekeeper treats the app as it would without it. CI imports it from the repository
secrets `SIGNING_CERTIFICATE_P12` and `SIGNING_CERTIFICATE_PASSWORD`.

**Releasing.** CI builds and signs on every push to `main`, so a second machine never needs
Xcode: `./update.sh` installs the newest release, or the newest green CI build if there's no
release yet. To cut a release:

1. Give the version a `## 1.3.0` section in `CHANGELOG.md`.
2. Push `main` and wait for the **Build** workflow to pass. The runner's compiler is older than
   a current Xcode's and has refused code that built locally.
3. Tag it: `git tag v1.3.0 && git push origin v1.3.0`.

The Release workflow stamps the version, builds, signs and attaches `Chartdesk.app.zip`, with
that version's CHANGELOG section as the notes. A tag with a suffix — `v1.3.0-rc.5` — is
published as a pre-release, with its own section as the notes if it has one. A tag that fails
to build is left where it is and the next number used, rather than moved.

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

**Updates never arrive** — updating goes through the GitHub CLI: `brew install gh`, then
`gh auth login`. **Check for Updates…** says what it found either way.

**The airspace switches draw nothing** — there is no openAIP table on this Mac yet; the Layers
panel says so. Build one with `Tools/make_openaip.py`, as above.

**No charts appear** — check the folder holds image files rather than PDFs. PDF plates aren't
supported yet.

**A chart won't open** — the viewer shows why, with a Reveal in Finder button. Usually a
truncated download or a `.png` that's secretly something else.

---

> [!CAUTION]
> **For flight simulation use. Not for real-world navigation.**
