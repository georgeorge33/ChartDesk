# Changelog

## 1.2.0-rc.7

What this candidate adds to 1.1.0. Full release when it has been flown.

**The airport's own ground**

- **Runways, taxiways and aprons** at the closest zooms, the way a ground chart draws them:
  yellow centrelines, each taxiway's designator in a yellow box, the runways with their
  numbers. From OpenStreetMap, which is the only source that has taxiways at all — the
  bundled runway table knows where a runway is and nothing about what leads to it.
- Over imagery **only the markings are drawn**, because the tarmac is already in the
  picture and painting grey over it hides the thing you chose that base map to see. Over the
  drawn map, the pavement is drawn too: aprons filled, every way in its own width, from the
  `width` tag where there is one and from what the way is where there is not.
- **The runway looks like a runway**: dark asphalt against the lighter concrete beside it, a
  white line down each side, the broken line down the middle, and the piano keys at both
  thresholds — eight stripes over the middle four-fifths of the width, thirty metres long,
  which is what the real paint is. It replaces the bundled runway strip wherever it has been
  fetched: that one is a straight band between two thresholds, and this is the runway's own
  outline. The bundled table still draws every other airport on earth, which is what it is
  for.
- **Taxiways are drawn as curves** through their points rather than a chain of straight bits
  between them. A fillet is three or four nodes round the corner, and joining them with
  straight lines drew the corner as a cut-off — which is what made the yellow lines look
  faceted. Catmull-Rom, so the curve passes through every node it was given and only the
  space between them changes.
- **Stand numbers** at the closest zoom, **holding positions** as the magenta bar painted
  across the taxiway, and the runways with a white line down each side and their numbers at
  the ends they belong to. Madrid comes to 418 stands and 293 holding positions.
- Which end a runway number goes on is not a matter of taste: 14L is painted where you line
  up to fly 140°, so the bearing of the way decides it. The bar across a holding position is
  worked out too — OpenStreetMap marks the spot and says nothing about which way the taxiway
  runs through it, so the nearest stretch of pavement is found and the bar laid square to it.
- Taxiway designators are yellow on black with a yellow border, the way a ground chart paints
  them.
- OpenStreetMap numbers a taxiway's segments — Madrid's ZW is ZW-1, ZW-2, ZW-3 — and the
  chart paints ZW5, so a letter group, a hyphen and a number group become the designator.
  Anything else keeps the name it was given: a north-south taxiway is not N followed by S.
- **Fetched on the way down**, from about 60km across — ten times further out than a layout
  is drawn — because Overpass takes a minute or two and asking at the zoom where the layout
  would appear means watching an empty airport while it arrives. The fields in view are
  queued **biggest first**, so Heathrow is asked for before the grass strip under the
  cursor, and one at a time, because a dozen at once would be both rude and no faster.
- **Your flight's own airfields are fetched whatever the map is showing**, and first. They
  are the one set of layouts you know you are going to want.
- Fetched one airport at a time from the Overpass API and **kept**. It is a free, shared
  service and a slow one — the same query for Madrid took 48 seconds one minute and 152 the
  next — so `Tools/make_layouts.py` will fetch the fields you actually fly ahead of time,
  and the app never asks for the same airport twice.
- **Drawn from twenty kilometres across** rather than six, and every field on the sheet
  rather than only the one nearest the middle of it. Two airports that share a city are
  often closer together than the view is wide — Kennedy and La Guardia are seventeen
  kilometres apart — and drawing one of them as a ground plan while the other stayed a bare
  strip looked like a fault rather than a decision. The threshold is now a real distance
  instead of a zoom figure, so it means the same thing whatever size the window is.
- **A Debug submenu**, in the Window menu. Performance has moved into it from the View menu,
  where it never belonged, and it has been joined by **Airport Layouts** — a list of every
  ground plan on this Mac, with the taxiways, runways, stands and holding positions each one
  holds, how much of its pavement is a drawn outline, how big it is and when it arrived. The
  layouts arrive one at a time from a service that is often busy and are kept forever once
  they do, and until now the only way to know which ones you had was to fly somewhere and
  see whether the taxiways were drawn. It can also throw the lot away, for when the query
  has changed and the cached answers predate it — behind a confirmation that says how many
  airports and how many megabytes are about to go, because collecting them again is hours
  of asking.
- **The field is worked out on its own plane.** Everything derived from a layout — the
  white lines down a runway's sides, the piano keys, the bar across a holding position — is
  now worked out on an azimuthal equidistant projection centred on the airport, which is what
  Navigraph's AMDB API offers alongside plain latitude and longitude and for the same
  reason. An airport is four kilometres across and on that much ground a sphere is a plane,
  so "half a width square to the centreline" becomes the two lines of arithmetic it sounds
  like instead of a cross product against a unit sphere. The shapes come out within a
  micron of the spherical ones they replace, at the equator and at 78° north alike, and
  they are worked out once when the layout is read rather than again on every frame.
- **Pavement that is drawn rather than guessed.** Where OpenStreetMap has the outline of
  the tarmac — `area:aeroway`, or the older `area=yes` on a closed ring — that outline is
  the pavement, and the centreline running through it is no longer inflated by its width
  tag to stand in for one. This is the distinction an AMDB is built on: there a taxiway is
  a polygon and the yellow line down it is a separate feature. The runway keeps its paint
  either way, because the markings are not the pavement. Be warned that the tag is rare —
  about one taxiway in a hundred worldwide, and none at all at Frankfurt — so most fields
  look exactly as they did. At Maastricht, which has thirteen of them, the drawn outlines
  differ from the width tag they replace by a median of 58%.
- Taxilanes **lose their yellow line and their letter**. A taxilane is the lead into a stand
  on the apron, not movement area, and painting it like a taxiway made the ramp look like
  somewhere you might be told to go. The pavement stays; the markings do not.
- **No switch for it.** This far in the ground plan is the map — the coastline is a straight
  line and the nearest border is nowhere near — so there was nothing to choose between. The
  Layers panel still says where the layout comes from and how far out it is fetched.

**Also**

- **A flight category beside the METAR**: a coloured dot and the letters, so you can tell
  whether a field is flyable from across the room before reading a single group. Green VFR,
  blue MVFR, red IFR, magenta LIFR — not a palette anyone gets to choose, since that is what
  every briefing map has meant by them for decades. The worse of ceiling and visibility
  decides it, few and scattered are not a ceiling, and everything after `RMK` is thrown away
  first, because remarks are a different grammar and reading them as the body is how a
  decoder invents a ceiling.
- **An ATIS now comes with it decoded.** Under the report, the eight figures you tuned in
  for, set down in a column: information letter, time, wind, visibility, cloud, temperature,
  dew point and altimeter. Read from whichever form the field uses — the METAR-coded run an
  American D-ATIS opens with, the ICAO groups a European one uses, or the plain English a
  controller speaks — with the pressure given in both units because an ATIS gives one and
  half the world flies on the other.
- The full text stays above it. The advisories are half of what an ATIS is for, and nothing
  here summarises cranes and closed taxiways. Anything the decoder cannot read with
  confidence is left out rather than guessed: a missing row is honest, a wrong one is worse
  than the text it was meant to save you reading.
- **Weather is fetched when you pick the airport**, not when you turn to the weather tab. It
  used to start loading at the moment you asked to read it, so you watched it arrive — for a
  request that takes a second or two and is then good for minutes. Choosing the airport is
  the honest signal that you are interested in it. Turning the weather off still stops it;
  that is what the switch is for.
- **A window restored bigger than the screen is pulled back onto it.** macOS hands back the
  frame it saved whether or not it still fits, and this window is usually the full height of
  the usable area, so very little has to change for it to stop fitting — the Dock coming out
  of hiding, a display with a different notch, a second monitor that has gone. The frame came
  back as it was, the bottom stayed put, and the title bar ended up above the top of the
  screen where it could not be dragged down. Checked at launch and whenever the screens
  change; only windows that do not fit are touched.
- **The Recent airports section is gone** from the sidebar, and the machinery behind it with
  it. The sidebar goes from Route Map to Airports.

- **The flight plan is drawn magenta** — its legs, its fixes and the fields at either end.
  That is what a planned track is on every navigation display and every chart that draws
  one; the accent blue it used to be is the colour of the app's own buttons and panels, and
  a route is not furniture. SID and STAR legs stay orange, which is the distinction that
  was already being made.

**The base map**

- **Apple's own map replaces Terrain.** Roads, place names and shaded relief, rendered by
  MapKit — no key, no account, and Apple carries the licensing of what it draws. It costs
  the network every time: Apple does not permit an app to keep a copy, so unlike the tiles
  it replaces there is nothing left on the disk to look at offline.
- Drawn with realistic elevation rather than flat, which is what puts the hills in it, and
  barely dimmed — it is drawn dark to begin with, and taking a third off as well leaves a
  faint suggestion of roads.
- **Out with it goes the terrain rendering**: the hillshade, the height colouring sampled
  off a VFR chart, the vector contours, and the dark ink set the pale base needed. That was
  a layer this app drew itself from raw elevation; this one is a layer Apple draws.
- Anyone who had Topographic or Terrain chosen gets this in its place rather than being
  dropped back to Drawn.

**Also**

- **Water runways are gone.** A seaplane base's landing area is tagged as a runway and is a
  stretch of lake — 865 of them in OurAirports, 47 with both ends mapped — and drawn as
  tarmac it put a grey strip down the middle of Lake Hood. Left out of both bundled tables
  and of the fetched layouts, where OpenStreetMap tags the same thing `surface=water`.
- **The runway centreline stays where the paint is.** Its dashes were measured in points on
  the screen and drawn in however many pieces the runway was clipped into, so zooming slid
  them along the tarmac. Thirty metres of paint and twenty of gap now, measured on the
  ground, in one unbroken path.
- The credits in the corner of the map are 5pt, in a size of their own.

## 1.1.0-rc.6

What this candidate adds to rc.5. Full release soon.

**A Layers button**

- **In the top right corner of the map**, on its own, away from the map controls — what it
  holds are not map controls. Each layer is read the first time it is switched on rather than
  at launch.
- **Airspace**, drawn the way a chart draws it: Class B solid blue, C magenta, D blue and
  dashed, each ring labelled with its ceiling over its floor. Boston's Class B comes out as
  its four shelves — 70/SFC, 70/20, 70/30, 70/40 — with each pair of figures out in the ring
  it belongs to rather than four of them stacked over the runway. From the FAA, which is
  public domain and thorough over the United States.
- **Or from openAIP**, for the rest of the world: 18,488 rings against the FAA's 4,223, with
  classes A and E as well as B, C and D, and the prohibited, restricted and danger areas that
  a chart outside America is mostly made of. Munich comes back as a Class D CTR to 3,500ft
  under Class C shelves to FL100, which is what the German AIP says. Not bundled — openAIP's
  data is CC BY-NC and takes a key — so `Tools/make_openaip.py` builds it on your own Mac with
  your own free key, into Application Support. Until it is there the choice is greyed out and
  the FAA's table keeps drawing.
- Heights say what they are measured from: `SFC`, `70` for hundreds of feet above the sea,
  `FL195`, `25 AGL`. A European danger area's floor is usually the last of those, and reading
  it as height above the sea puts it 2,000ft wrong over high ground.
- **A ring too small to read is left out** rather than drawn as a speck. At 16° across, 1,872
  rings are in view over Chicago and 3,835 over the Alps; only the ones more than 44 points
  across are drawn, which is 152 and 860.
- **State borders** and **town and city names**, both Natural Earth. Names are asked for in
  rank order, so the room there is goes to the places that matter.

**A finer coast, and twenty times further in**

- The deepest level of detail now draws land from **OpenStreetMap** rather than Natural Earth:
  450 points around Boston against 77, which is the difference between a harbour and a notch.
  There is no choice of coastline to make — the app simply draws the best one it can.
- Closer still, **the full OpenStreetMap coastline** — 79 million points — takes over one
  degree at a time, where it is on the Mac. 4 GB is not shippable, so
  `Tools/make_coastline.py` builds it into Application Support and the map reads only the
  cells in view: 41,147 points around Boston.
- **The zoom goes twenty times deeper**, down to about half a metre to the point, and the
  readout switches to kilometres and metres where degrees stop meaning anything.
- Lakes and borders stay Natural Earth: OpenStreetMap's coastline download is the coast and
  nothing else.

**Fixed**

- **Ocean drawn as land.** A shape running off the edge of the globe is closed along that
  edge, and the rule for which way round that arc goes was wrong in five different ways
  before it was right — at 24°S 77°W it filled the South Atlantic. Every ring is now checked
  against the face it would cover, and one that would paint over most of the globe is dropped
  instead: the worst ring anywhere now covers 0.47 of the face, and land averages 0.30 over
  108 views, where Earth is 0.29.
- **Straight lines ruled across the land** at close zoom. Not the graticule, which is what it
  looked like: the full coastline comes cut into pieces on a whole-degree grid, and stroking
  every piece drew the cuts as though they were coast. That layer is filled and not outlined
  now. The graticule also stops before it gets that close.
- The gap between a ceiling, its rule and its floor — the rule was positioned using the height
  of both lines instead of the top one, so it sat on top of the figure below it.

## 1.1.0-rc.5

What this candidate adds to rc.4. Full release soon.

**The map is a globe**

- **The world is drawn as a sphere rather than a Mercator sheet.** Orthographic: the viewer is
  infinitely far off looking at one point, so the middle of the view is face-on and the edge
  falls away the way a ball's does. Greenland is the size of Greenland. Dragging turns the
  globe rather than sliding a sheet, so it needs where the drag began and not only how far it
  has gone. The far hemisphere is not there to be drawn, which is the one real cost: a flight
  spanning more than 180° of longitude can no longer be seen whole.
- **There is no antimeridian any more.** A ring crossing 180° used to need drawing twice, once
  shifted a whole world sideways, or it swept a line back across Siberia. A sphere has no seam,
  so all of that is gone.
- A shape that runs off the edge of the globe is closed *along* the edge. Which way round that
  arc goes is the whole difficulty — the land is sometimes the larger part — and it is settled
  by finding where round the edge there is nothing at all and going the other way. Three wrong
  answers to that were caught by checks rather than by looking: an island half over the horizon
  drawn as coastline round the entire globe, Antarctica reported as containing Europe, and
  continents culled for being too big.
- Shapes are held as directions worked out when the tables are read, so putting a point on the
  sheet is two dot products and no trigonometry. The deepest level of detail still arrives in
  under 14ms with all of that folded in.

**Fixed**

- **The Caspian Sea was drawn as land.** Natural Earth keeps it as a hole in Eurasia rather
  than as a lake — the only hole in that layer — and the build was discarding holes, so
  371,000 square kilometres of water was painted as land at every level of detail. Wrong in
  rc.3 and rc.4 as well.

**Also**

- A ditto mark stands on the right with the figures it repeats, rather than centred under them.
- The Labels checkbox is gone from the map. It was on every time anyone looked at it, and names
  are still held back until there is room for them.

## 1.1.0-rc.4

What this candidate fixes in rc.3. Full release soon.

- **rc.3 went out signed ad-hoc**, despite being the release that was supposed to fix exactly
  that. The certificate reached the runner and the identity was found, but `codesign` could
  not reach the private key — and `build.sh` had been sending codesign's error to
  `/dev/null`, so the release published with notes claiming a signature it did not have and
  nothing anywhere saying otherwise. The keychain now goes into the search list as well as
  being named outright, which is what the key access needed, and a signature that fails now
  prints the reason it failed.
- **The push build signs the same way a release does**, so a broken signature fails on a push
  instead of being found in something already published. That earned its keep immediately: it
  caught a second fault in the same change, where `security import` could not work out the
  format of a temporary file that had no suffix.
- Nothing else changes from rc.3. The map's levels of detail and its runways are as they were.

## 1.1.0-rc.3

What this candidate adds to rc.2. Full release soon.

**The map draws the detail the zoom can show**

- **Four levels of detail instead of the one drawing.** rc.2 drew a single 1:50m world at every
  zoom, which carried ten times the points a whole-world view has pixels and too few to show a
  coastline close in. The map now picks between Natural Earth at 1:110m, 1:50m and 1:10m by
  zoom, and past about 2.5° across adds **runways** — 14,865 at 11,362 airports, with idents.
  Zoom in on Boston and Logan's 04L, 04R, 14, 15L and 15R are drawn where they are.
- The tier in use is named in the readout, so the level of detail is visible rather than
  guessed at. A finer tier is read on a background queue and the coarser one keeps drawing
  until it lands — 10ms for the deepest, scanned as bytes.
- **Rings are clipped to the view rather than culled by it**, which is what makes the deepest
  tier affordable: Africa-and-Eurasia is one ring of 80,000 points, and over Kansas every point
  of North America is off the panel — so leaving out what you cannot see would have erased the
  continent instead of drawing it. Clipped, that ring draws from four points and Kansas stays
  land.

**A signature that is the same one next time** — *this did not work in rc.3; see rc.4 above.*

- ~~**macOS stops asking for the Downloads folder after every update.**~~ Not in this build.
  rc.3 went out signed ad-hoc: the certificate reached the build but `codesign` could not
  reach its private key, and the error was being discarded, so the release published with
  these notes claiming a signature it did not carry. The reasoning below holds and the fix
  landed in rc.4. macOS ties a permission you have granted to the signature's designated
  requirement, and an ad-hoc signature's requirement is the build's own hash — so every
  release looked like a different app and asked again. Signed with a certificate the
  requirement is the bundle identifier and the certificate instead: the same next release, and
  the answer sticks. The certificate is self-signed and vouches for nobody — Gatekeeper treats
  the app exactly as it did before.
- **Fixed: builds intermittently came out unsigned.** (This part did work.) The strip of
  Finder attributes walked
  every file in the bundle while iCloud re-stamped the one directory `codesign` objects to, and
  lost that race often enough to matter. It now clears that directory immediately before each
  attempt, and `--install` clears it again on the way into /Applications.

## 1.1.0-rc.2

What this candidate adds to rc.1. Full release soon.

**Altitude restrictions, from real navigation data**

- The route list states what a SID or STAR demands, not only what SimBrief predicts. On the
  HYLND7 out of Boston, HURBE reads **4000** in magenta with a bar beneath it — at or above —
  while the fixes either side stay green predictions. SimBrief had that fix at 6,800: a
  prediction and a restriction are different numbers, and only one of them is a clearance.
- Airbus F-PLN formatting: magenta for a restriction and green for a prediction, a bar under a
  floor, over a ceiling, both for a single altitude, and two stacked figures for a block. No
  words — the bars say it.
- The data is the FAA's Coded Instrument Flight Procedures: public domain, reissued every 28
  days, United States only. 18,592 restrictions at 496 airports, distilled from the 53 MB the
  FAA ships to the 0.7 MB that says anything about an altitude.
- **It keeps itself current.** At launch the cycle in force — which is arithmetic, not a
  question for the network — is compared with the cycle on disk, named in the file. Out of date
  or missing, the new one is fetched, distilled and written, and only then is the old one
  deleted: an interrupted update leaves you on the previous cycle rather than on nothing.
  Settings ▸ Navigation Data shows the cycle and its dates, with a Check Now button.

**Also**

- An altitude that repeats the one above it shows a ditto instead, centred under the figure it
  stands for, so a cruise of a dozen fixes states FL360 once. A restriction is never dittoed.
- Altitudes lost their "ft": every figure in the column is feet, and saying so twelve times
  says nothing.

## 1.1.0

**A map**

- **Route Map** joins the sidebar, beside Pinned Charts. Selecting it lists the route in the
  middle column — ident, airway or procedure, altitude as a flight level above the transition —
  and draws the map where a chart would be. Drag to pan, scroll to zoom at the cursor, **Fit**
  to frame the flight. ⇧⌘M selects it.
- **Your SimBrief flight is drawn on it**, and needs no navigation database to be: the navlog
  gives every fix a latitude and longitude, which the app had been discarding in favour of the
  route string. The SID and STAR legs are picked out in orange, from SimBrief's own flag.
- Legs are drawn as **great circles**, which on a globe is simply the way the aeroplane goes:
  Boston to Heathrow passes 52.6°N halfway across, where a straight line between the two would
  have crossed at 46.9°N.
- The airports you hold charts for are on the map whether or not a flight is loaded.

**Bundled, not fetched**

The geography is Natural Earth and OpenStreetMap and the airports and runways are
OurAirports, all built by the scripts in `Tools/` into the bundle — 40 MB of tables. The
rest of the app works with the network off, and a map that needed tiles would have been the
first thing to stop.

- **Four levels of detail, chosen by zoom.** Natural Earth publishes the same world at 1:110m,
  1:50m and 1:10m, each generalised by cartographers for the scale it is meant to be seen at,
  and the map draws whichever suits: continents at a whole-world view, and from about 27°
  across the 1:10m world, which is where Cape Cod, the Finger Lakes, Georgian Bay and the
  Aegean islands come from. Closer than about 2.5° across, **runways** — 14,865 of them at
  11,362 airports, with their idents once a strip is long enough to hang one off. Which tier
  is in use is named in the readout, rather than left to be inferred.
- Tiers are read on a background queue the first time a zoom asks for one, and whichever is
  already in hand keeps drawing meanwhile: the coast sharpens a moment later instead of
  disappearing while a file is read. Scanned as bytes rather than decoded and split into
  strings, which is what gets the deepest tier — 380,000 points — down to 10ms.
- Three layers per tier, each drawn its own way: land filled, **lakes filled back in with the
  sea's colour**, and borders stroked. Borders are only the arcs two countries share, so no
  line is drawn twice and no coastline is mistaken for a frontier. All three come from the one
  tier, because a 1:10m coast beside a 1:50m border puts the frontier out at sea.
- **Rings are clipped to the view rather than culled by it.** Africa-and-Eurasia is a single
  ring of 80,000 points at 1:10m, so asking whether its extent reaches the view answers
  nothing — and leaving out the parts you cannot see is worse than useless, because the view
  is so often *inside* a ring: over Kansas every last point of North America is off the panel.
  Clipped, that ring draws from four points instead of 55,000 and still says Kansas is land.
- **The world is drawn as a sphere**, seen from outside and infinitely far off, so the middle
  of the view is face-on and the edges fall away as a ball's do. Scale is honest everywhere,
  where Mercator made Greenland the size of Africa. And there is no antimeridian to get wrong:
  a ring crossing 180° used to jump to −179° and draw a line sweeping back across the whole
  map through Siberia, and a sphere simply has no seam. Dragging turns the globe. The cost is
  the far side, which is not there to be drawn — a flight spanning more than 180° of longitude
  can no longer be seen whole.
- A shape running off the edge of the globe is closed **along** that edge, which is most of what
  drawing a sphere from vector data consists of. Which way round the closing arc goes is
  settled by finding where round the edge there is nothing at all and going the other way —
  taking the shorter way instead draws an island as coastline all the way round the world.

**Layers**

- **A Layers button** in the top right corner of the map, away from the map controls, because
  what it holds are not map controls. Three things so far, each read the first time it is
  switched on and not at launch.
- **Airspace**, drawn the way a chart draws it: Class B solid blue, C magenta, D blue and
  dashed, prohibited, restricted and danger areas red, each ring labelled with its ceiling
  over its floor. Each figure sits out in the ring it belongs to rather than four of them
  stacked over the runway, which is what a Class B's shelves would otherwise do.
- **From openAIP**, worldwide: 18,488 rings, with classes A and E as well as B, C and D, and
  the prohibited, restricted and danger areas that a chart outside America is mostly made
  of. Munich's CTR comes back Class D to 3,500ft with its TMA in Class C shelves up to FL100,
  which is what the German AIP says. Not bundled — openAIP's data is CC BY-NC and needs a
  key — so `Tools/make_openaip.py` builds it on your own Mac with your own free key, into
  Application Support, and the Layers panel says when it is not there.
- **A switch per class**: A, B, C, D, E, and one for all three kinds of area you keep out of,
  each chip in the colour that class is drawn in. Class E over the United States is every
  transition area in the country and buries everything else; over Europe it is a handful of
  rings. Which of them you want is not something an app can know.
- **A ring too small to read is left out**, rather than drawn as a speck with two illegible
  figures on it. A zoom threshold was enough for 4,223 rings and is not enough for 18,488: at
  16° across — as wide as this layer ever draws — 1,872 rings are in view over Chicago and
  3,835 over the Alps, which is a wash of colour. Only the ones more than 44 points across
  are drawn, which is 152 and 860.
- Heights are written the way each one is measured: `SFC` at the ground, `70` for hundreds of
  feet above the sea, `FL195` for a flight level, `25 AGL` where the figure is above the
  ground. A European danger area's floor is often the last of those, and calling it 2,500ft
  above the sea would put it 2,000ft wrong over high ground.
- The airspace table is read by scanning bytes rather than by decoding it into a string and
  splitting: 0.10s instead of 6.28s for openAIP's world, and it no longer loses the 25 rings
  whose names hold a stray U+0085 — a character Unicode counts as a line break, which cut
  those lines in half and dropped them without a word.
- **State borders** and **town and city names**, both Natural Earth. Names are asked for in
  rank order, so what there is room for goes to the places that matter.

**A base map you can choose**

- **Drawn, Topographic or Satellite**, in Layers. Drawn is what it always was and stays the
  default: coastline, lakes and borders from the tables in the app, and the only one that
  works with the network off.
- **Topographic is OpenTopoMap**: OpenStreetMap with SRTM contours and hillshading over it,
  fetched a tile at a time and **kept on this Mac**, so anywhere you have looked at works
  with the network off afterwards. A tile arrives in tens of milliseconds and a whole view
  in about a second; from the cache, 24ms.
- **Drawn a pixel to a pixel.** A tile server's 256-pixel squares drawn at 256 *points* are
  magnified twofold on a Retina screen, which is what a blurry map looks like; OpenTopoMap
  publishes no Retina set, so the map fetches one level deeper and draws it at half the
  size. Four times the tiles, and the difference between reading a village's name and not.
  Sampled between four pixels rather than at the nearest one, which costs 2ms a frame and
  takes the staircases off everything.
- **A third of the light comes off the base** before the overlays go over it. Both of these
  maps are made to be looked at on their own, and airspace over bright hillshading is two
  things competing.
- **Satellite is Apple Maps**, by way of `MKMapSnapshotter` — no key, no account, and Apple
  carries the licensing of the imagery. Nothing of Apple's is kept: their terms do not allow
  it, so that layer needs the network every time.
- **Reprojected, not stretched.** Apple's snapshots are Mercator and this map is a globe, so
  every pixel of the sheet is traced back through the sphere to the tile under it. Stretching
  the picture into place instead would be 2.8% out across a three-degree view at Alpine
  latitudes — twenty-eight points on a thousand-point panel, which looks exactly like a map
  that is wrong. On a sphere the Mercator northing collapses to `atanh` of the direction's
  vertical component, which is what gets the whole warp down to 13ms at Retina size; it is
  redone only when the camera moves.
- **Tiles, kept.** One snapshot of the whole view had to be fetched again the moment anything
  moved: 1.3 seconds inside MapKit for a 2800×2400 image, and another quarter of a second
  encoding it to TIFF and back, every single time. It is a pyramid of Mercator tiles now,
  asked for as map rectangles so each one is exactly a tile, and kept — so a pan of half a
  screen reuses nine tiles of twelve and redraws in **60ms** instead of a second and a half,
  and zooming a step you have already seen costs nothing at all. Four requests in flight at
  once, which measured fastest: one at a time takes 12.6 seconds to fill a view, four takes
  2.6, and ten takes 6.5 because they contend.
- **Coarse first, then sharp.** Three levels out is one or two tiles covering the whole view,
  so there is something to look at while the detail lands, and it sharpens as it arrives —
  the way every map does it. Nothing is written to disk: Apple does not permit an app to keep
  its own copy, so the tiles live in memory and go when the app does.
- Drawn from about 30° across and closer, over the drawn map rather than instead of it: a
  snapshot arrives a moment after the view moves, and a map that goes blank while it waits is
  worse than one that sharpens. Apple does not permit an app to keep its own copy, so these
  two need the network every time — with none, the drawn map is simply what you get.

**The coastline is OpenStreetMap's**

- The deepest level of detail draws land from OpenStreetMap rather than Natural Earth: 450
  points around Boston against 77, which is the difference between a harbour and a notch.
- Closer still, **the full OpenStreetMap coastline** — 79 million points — takes over a
  one-degree cell at a time, where it is on the Mac. It is not shippable at 4 GB, so
  `Tools/make_coastline.py` builds it into Application Support and the map reads only the
  cells you are looking at. 41,147 points around Boston.
- Lakes and borders stay Natural Earth: OpenStreetMap's coastline download is the coast and
  nothing else.

**Asked once, not after every update**

- **macOS stops asking for the Downloads folder each time the app updates.** It ties a
  permission you have granted to the signature's designated requirement, and an ad-hoc
  signature's requirement is the build's own hash — so every release looked like a different
  app and asked again. Releases are signed with a certificate now, which makes that
  requirement the bundle identifier and the certificate: the same next release, and the answer
  sticks. It will ask once more after updating to this, and then stop. The certificate is
  self-signed and vouches for nobody, so Gatekeeper treats the app exactly as it did before.

## 1.0.8

- **The Info tab carries the two facts that were missing**: the magnetic variation in force for
  the airport, and the date of the newest plate you hold for it — orange past 28 days, which is
  a LIDO cycle. Charts kept no date of their own before this; the scanner was already reading
  one per file to find the library's newest, so each chart now keeps it.
- **A button in the sidebar footer looks in Downloads for charts to file**, beside the rescan.
  The same check as Chart ▸ File Downloaded Charts…, where you are when you have just saved a
  plate.
- **The SimBrief button lines up with the rescan below it.** A section header sits on the
  list's own inset while the footer is a plain row, which left the two eight points apart.
- **Fixed: the manual check showed a countdown that never counted.** Asking for the check from
  the menu put the banner up reading "filing in 10s" with a number that never moved and a file
  that never happened. It now makes the same ten-second offer a launch does.

## 1.0.7

**A Runways tab of its own**

- The wind analysis moves out of the Weather tab into **Runways**, next to it: the wind
  summary, the variation, the RWY picker, the north/south diagram with its head and cross
  arrows, and the table of every runway with the star on the most headwind. **Weather** is now
  METAR, TAF and ATIS alone.
- Both tabs keep the same header — which airport, how old, fetch again — because wind an hour
  stale is worth knowing about on either, and switching airports should not depend on which one
  you are reading.
- The wind section no longer waits for a report before drawing. On its own tab that would have
  left an empty pane; instead the picker lists the airport's runways and the section says why
  nothing resolved.
- Being on either tab counts as looking, so the store fetches for both. Info and Charts still
  stop the polling, which is what collapsing the old panel used to do.
- The Info tab's runway chips are gone with it. One column with two things called Runways was
  one too many, and the picker and the table list the same runways with more to say about them.

## 1.0.6

**The chart column has tabs**

- The airport's code sits centred at the top with its name beneath it, and below that three
  tabs: **Info**, **Charts** and **Weather**. The name comes from the chart folder when it
  carries one, otherwise from the SimBrief plan — the only other place the app has been told
  what an ICAO is called.
- **Info** is new: the airport's runways as chips, with the planned one picked out, how many
  charts you hold in each category, and the folder they are in. Nothing is fetched for it.
- **Weather** is the same panel in a tab of its own, filling the column. Its drag-to-resize
  grip and remembered height are gone with the split it used to divide — a tab has nothing to
  trade height with. Another tab being on top now counts as collapsed, so looking away still
  stops the polling rather than hiding it.

**A warning when the flight plans a runway you have no plate for**

- With a flight loaded, each airport is checked against the runway the plan names. The flight
  section's row says `RWY 04R — no chart` in orange, and the chart column's header replaces its
  `RWY 04R planned` line with the warning — one line, not two. As soon as a plate serves that
  runway the plain line comes back.
- The check asks whether *any* plate serves the runway rather than insisting on the right kind:
  one plate covering both ends of a strip is normal, so demanding a SID specifically would warn
  about flights that are perfectly well served.

**Charts named `LOC 25` now know their runway**

- The name parser only read a runway from a name carrying `RWY`, or from a designator with a
  side letter like `04R`. A plate called `LOC 25` had neither, so it carried no runway at all:
  it never sorted with its fellows, never showed a runway, and the new warning called it
  missing while it sat in the list. A procedure word followed by a bare number now counts,
  **anchored to the end of the name** — a loose two-digit number is more often a date
  (`AGC 24 JUL 2025`), a page (`APC 2 OF 3`) or a frequency (`ILS 118`) than a runway.
- The runway in a chart row is a chip rather than a third word in a run of faint text, with
  tabular digits so designators line up down the list.

**Fixed**

- **The app could freeze on the startup screen.** Reading the download folder is what makes
  macOS put its permission dialog up, and that call does not return until the dialog is
  answered — on the main thread, that left the window unresponsive behind a dialog easy to miss.
  The read and the file moves now happen off the main thread.

## 1.0.5

**The runway menu holds the airport's own runways**

- The RWY menu and the wind list are filled from a bundled table of 32,000 airports, so KJFK
  offers its eight runways rather than 01 to 36. The airports that fell back to all thirty-six
  were the ones whose plates name no runway — an airport chart on its own says nothing about
  which runways exist, and there was nothing else to ask.
- Your charts still count for more: a plate named `IAC ILS Z RWY 04R` is proof from the set you
  fly, and the two are unioned, so a runway the table has missed still appears. All 36 now show
  only when nothing knows the airport at all.
- Designators only, which is all the wind maths needs — the number is the magnetic heading. The
  data is [OurAirports](https://ourairports.com/data/), public domain, 407 KB in the bundle and
  parsed once in 1.3 ms. It carries no guarantee of accuracy, so a decommissioned runway can
  linger in it. Rebuild with `Tools/make_runways.py`.

## 1.0.4

**Charts file themselves**

- Charts downloaded from the MSFS planner are offered up on launch: a banner says what is
  waiting in Downloads and files it after ten seconds, or straight away on **File now**. **Not
  now** leaves them alone for that launch only — the charts are still there next time, and
  skipping them once is not a decision to skip them for ever.
- Two shapes are recognised: `KMKE/AGC.png`, the airport folder a browser makes for a download,
  and a flat `KMKE AGC.png`. Both land as `KMKE/AGC.png`, which is how a library is already
  laid out — a folder per airport with the chart's code as the name.
- The airport code has to be four **capital** letters. That is what keeps `Scan 1.png` and a
  folder called `Docs` out of your library, both of which are otherwise four letters.
- **A chart you already have is never replaced.** It is reported back and its download left
  where it is. This is the first thing in Chartdesk that writes to the chart folder at all, and
  adding files is a very different promise from changing them.
- Chart ▸ File Downloaded Charts… runs it whenever you like, and answers even when there is
  nothing waiting. Settings ▸ Startup turns the launch offer off.

## 1.0.3

**An update shows itself installing**

- The startup screen now stays up while an update installs, with a progress bar under the
  version: *Updating to x.y.z*, then *Restarting…* with the bar full. The same screen appears
  whether the update was found at launch or asked for from the Chartdesk menu — better than the
  window simply vanishing and coming back.
- The bar is a shape rather than a measurement, because `gh` reports no byte totals on the way
  through: quick off the mark, then flattening, and short of the end. Only the new bundle being
  staged fills it, and the quit waits a beat after that so a full bar is seen rather than
  guessed at.

**The version is always in the corner**

- The bottom left of the sidebar now carries the version on every build, not only on release
  candidates. A candidate keeps its orange badge, since a pre-release that looks exactly like
  the real thing is how you report a bug from the wrong one; a final release states itself
  quietly.
- The welcome screen shows it in the same corner, for the one screen that has no sidebar.

## 1.0.2

- **The chart filter no longer holds the caret when the app opens.** SwiftUI hands a new
  window's focus to the first text field it finds, which was the filter, so the first thing you
  typed after launch went into it instead of reaching the chart list. Focus now starts nowhere.
  Clicking either search field, tabbing into it and ⌘F all work exactly as before.

## 1.0.1

**Chartdesk updates itself**

- A newer release is now **installed when the app opens**, and the app reopens on it, rather
  than asking. The chore of noticing a release and clicking through a dialog is gone.
- Settings ▸ General turns it off. **Check for Updates** in the Chartdesk menu still asks
  first, and still reports what it found either way — an update you asked about should answer
  you, and one you did not should not interrupt you, including when it fails.
- **A tag is only ever installed once automatically.** If a build's stamped version did not
  match the tag it came from, the app would install, relaunch and install again for ever, and
  an automatic updater is exactly where that loop would go unnoticed.
- It follows release candidates as well as final releases, which is what the check has done
  since 1.0.0. If you tag a candidate, machines running the automatic update will take it.

**A measured optimisation pass**

Every file read through, with before-and-after numbers for each change rather than guesses.
Nothing at rest moved — launch, memory and idle CPU are unchanged, because none of this is
work the app does while sitting still.

- **Two stalls left the main thread.** Saving marks encoded the whole annotations file on every
  stroke: 25ms for a realistically annotated library, a frame and a half dropped each time you
  lifted the pen. It is now 40ns on the main thread and the encoding happens on a utility
  queue, with a barrier on quit so a stroke and a quit in the same breath still saves. Fetching
  weather parsed the 1.4 MB VATSIM feed on the main thread too — six milliseconds — because a
  `Task` started inside a `@MainActor` store inherits it; the fetch and parse moved into
  `WeatherSource`, which is isolated to no actor.
- **Compiled regular expressions are built once, not per call.** The ATIS markup was rebuilding
  fifteen of them every time it marked a report, and the weather panel marks up three reports on
  every redraw: 180µs down to 45µs for an ATIS, 160 to 18 for a METAR. Reading the wind out of
  a METAR went from 23µs to 0.8, and an ATIS's issue time from 21µs to 0.7.
- **The VATSIM feed is parsed once per fetch, not once per airport.** Looking up an airport used
  to re-parse the whole megabyte; it is a dictionary lookup now — 6.5ms to 11ns — and the
  grouping was checked against the old code across 102 real stations at 85 airports.
- **Filtering the chart list is 9x faster.** `searchText` assembled six strings per chart on
  every keystroke and then asked Foundation for a case-insensitive search. The key is now built
  once when the chart is read and compared over UTF-8 bytes: 2.0ms to 0.23ms for two thousand
  charts, agreeing with the old behaviour across 2,807 comparisons including accented and
  decomposed names.
- **Sort keys are worked out once instead of inside comparators.** Ordering an airport's charts
  called a linear search for the category and re-parsed the runway designator on every
  comparison — 1.16ms to 0.65ms for five hundred charts. Runway designators sort the same way
  now, and reading a heading off one is 20x faster by taking it from the UTF-8 bytes.
- **The weather panel resolves its state once per redraw.** Those were computed properties, and
  each reader triggered its own evaluation: the runway list came out of the library three times,
  the METAR was parsed four times.

Two things measured and deliberately left alone: hit-testing marks for the eraser costs 11µs
per mouse move, which is 0.1% of a core while erasing, and the chart image cache's limits do
not govern its memory — clearing it frees nothing, because the 33 MB a drawn plate costs is
held inside CoreGraphics. Capping the cache by bytes changed the footprint by nothing
measurable, so that change was reverted. If memory ever matters, the lever is drawing plates at
screen resolution rather than full plate resolution.

## 1.0.0

The first release that isn't a pre-release. Everything here is new since 0.14.0.

### What changed, in short

- **Weather and ATIS.** METAR, TAF, real ATIS and VATSIM ATIS in the chart list, with the key
  values colour coded and the ATIS's age beside it.
- **Wind and crosswind.** The runway you pick drawn pointing up the page, with the wind beside
  it as a head-or-tail arrow and a crosswind arrow, both to one scale.
- **Runways come from your charts.** A plate for 04R is proof that 04R and 22L exist, so the
  runway menu fills itself and there is nothing to type.
- **Magnetic variation is a field, and it matters.** METAR wind is true, runway numbers are
  magnetic; at Boston's 15°W that is the difference between 3.5 and 8.5 knots of crosswind.
- **A UTC clock** beside the airport code, since every clearance and report is in Zulu.
- **A startup screen**, and a release candidate now says so in the corner.
- **Taxi routing is gone**, as promised when it was deprecated — 2,295 lines, and any route
  already drawn on a chart survives as an ordinary mark.
- **Night mode is gone** too, along with the inversion that never applied to your marks.
- **Requires macOS 26**, and the network code is rewritten with structured concurrency.
- **Nothing is set below 10.5 point** — the smallest labels used to be 9.
- **Fixes:** charts opened flush left instead of centred; the weather panel's drag compounded
  its own deltas and stopped at half the column; a candidate sorted *above* the release it was
  a candidate for, so anyone testing one would never have been offered the real thing.

### In full

**Taxi routing is gone**

- The taxi router, the chart calibration that fed it and the OpenStreetMap importer are all
  removed, as promised when they were deprecated. Lining a chart up with the ground was fiddly
  and the drawn routes were never dependable enough to read a clearance from.
- **Routes already drawn onto a chart survive.** They were committed as ordinary annotations,
  so they are marks like any other and outlive the feature that made them.
- `⇧⌘T`, the Taxi Route toolbar button and the Recalibrate menu item are gone with it, and the
  align, calibrate and network-preview apparatus is out of the annotation overlay — 2,295
  lines in total.
- `georeference.json` and the `taxi/` folder under `~/Library/Application Support/Chartdesk/`
  are no longer read. Nothing deletes them for you; they are yours to remove.

**Night mode is gone**

- The inverted-chart mode is removed: the toolbar button, `⇧⌘N`, the Settings section, the
  Core Image inversion, the `nightMode` and `desaturateNight` preferences and the dark canvas
  override with them. Nothing is left switched off behind a flag.
- Marks were never inverted with the plate underneath them, which is part of why the mode never
  quite worked. The annotation palette stays as it was.

**The SimBrief section can be cleared, and fetched back, from the sidebar**

- An × beside the flight section's refresh button clears the flight. There were already a Clear
  in Settings ▸ General and one in the File menu, but neither is where you are when you decide
  you are done with a flight.
- Clearing leaves a **Load SimBrief Flight** row where the section was, so getting a flight back
  is a click rather than remembering that ⇧⌘B exists. It only appears once there is an account
  to fetch from.

**A startup screen**

- The app opens on its icon, its version and the caution line while the library's first scan
  runs, so a big folder no longer opens onto an empty sidebar that fills in a beat later, and
  for two seconds beyond that — long enough to read, rather than a flash that registers as a
  glitch.
- The caution line is red on both the startup screen and the welcome screen. A chart browser
  for a simulator is exactly the thing somebody might one day reach for in a cockpit.

**The update check follows candidates**

- **It looks for pre-releases now.** It used to ask GitHub for the newest release that was
  *not* a pre-release, which made a release candidate invisible to it. It lists releases
  instead and takes the highest version — by version rather than by date, so a patch cut after
  a candidate cannot look like the newest thing going.
- Candidates are ordered against each other too. `1.0.0-rc.1` used to parse as though `rc.1`
  were a fourth version component, which sorted it *above* `1.0.0`; a release now outranks
  every candidate for it, and `rc.10` outranks `rc.9` rather than losing on string order.

**Now requires macOS 26**

- The minimum is raised from macOS 13 to **26**, ahead of 1.0. The binary reports `minos 26.0`
  against the 27 SDK.
- The network code is rewritten with structured concurrency. Fetching weather ran four
  independent requests through a `DispatchGroup` with an `NSLock` guarding a mutable capture;
  it is now four `async let`s, which says the same thing without the lock or the shared
  mutable state. `WeatherStore` and `FlightPlanStore` are `@MainActor`, so the UI state they
  hold cannot be touched off the main thread by construction.
- `onChange(of:)` moved to the two-parameter form, and the `Text.foregroundStyle` workaround in
  the wind diagram is gone — both were only there to stay compatible with macOS 13.


**Wind and crosswind**

- The weather panel now resolves the wind against your runways, each with its head and cross
  component, and draws the one you pick.
- **The selected runway is drawn on the left, always pointing up the page**, whatever its
  heading. On approach the only thing that matters is the wind relative to the runway, and a
  compass rose makes you do that rotation in your head.
- Beside it the wind is drawn as its two components: one arrow along the runway for the head or
  tail, one across it for the direct crosswind. Each label sits beyond its own arrowhead, since
  a strong crosswind pushes the corner of the pair out to the edge and a label beside the shaft
  there had its first character cut off against the arrow. Both are to one scale, so their lengths are
  comparable — a long arrow down the page beside a stub is a wind on the nose. Each points the
  way the air moves, which is also the way it pushes you, and a tailwind turns orange.
- **Runways are a menu, filled from the charts you hold**, so there is nothing to type. A plate
  named `IAC ILS Z RWY 04R` is proof that 04R exists, and that 22L does with it, being the other
  end of the same strip. An airport with no charts — one typed into the ICAO field — offers all
  36 designators instead. A list typed into the old text field is still honoured.
- **The panel resizes.** Drag the grip on its top edge to trade height with the chart list; the
  size is remembered, and the drag stops with the list still usable rather than swallowing it.
- It sits in the chart list rather than a window of its own — the airport you want weather for
  is almost always the one whose charts you are reading, and a second window would have meant
  keeping two selections in step. **⇧⌘W** shows or hides it.
- The ICAO field looks up any airport, so a destination you hold no charts for is one field away
  rather than unreachable.
- **Magnetic variation is a field, and it matters.** METAR reports wind against true north while
  a runway designator is magnetic, so at Boston's 15°W the two references differ by 15°. On
  runway 04R in a 050/20 wind that is 3.5 knots of crosswind ignored versus 8.5 knots resolved
  — a factor of two and a half. The panel says so rather than quietly computing the wrong one.
- The variation is remembered per airport, since it does not change between flights.
- Gust crosswind is computed too, and shown on hover in the list.
- A calm or variable wind produces no components rather than a confident zero, and says which
  it was.
- The star marks the most headwind of the runways listed. It is not a recommendation — Boston
  often runs 04L/04R when the wind favours 09, and 09 is frequently closed.

**Elsewhere**

- **Nothing is set below 10.5 point.** The smallest labels were 9, under the 10 that macOS's
  own smallest text style resolves to, and the floor is now a named font rather than a number
  written out at each of fifty-six sites.

- **A chart opens centred.** A fitted plate is narrower than the window, and the code that
  positioned it after zooming clamped the scroll origin to zero — which undid the clip view's
  centring and planted the chart against the left edge with all of its margin on the right.
  Only the axes the plate is actually bigger than the window on are scrolled now.
- **A release candidate says so.** A build whose version carries a pre-release suffix prints it
  in orange beside the clock, and the startup screen shows it in orange too. A candidate that
  looks exactly like the real thing is how a bug gets reported against the wrong build.
- A **UTC clock beside the airport code** in the chart list. Every clearance, report and OFP is
  in Zulu and the menu bar clock is not. It is a `TimelineView`, so it costs nothing while the
  window is hidden.

**Weather and ATIS**

- A new panel at the foot of the chart list shows the selected airport's METAR, TAF, real ATIS
  and VATSIM ATIS. It follows whichever airport you have selected.
- METAR and TAF come from the Aviation Weather Center and cover the world. Real ATIS is FAA
  D-ATIS, which is US fields only — everywhere else says so rather than leaving a blank row.
  VATSIM ATIS comes from the VATSIM data feed and appears only while a controller is online.
- **VATSIM METAR and TAF are deliberately not fetched.** VATSIM's METAR endpoint serves the
  same observation byte for byte, since it mirrors real weather, and VATSIM publishes no TAF at
  all. Requesting them would be duplicate traffic for identical text. What VATSIM uniquely has
  is the controller's ATIS, which does differ — different runways in use, and only when staffed.
- METAR and TAF are shown above ATIS. A full ATIS runs to ten lines of hold-short and crane
  advisories, which pushed the two things you actually glance at below the fold.
- Airports with a split ATIS are shown separately, labelled Arrival and Departure, rather than
  merged — Manchester currently publishes Arrival E and Departure I.
- Text is selectable, METAR and TAF are monospaced, and each source fails on its own: an ATIS
  that isn't published never stops the METAR arriving.
- **The key values are colour coded.** Two tiers rather than a colour per field: blue for the
  information letter and the wind, marked whatever their value because they are what you read
  every time, and orange for something worth a second look — visibility below 3 SM or 5000 m,
  a ceiling below 1000 ft, temperature at or below 3°C or at or above 30°C, QNH outside
  1000–1030 hPa, or weather that changes the plan. Mist, haze and light rain stay plain;
  marking those would mark half the reports in Europe. Everything else staying plain is the
  point.
- Weather codes are read only in the coded run at the top of a report. Past the pressure group
  an American ATIS is plain English, where `VA` is a visual approach and `GS` a glideslope
  rather than volcanic ash and hail.
- An ATIS shows how long ago it was issued, from its own time group: **+29 mins**, turning
  orange past an hour, since a new letter goes out at least hourly.
- D-ATIS is fetched from `atis.info` directly. `datis.clowd.io` still answers but only with a
  302 to it, so this saves a redirect on every fetch.
- **Collapsing the panel stops the requests** rather than just hiding them, and there is a
  Settings toggle to switch it off entirely. Results are cached for a minute, which keeps a
  Refresh meaningful and stays well inside VATSIM's fifteen-second polling guidance.

## 0.14.0

**Charts for the runway you're actually using**

- With a SimBrief flight loaded, plates for the planned runway float to the top of the list and
  their runway badge is highlighted. Eleven approaches at a big field is a lot to read through
  when the flight plan already says which one you want.
- The header says "RWY 04R planned", so the reordering explains itself rather than looking like
  an arbitrary sort.
- Matching is forgiving in the way charts actually are: 04 and 4 agree, a plate charted for
  "04" matches a planned 04R because LIDO issues one plate for both sides, and a plan naming
  "04" matches the plate for 04R. Reciprocals don't match — 09 is not 27.
- Nothing moves if no plate matches, or if they all do.

**A warning for stale charts**

- The sidebar footer shows the age of your chart library when the newest file in it is over 60
  days old — two LIDO cycles, so no longer a near miss. Flying a stale set is the kind of
  mistake you only notice afterwards.
- The date is the newest file's, not the effective date printed on the plate, which would mean
  reading it off the image. It moves whenever you update a set, which is what matters.

**Fixed**

- `webp` files were being skipped. The README listed them as supported but the scanner's
  extension list did not, and ImageIO decodes them perfectly well.

## 0.13.0

**Zoom and pan**

- **The scroll wheel now zooms** rather than scrolls, centred on the pointer so whatever is
  under it stays under it. A trackpad reports many small deltas where a wheel reports a few
  large ones, so the two are scaled separately to feel the same.
- **Dragging pans.** Grab the plate and pull: dragging right reveals what was to its left.
- Double-click still toggles fit and 100%, and pinch still zooms.
- Annotate mode is unaffected — while it is on, a drag draws. The overlay takes the mouse back,
  so neither behaviour needs to know about the other.

**Internal**

- The plate is now transparent to the mouse, and panning and double-clicking are handled by the
  document view underneath. Double-click no longer goes through a click recogniser, which would
  have had to delay every drag to find out whether a second click was coming.

## 0.12.1

- An airport in the flight list that you have no charts for is now clickable, and opens the
  MSFS web flight planner. There is nothing to select on those rows, so they do the next most
  useful thing instead.
- Role badges read ORIG, DEST and ALTN rather than ORI, DES and ALT.
- The category tabs are colour coded — green ARR, orange APP, blue APT, purple DEP, pale
  REF — matching how Navigraph Charts colours the same tab strip. The selected tab fills
  with its own colour rather than a single accent. A segmented `Picker` paints every
  segment the same, so the strip is now built by hand.
- The category label under each chart in the list takes the same tint, so the list and the tabs
  read as one colour scheme rather than two. Most visible in the pinned list, where categories
  mix.

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
