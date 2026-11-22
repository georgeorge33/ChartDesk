# Data in Chartdesk

Chartdesk draws on several public datasets. Most are public domain; the airport layouts,
the airspace and Apple's maps are not, and those come with obligations rather than
courtesies. It also carries one typeface, B612 Mono, under a licence of its own.

## X-Plane Scenery Gateway — GPL v2 or later

**What:** `~/Library/Application Support/Chartdesk/layouts/xplane/ICAO.dat`: each airport's
runways, pavement, painted lines, taxi routes, holds and stands, as X-Plane's own airport file
(`apt.dat`), fetched from the [X-Plane Scenery Gateway](https://gateway.x-plane.com/) the first
time you zoom into that airport, or for every airport you have charts for with **Fetch Layouts
for Your Airports** in the Layers panel. Beside each file is a note of which approved version it
is and when it was last asked about. The Gateway is free and asks to be treated considerately,
so the app asks for one airport at a time, keeps it for good, and asks about it again only a
month later. Where the Gateway has nothing but runways for an airport, the map draws its
runways from the bundled OurAirports table and nothing more.

**Who:** drawn by the Gateway's volunteer artists in X-Plane's WorldEditor and checked by its
moderators; the Gateway is run by Laminar Research, who make X-Plane.

**Licence:** the [GNU General Public License, version 2 or later](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html),
which the Gateway's data is released under. Its copyright notices stay with it.

**What that requires of this app, and where it is done:**

- **No redistribution, so the app's own licence is untouched.** Nothing from the Gateway is in
  this repository or in the app. Each airport is fetched on your Mac, for you, the way the map
  fetches Apple's imagery, and kept there exactly as it arrived — which is the form the GPL
  calls the data's source. If a release ever bundled these files, they would ship under the
  GPL with its text and their notices, apart from the app's own code.
- **Attribution.** "X-Plane Scenery Gateway · airport layouts, GPL" is shown in the map's
  credits whenever one of its airports is drawn, and the Layers panel names it beside the
  airport layout.

## OpenStreetMap — no longer used

Up to 1.2.0 the airport layouts came from OpenStreetMap, through the Overpass API, under the
[Open Database License](https://opendatacommons.org/licenses/odbl/1-0/), and its coastline
before that, behind a drawn base map. Neither is used now: the layouts are the X-Plane
Gateway's (above) and both base maps are Apple's. The layouts that left on your Mac, in
`layouts/v2`, are removed the first time this version runs.

## Natural Earth — public domain

`Resources/borders-*.txt` at 1:110m, 1:50m and 1:10m, plus `states.txt` (internal borders)
and `cities.txt` (towns, with Natural Earth's own scale rank), all built by
`Tools/make_mapdata.py`. These are drawn over Apple's imagery, which has no frontiers and no
names on it; over Apple's own map they are held back, because it draws its own. [naturalearthdata.com](https://www.naturalearthdata.com/about/terms-of-use/)
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

`Resources/airports.txt`, `airport-names.txt`, `runways.txt` and `runway-ends.txt`, from
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

## B612 Mono — SIL Open Font License 1.1

**What:** `Resources/Fonts/B612Mono-Regular.ttf` and `B612Mono-Bold.ttf`, version 1.008, inside
the app for **Use B612 Mono** in Settings › Viewing. Taken unchanged from
[Google Fonts' copy](https://github.com/google/fonts/tree/main/ofl/b612mono) of the
[B612 project's](https://github.com/polarsys/b612) fonts.

**Who:** the typeface made for Airbus's cockpit displays, designed by Nicolas Chauveau, Thomas
Paillot, Jonathan Favre-Lamarine and Jean-Luc Vinot. Copyright 2012 The B612 Project Authors.

**Licence:** the [SIL Open Font License, version 1.1](Resources/Fonts/B612-OFL.txt), which lets
the fonts ship inside any software, free or sold, so long as they are never sold on their own
and their copyright notice and licence go wherever they do.

**What that requires of this app, and where it is done:** the licence goes with the fonts, as
`Resources/Fonts/B612-OFL.txt` in this repository and `Contents/Resources/Fonts/B612-OFL.txt` in
the app, where `build.sh` copies it beside them. The fonts are unmodified and keep their names,
and they are registered for Chartdesk alone while it runs — never installed on the Mac.
