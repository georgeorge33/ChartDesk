#!/usr/bin/env python3
"""Builds the map's bundled tables, at three levels of detail.

    python3 Tools/make_mapdata.py path/to/sources

Writes Resources/{land,lakes,borders}-{110,50,10}.txt, airports.txt and runway-ends.txt.
Every source is public domain: Natural Earth for the geography, OurAirports for the fields
and the runways. The sources wanted in that directory, all under their published names:

    countries-110m.json                     world-atlas TopoJSON, for land and borders
    countries-50m.json                          "
    ne_110m_lakes.geojson                   Natural Earth GeoJSON
    ne_50m_lakes.geojson                        "
    ne_10m_land.geojson                         "
    ne_10m_minor_islands.geojson                "
    ne_10m_lakes.geojson                        "
    ne_10m_admin_0_boundary_lines_land.geojson  "
    airports.csv                            OurAirports
    runways.csv                                 "

Three tiers rather than one because a coastline is only ever right for one scale. Natural
Earth publishes the same world at 1:110m, 1:50m and 1:10m, each generalised by cartographers
for the scale it is meant to be seen at, and that is a better thing to draw than one file
thinned on the fly: at a whole-world zoom the 1:50m rings carry ten times the points the
screen has pixels, and zoomed in on the Aegean they carry too few. The map picks the tier
from its zoom, so what it draws is always the one drawn for that scale.

Simplified past the quantisation step, per layer rather than per tier, because how exactly a
feature is drawn matters differently for each: a coastline has an airport sitting on it and
is held to 165m, while a dashed border and a lake shore are held to 400m and nobody can tell.
Islands below each tier's threshold are dropped — at 1:110m a 60km island is a pixel.

Longitudes are *unwrapped*: a ring crossing the antimeridian keeps counting past 180 rather
than jumping to -179. A jump is what drew those sweeping horizontal lines across Siberia and
Antarctica — the renderer draws each ring a second time shifted by 360° to cover the seam.
"""
import csv
import json
import os
import sys

# name, precision, and the tolerance and smallest ring worth keeping for each layer.
# Tolerances are degrees; 0.001° is about 110m.
TIERS = [
    {"name": "110", "precision": 2,
     "land": (0.01, 0.6), "lakes": (0.01, 0.6), "borders": (0.01, 0.0)},
    {"name": "50", "precision": 2,
     "land": (0.005, 0.15), "lakes": (0.005, 0.15), "borders": (0.005, 0.0)},
    {"name": "10", "precision": 3,
     "land": (0.0015, 0.02), "lakes": (0.004, 0.03), "borders": (0.004, 0.0)},
]


# --- Geometry ----------------------------------------------------------------------------

def simplify(points, tolerance):
    """Douglas-Peucker, iteratively: the deep rings here are 80,000 points long.

    Keeps the vertices that carry the shape and drops the ones that only sit on a line
    between two others, which after rounding to the grid is most of what a tier hands over.
    """
    count = len(points)
    if count < 3 or tolerance <= 0:
        return points

    keep = [False] * count
    keep[0] = keep[count - 1] = True
    limit = tolerance * tolerance
    stack = [(0, count - 1)]

    while stack:
        first, last = stack.pop()
        if last <= first + 1:
            continue
        ax, ay = points[first]
        dx, dy = points[last][0] - ax, points[last][1] - ay
        span = dx * dx + dy * dy

        worst, at = -1.0, -1
        for index in range(first + 1, last):
            px, py = points[index]
            if span == 0:
                offset = (px - ax) ** 2 + (py - ay) ** 2
            else:
                along = ((px - ax) * dx + (py - ay) * dy) / span
                along = 0.0 if along < 0 else (1.0 if along > 1 else along)
                offset = (px - ax - along * dx) ** 2 + (py - ay - along * dy) ** 2
            if offset > worst:
                worst, at = offset, index

        if worst > limit:
            keep[at] = True
            stack.append((first, at))
            stack.append((at, last))

    return [point for point, wanted in zip(points, keep) if wanted]


def unwrap(points):
    """Keeps longitudes continuous across the antimeridian by letting them run past ±180."""
    out = []
    shift = 0.0
    for index, (lon, lat) in enumerate(points):
        if index:
            previous = points[index - 1][0] + shift
            while lon + shift - previous > 180:
                shift -= 360
            while lon + shift - previous < -180:
                shift += 360
        out.append((lon + shift, lat))
    return out


def quantise(points, precision):
    out = []
    for lon, lat in points:
        point = (round(lon, precision), round(lat, precision))
        if not out or point != out[-1]:
            out.append(point)
    return out


def span(points):
    lons = [p[0] for p in points]
    lats = [p[1] for p in points]
    return max(lons) - min(lons), max(lats) - min(lats)


def prepare(points, tolerance, precision, smallest, closed=True):
    """One ring or line, ready to write: unwrapped, simplified, on the grid, or None."""
    points = quantise(simplify(unwrap(points), tolerance), precision)
    if len(points) < (4 if closed else 2):
        return None
    if smallest > 0:
        across, up = span(points)
        if across < smallest and up < smallest:
            return None
    return points


# --- Sources -----------------------------------------------------------------------------

def decode_arcs(topology):
    scale = topology["transform"]["scale"]
    translate = topology["transform"]["translate"]
    arcs = []
    for arc in topology["arcs"]:
        x = y = 0
        points = []
        for dx, dy in arc:
            x += dx
            y += dy
            points.append((x * scale[0] + translate[0], y * scale[1] + translate[1]))
        arcs.append(points)
    return arcs


def stitch(arcs, indices):
    line = []
    for index in indices:
        piece = arcs[index] if index >= 0 else arcs[~index][::-1]
        line.extend(piece if not line else piece[1:])
    return line


def topology_polygons(geometry):
    """Every polygon in a TopoJSON geometry, as a list of its rings.

    The first ring of a polygon is its outline and the rest are holes in it. Kept apart,
    because a hole in a landmass is water: the Caspian Sea is a hole in Eurasia, and flattening
    the two together fills it in.
    """
    if geometry["type"] == "Polygon":
        return [list(geometry["arcs"])]
    if geometry["type"] == "MultiPolygon":
        return [list(polygon) for polygon in geometry["arcs"]]
    return []


def geojson_polygons(path):
    """Every polygon in a GeoJSON file, as a list of its rings — outline first."""
    found = []
    for feature in json.load(open(path, encoding="utf-8"))["features"]:
        geometry = feature.get("geometry")
        if not geometry:
            continue
        kind, coordinates = geometry["type"], geometry["coordinates"]
        if kind == "Polygon":
            polygons = [coordinates]
        elif kind == "MultiPolygon":
            polygons = coordinates
        else:
            continue
        for polygon in polygons:
            found.append([[(p[0], p[1]) for p in ring] for ring in polygon])
    return found


def outlines(polygons):
    """Just the outlines, for a layer whose holes are not wanted.

    A lake's later rings are islands within it, and this map fills lakes with the sea's
    colour — an island in a lake would be painted sea too, so they are left out.
    """
    return [polygon[0] for polygon in polygons if polygon]


def holes(polygons):
    """The holes, which in a land layer are the water inside it."""
    return [ring for polygon in polygons for ring in polygon[1:]]


def geojson_lines(path):
    """Every line in a GeoJSON file, for sources that publish borders as lines already."""
    lines = []
    for feature in json.load(open(path, encoding="utf-8"))["features"]:
        geometry = feature.get("geometry")
        if not geometry:
            continue
        kind, coordinates = geometry["type"], geometry["coordinates"]
        if kind == "LineString":
            parts = [coordinates]
        elif kind == "MultiLineString":
            parts = coordinates
        else:
            continue
        for part in parts:
            lines.append([(p[0], p[1]) for p in part])
    return lines


def shared_arcs(topology, arcs):
    """The arcs two countries have in common — a frontier, rather than a coast.

    Drawn from the topology rather than from each country's outline, so a border is one
    line instead of two on top of each other and a coastline is never mistaken for one.
    """
    counted = {}
    for geometry in topology["objects"]["countries"]["geometries"]:
        seen = set()
        for polygon in topology_polygons(geometry):
            for ring in polygon:
                for index in ring:
                    seen.add(index if index >= 0 else ~index)
        for index in seen:
            counted[index] = counted.get(index, 0) + 1
    return [arcs[index] for index, count in counted.items() if count >= 2]


# --- Writing -----------------------------------------------------------------------------

def figure(value, precision):
    """A number as short as it can be written without ever reaching for an exponent.

    `%g` would be shorter still and turns 0.0001 into `1e-04`, which the app's byte-scanning
    parser does not read. Nothing in today's tables is small enough to trip it; a rebuilt
    table at finer precision would be, silently, and a map with a coastline in the wrong
    ocean is a poor way to find that out.
    """
    text = f"{value:.{precision}f}"
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in ("", "-", "-0") else text


def write(path, header, lines, precision):
    with open(path, "w", encoding="utf-8") as out:
        out.write(f"# {header}\n")
        out.write("# lon lat lon lat …  Longitudes may run past ±180; see Tools/make_mapdata.py\n")
        for points in lines:
            out.write(" ".join(f"{figure(lon, precision)} {figure(lat, precision)}"
                               for lon, lat in points) + "\n")
    return len(lines), sum(len(points) for points in lines), os.path.getsize(path)


def build_tier(tier, source, report):
    name, precision = tier["name"], tier["precision"]
    scale = f"1:{name}m"

    if name == "10":
        land = (geojson_polygons(source("ne_10m_land.geojson"))
                + geojson_polygons(source("ne_10m_minor_islands.geojson")))
        border_lines = geojson_lines(source("ne_10m_admin_0_boundary_lines_land.geojson"))
    else:
        topology = json.load(open(source(f"countries-{name}m.json"), encoding="utf-8"))
        arcs = decode_arcs(topology)
        land = [[stitch(arcs, ring) for ring in polygon]
                for geometry in topology["objects"]["land"]["geometries"]
                for polygon in topology_polygons(geometry)]
        border_lines = shared_arcs(topology, arcs)

    land_rings = outlines(land)
    # A hole in the land is water, and this map draws water by filling it back in with the
    # sea's colour — which is what the lakes layer is. Natural Earth keeps the Caspian Sea
    # this way, as a hole in Eurasia rather than as a lake, and it is the only one.
    lake_rings = outlines(geojson_polygons(source(f"ne_{name}m_lakes.geojson"))) + holes(land)

    for layer, rings, closed in (("land", land_rings, True),
                                 ("lakes", lake_rings, True),
                                 ("borders", border_lines, False)):
        tolerance, smallest = tier[layer]
        ready = [points for points in
                 (prepare(ring, tolerance, precision, smallest, closed) for ring in rings)
                 if points]
        headers = {
            "land": f"Land at {scale} from Natural Earth (public domain).",
            "lakes": f"Lakes at {scale} from Natural Earth.",
            "borders": f"Shared country borders at {scale}, Natural Earth.",
        }
        path = f"Resources/{layer}-{name}.txt"
        report(path, *write(path, headers[layer], ready, precision))


def build_airports(source, report):
    """The fields the map marks, and the runways it draws once you are close enough."""
    wanted = {"large_airport", "medium_airport"}
    rows = 0
    with open("Resources/airports.txt", "w", encoding="utf-8") as out:
        out.write("# Airports from OurAirports (public domain): ident, lat, lon, name, town, "
                  "country.\n# Rebuild with Tools/make_mapdata.py\n")
        for row in csv.DictReader(open(source("airports.csv"), newline="", encoding="utf-8")):
            kind = row["type"]
            if kind not in wanted and not (kind == "small_airport"
                                           and row["scheduled_service"] == "yes"):
                continue
            ident = (row["ident"] or "").strip().upper()
            if not ident or not row["latitude_deg"] or not row["longitude_deg"]:
                continue
            out.write("\t".join([ident,
                                 f"{float(row['latitude_deg']):.4f}",
                                 f"{float(row['longitude_deg']):.4f}",
                                 (row["name"] or "").replace("\t", " ").strip(),
                                 (row["municipality"] or "").replace("\t", " ").strip(),
                                 row["iso_country"]]) + "\n")
            rows += 1
    report("Resources/airports.txt", rows, rows, os.path.getsize("Resources/airports.txt"))


def build_runways(source, report):
    """Runway ends, which is the last thing left to draw once the coast is a straight line.

    Five decimals, about a metre: this is the one table drawn at a scale where the ends of a
    runway are hundreds of points apart, and a rounded threshold would sit off the tarmac.
    Only runways OurAirports gives both ends for, and only the ones still open.

    Water is left out. A seaplane base's landing area is tagged as a runway and is a stretch
    of a lake — 865 of them — and drawn as tarmac it puts a grey strip down the middle of
    Lake Hood and a dozen Norwegian fjords.
    """
    rows = 0
    with open("Resources/runway-ends.txt", "w", encoding="utf-8") as out:
        out.write("# Runway ends from OurAirports (public domain): airport, ident, lat, lon, "
                  "lat, lon, width in feet.\n# Rebuild with Tools/make_mapdata.py\n")
        for row in csv.DictReader(open(source("runways.csv"), newline="", encoding="utf-8")):
            if row.get("closed") == "1" or is_water(row.get("surface")):
                continue
            try:
                ends = [float(row[field]) for field in ("le_latitude_deg", "le_longitude_deg",
                                                        "he_latitude_deg", "he_longitude_deg")]
            except (TypeError, ValueError):
                continue
            airport = (row["airport_ident"] or "").strip().upper()
            if not airport:
                continue
            # The low end names the runway; the pair reads as "04L" whichever way you fly it.
            ident = (row["le_ident"] or "").strip().upper()
            try:
                width = int(float(row["width_ft"]))
            except (TypeError, ValueError):
                width = 0
            out.write("\t".join([airport, ident] + [f"{value:.5f}" for value in ends]
                                + [str(width)]) + "\n")
            rows += 1
    report("Resources/runway-ends.txt", rows, rows, os.path.getsize("Resources/runway-ends.txt"))


def is_water(surface):
    """True for a landing area that is a stretch of water rather than a surface.

    OurAirports spells it half a dozen ways — WATER, WAT, WATER-E, WATER-G, "SUMMER WATER."
    — so this asks whether the word is in there at all.
    """
    return "WAT" in (surface or "").strip().upper()


def build_states(source, report):
    """Internal borders — states, provinces, counties — as lines, for every country.

    A layer of its own because they are only wanted sometimes: on a route across a continent
    they are clutter, and over one state they are what tells you where you are.
    """
    lines = []
    for line in geojson_lines(source("ne_10m_admin_1_states_provinces_lines.geojson")):
        ready = prepare(line, tolerance=0.004, precision=3, smallest=0.02, closed=False)
        if ready:
            lines.append(ready)
    path = "Resources/states.txt"
    report(path, *write(path, "Internal borders at 1:10m from Natural Earth (public domain).",
                        lines, 3))


def build_cities(source, report):
    """Towns and cities, with a rank so the map can show the ones there is room for.

    Natural Earth's own scale rank, 0 for the places that belong on a world map and 10 for the
    ones that only belong on a local one, which is exactly the question the map has to answer
    at every zoom. Written in rank order, so drawing them in file order draws the most
    important first — and the map's label placer gives the space to whoever asks first.
    """
    places = []
    for feature in json.load(open(source("ne_10m_populated_places.geojson"),
                                  encoding="utf-8"))["features"]:
        geometry = feature.get("geometry")
        properties = feature.get("properties") or {}
        if not geometry or geometry["type"] != "Point":
            continue
        name = (properties.get("NAME") or properties.get("NAMEASCII") or "").strip()
        if not name:
            continue
        rank = properties.get("SCALERANK")
        rank = 10 if rank is None else int(rank)
        longitude, latitude = geometry["coordinates"][0], geometry["coordinates"][1]
        places.append((rank, latitude, longitude, name.replace("\t", " ")))

    places.sort(key=lambda place: (place[0], -abs(place[1])))
    with open("Resources/cities.txt", "w", encoding="utf-8") as out:
        out.write("# Towns and cities from Natural Earth (public domain): rank, lat, lon, "
                  "name.\n# Rank 0 belongs on a world map, 10 on a local one. In rank order.\n"
                  "# Rebuild with Tools/make_mapdata.py\n")
        for rank, latitude, longitude, name in places:
            out.write(f"{rank}\t{latitude:.4f}\t{longitude:.4f}\t{name}\n")
    report("Resources/cities.txt", len(places), len(places),
           os.path.getsize("Resources/cities.txt"))


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else "."

    def source(name):
        path = os.path.join(directory, name)
        if not os.path.exists(path):
            sys.exit(f"{path}: missing. See the list at the top of this file.")
        return path

    written = []

    def report(path, count, points, size):
        written.append((path, count, points, size))

    for tier in TIERS:
        build_tier(tier, source, report)
    build_airports(source, report)
    build_runways(source, report)
    build_states(source, report)
    build_cities(source, report)

    total = 0
    for path, count, points, size in written:
        total += size
        print(f"{path:32s} {count:6d} lines {points:8d} points {size / 1024:8.0f} KB",
              file=sys.stderr)
    print(f"{'total':32s} {'':6s}       {'':8s}        {total / 1024:8.0f} KB", file=sys.stderr)


if __name__ == "__main__":
    main()
