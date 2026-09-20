# Data in Chartdesk

Chartdesk draws on several public datasets. Most are public domain; the coastline, the
airspace and the topographic base map are not, and those come with obligations rather than
courtesies.

## OpenStreetMap — ODbL 1.0

**What:** `Resources/land-osm.txt`, the simplified coastline, built by
`Tools/make_coastline.py` from
[osmdata.openstreetmap.de](https://osmdata.openstreetmap.de/data/land-polygons.html). The
optional full coastline, built by the same script into Application Support, is from the same
source.

Also `~/Library/Application Support/Chartdesk/layouts/ICAO.json`: each airport's runways,
taxiways and aprons, fetched from the [Overpass API](https://overpass-api.de/) the first time
you zoom into that airport, or ahead of time by `Tools/make_layouts.py`. Overpass is a free,
shared, community-run service, so the app asks it for one airport at a time, writes the
answer to disk, and never asks twice.

**Licence:** [Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/).

**What that requires of this app, and where it is done:**

- **Attribution.** "© OpenStreetMap contributors" has to be shown wherever the data is drawn.
  The map's readout carries it, and the Layers panel says the same under its note about where
  the coast comes from.
- **Share-alike.** Those tables are a Derived Database, so they are offered under ODbL too —
  not under whatever terms the rest of this app carries. Take them and the same conditions
  follow you.

This is the coastline now — there is no longer a choice of one. Natural Earth still draws the
two zoomed-out tiers, which have no OpenStreetMap equivalent, and still provides every lake
and every border.

## Natural Earth — public domain

`Resources/land-*.txt`, `lakes-*.txt`, `borders-*.txt` at 1:110m, 1:50m and 1:10m, plus
`states.txt` (internal borders) and `cities.txt` (towns, with Natural Earth's own scale rank),
all built by `Tools/make_mapdata.py`. [naturalearthdata.com](https://www.naturalearthdata.com/about/terms-of-use/)
places these in the public domain, with no attribution required. It is credited anyway, in the
headers of the tables and in the release notes.

## openAIP — CC BY-NC 4.0

**What:** all the airspace this app draws — classes A to E, plus prohibited, restricted and
danger areas — fetched from [openAIP](https://www.openaip.net/)'s API by
`Tools/make_openaip.py`: 31,871 airspaces read, 18,488 drawn, 19 MB. There was a bundled FAA
table alongside it for a while; it knew the United States and sketched everywhere else, and
it is gone.

**Licence:** [Attribution-NonCommercial 4.0 International](https://creativecommons.org/licenses/by-nc/4.0/),
as stated on openAIP's own front page. Attribution, and no commercial use. No share-alike
clause, unlike ODbL above.

**Not shipped.** No openAIP data is in this repository or in the app. The table is built on
your own Mac, with your own free key, into Application Support — for three reasons, in order:
the release runner has no key; a worldwide airspace database bundled at release time is stale
by the next amendment cycle; and a non-commercial condition is one to accept on purpose rather
than to inherit with a download.

**Attribution, where it is done:** "© openAIP contributors · CC BY-NC 4.0" appears on the map
whenever openAIP airspace is being drawn, and beside the choice in the Layers panel.

## OpenTopoMap — CC-BY-SA 3.0

**What:** the Topographic base map. OpenStreetMap data with SRTM contours and hillshading
rendered over it, fetched a tile at a time from
[opentopomap.org](https://opentopomap.org/about) and reprojected onto the globe. Nothing is
bundled; tiles are fetched as you look at places and **kept** in Application Support, so
anywhere you have been works with the network off.

**Licence:** map data © OpenStreetMap contributors and SRTM, under ODbL; the rendering ©
OpenTopoMap under [CC-BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/). Both
credits appear on the map whenever the layer is drawn, and the Layers panel links to
OpenTopoMap's own page.

**Their servers, their rules.** The tiles come from volunteers. This app fetches at most four
at a time, never re-fetches one it already has, sends a user agent that says who is calling,
and caps what it keeps at 400 MB. OpenTopoMap asks only that their servers not be strained by
mass downloads, and this is nowhere near that.

## Apple Maps — Apple's own terms

**What:** the Satellite base map, which is `MKMapSnapshotter` imagery from Apple Maps,
reprojected onto the globe. Nothing is bundled and nothing is stored: Apple does not permit
an app to keep its own copy of map imagery, which is why this one needs the network every
time and the drawn map stays underneath it.

**Terms:** MapKit's, as part of the Apple Developer Program agreement. No key or account is
needed to use it in a Mac app. Apple asks that its maps be credited where they are shown and
that the credit not be obscured — `MKMapView` draws that itself, and a snapshot does not, so
the map draws it: the Apple logo and "Apple Maps" sit in the corner with the other credits
whenever Apple's imagery is on the sheet, and the Layers panel links to Apple's own notices
at [gspe21-ssl.ls.apple.com](https://gspe21-ssl.ls.apple.com/html/attribution.html).

Esri's World Imagery was the obvious alternative and is not usable here: it requires an
ArcGIS licence.

## OurAirports — public domain

`Resources/airports.txt`, `runways.txt` and `runway-ends.txt`, from
[ourairports.com](https://ourairports.com/data/) by way of
[davidmegginson/ourairports-data](https://github.com/davidmegginson/ourairports-data). Public
domain. Comes with no guarantee of accuracy, which is why your own charts outrank it wherever
the two disagree.

## FAA CIFP — public domain

The SID and STAR altitude restrictions, from the FAA's Coded Instrument Flight Procedures,
reissued every 28 days and fetched by the app itself. A work of the United States government
and so not subject to copyright. United States only.

---

None of this is for real-world navigation. Chartdesk is for flight simulation.
