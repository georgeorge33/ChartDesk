# Chartdesk

A native macOS browser for chart images you already have on disk. Built for LIDO plates saved
as PNGs, laid out the way Navigraph Charts is: airports on the left, chart list in the middle,
plate on the right.

Requires macOS 13 or later. SwiftUI + AppKit, no dependencies, no network access.

---

## Build

```sh
./build.sh --install
```

That compiles a release build, wraps it in `Chartdesk.app`, builds the icon, ad-hoc signs it,
copies it to `/Applications` and launches it. Use `./build.sh` alone to leave the app in
`build/`, or `./build.sh --run` to build and launch in place.

You need Apple's Swift compiler — either Xcode, or just the command line tools:

```sh
xcode-select --install
```

The script calls `swiftc` directly rather than going through SwiftPM. There are no
dependencies to resolve, so SwiftPM adds nothing, and its newer XCBuild backend refuses to
start unless a full Xcode is installed and selected. The script works out the SwiftUI macro
plugin paths itself, which is the other job SwiftPM would otherwise do. `./build.sh --spm` uses
SwiftPM anyway if you want it; `./build.sh --doctor` prints what toolchain and plugins it can
see.

To work on the code, open `Package.swift` in Xcode — editing, indexing and autocomplete work
normally there. Run `./build.sh` when you want a real bundle, since a bare executable doesn't
get a proper Dock presence or menu bar.

---

## Updating without building

CI builds the app on a real Mac on every push, so a second machine never needs Xcode.

```sh
./update.sh
```

That downloads the newest build and installs it to `/Applications` — the most recent release if
there is one, otherwise the most recent green CI run — strips the quarantine flag, quits a
running copy, and reopens it. Pass the repo (`./update.sh owner/chartdesk`) when running it from
outside the checkout.

To cut a release, tag it:

```sh
git tag v1.1 && git push --tags
```

The release workflow stamps the version into the bundle, builds, and attaches `Chartdesk.app.zip`
to a GitHub release. CI artifacts expire after 90 days; releases don't.

---

## First run

Click **Choose Charts Folder…** and point it at wherever your plates live. The folder is read
only — Chartdesk never renames, moves, or writes anything inside it. macOS remembers the
permission, so it reopens the same library on every launch.

Both layouts work:

```
Charts/                            Charts/
  EGLL – London Heathrow/            EGLL AGC.png
    AGC.png                          EGLL IAC ILS Z 27R.png
    IAC ILS Z RWY 27R.png            EIDW STAR 28.png
  EIDW/                              EIDW AFC.png
    SID RWY 28.png
```

Airport codes come from the folder name when there is one, otherwise from the file name. A
folder named `EGLL – London Heathrow` gives you both the code and the airport name in the
sidebar. Anything with no recognisable code lands in an **Unsorted** group at the bottom of
the sidebar rather than being hidden.

Supported files: `png`, `jpg`, `jpeg`, `tif`, `tiff`, `gif`, `bmp`, `heic`, `webp`.

---

## How charts get sorted

Five tabs, matching the plate types LIDO issues. The parser scores tokens found in the file
name and in the enclosing folder names — file names win, folders only break ties.

| Tab | LIDO / common codes |
|---|---|
| **APT** Airport | AFC, AGC, ADC, APC, LVC, AOI, AOC, GMC, PDC, parking, stand, taxi, ground, aerodrome |
| **DEP** Departure | SID, SIDPT, EOSID, DEP, departure, RNAV departure |
| **ARR** Arrival | STAR, STARPT, ARR, arrival, transition |
| **APP** Approach | IAC, VAC, MVC, ILS, LOC, RNP, RNAV, VOR, NDB, GLS, visual, circling, minima |
| **REF** Reference | TXT, text pages, general, ATC, info, noise, escape, emergency, briefing |

Runways are pulled out of things like `IAC ILS Z RWY 27R`, `ILS25L` or `RNP 09R` and shown as a
badge. Approaches sort by runway number then L/C/R, so 09L comes before 09R before 10.

Anything filed in the wrong tab: **right-click ▸ Move to Category**. The correction is saved to
`~/Library/Application Support/Chartdesk/categories.json` and survives rescans, renames of the
app, and reboots. Settings ▸ General ▸ Reset Categories clears them all.

If a whole batch of your files lands in the wrong place, the token tables are near the top of
`Sources/Chartdesk/Model/ChartNameParser.swift` — they're plain string lists, so adding your own
naming convention is a one-line edit and a rebuild.

---

## Using it

Pinned charts sit at the top of the sidebar with their own section, grouped by airport — that's
your working set for a flight. Recent airports appear underneath, most recent first.

The viewer is a real `NSScrollView`, so pinch to zoom, two-finger scroll to pan, and
double-click to toggle between fit and 100%. Zoom stays put when you toggle night mode, and
resets when you switch charts or rotate.

Night mode inverts the plate for dark cockpits. A straight inversion turns chart blue into
orange, so Settings ▸ Viewing has a *Remove colour when inverted* option that gives you a clean
negative instead.

### Keyboard

| | |
|---|---|
| `⌘O` / `⌘R` | choose folder / rescan |
| `⌘F` / `⌥⌘F` | search airports / filter charts |
| `⌘1`–`⌘5` | APT, DEP, ARR, APP, REF |
| `⌘↑` `⌘↓` | previous / next chart |
| `⌘D` | pin or unpin |
| `⌘+` `⌘-` `⌘0` `⌘9` | zoom in, out, fit, 100% |
| `⇧⌘N` | night mode |
| `⇧⌘R` `⇧⌘L` | rotate right / left |
| `⇧⌘C` `⌘E` `⌘P` | copy image, export PNG, print |

Export and print use whatever you're looking at, including the rotation and night-mode
treatment — handy for a paper copy of an approach in the orientation you actually fly it.

---

## Where your data lives

| | |
|---|---|
| Folder permission, pins, recents, view settings | preferences for `local.chartdesk.app` |
| Manual category moves | `~/Library/Application Support/Chartdesk/categories.json` |
| Your charts | untouched, wherever you put them |

To start completely fresh: `defaults delete local.chartdesk.app` and delete that JSON file.

---

## Troubleshooting

**`Could not initialize build system … Unknown error parsing property list`** — that's
SwiftPM's XCBuild backend failing to start, before it reads a line of our code. It needs a full
Xcode install selected. The default `./build.sh` path avoids it entirely by calling `swiftc`.
If you want `swift build` itself working: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`,
then `rm -rf .build`, and try `swift build -c release --build-system native`.

**"Swift compiler not found"** — install the command line tools with `xcode-select --install`,
then check `./build.sh --doctor`.

**`external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`** — on
current SDKs `@State`, `@StateObject` and `@EnvironmentObject` are macros, so the compiler needs
the SwiftUIMacros plugin. That plugin ships inside Xcode's macOS platform directory and is *not*
part of the Command Line Tools, so a CLT-only machine cannot build any SwiftUI app that uses
them, this one included.

`build.sh` looks for the plugin in the selected toolchain, the SDK, and any `Xcode*.app` sitting
in `/Applications` — an installed but unselected Xcode is enough, nothing needs to be switched.
If it finds nothing it stops with instructions rather than dumping compiler errors.

```sh
./build.sh --doctor       # what toolchain and plugins are visible
./build.sh --find-macros  # search the disk for SwiftUIMacros
```

If the plugin turns up somewhere unusual, point the build straight at it:

```sh
CHARTDESK_PLUGIN_DIR=/path/to/host/plugins ./build.sh
```

If it isn't on the machine at all, Xcode has to be installed. Toolchains from swift.org don't
help — SwiftUIMacros is part of Apple's SDK, not the open source toolchain.

**The app builds but shows no charts** — check the folder actually contains image files rather
than PDFs. PDF plates aren't supported in this version; convert them first, or say the word and
I'll add a PDF path using the same pypdfium2 approach ChartView uses.

**A chart won't open** — the viewer shows the reason inline with a Reveal in Finder button.
Usually a truncated download or a `.png` that's secretly something else.

**Charts are in the wrong tabs** — right-click ▸ Move to Category for one-offs, or edit the
token tables in `ChartNameParser.swift` for a pattern.

---

For flight simulation use. Not for real-world navigation.
