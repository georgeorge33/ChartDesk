#!/usr/bin/env python3
"""Builds the map's OpenStreetMap coastline, at either of two levels of detail.

    python3 Tools/make_coastline.py simplified <dir>         -> Resources/land-osm.txt
    python3 Tools/make_coastline.py full <dir> <out>         -> <out>/land-osm-full.txt

`<dir>` holds the unzipped downloads from osmdata.openstreetmap.de:

    simplified-land-polygons-complete-3857/simplified_land_polygons.shp
    land-polygons-split-4326/land_polygons.shp

**Licence.** OpenStreetMap data is ODbL, not public domain like everything else the map is
built from. Two things follow, and both are obligations rather than courtesies: "©
OpenStreetMap contributors" has to be shown wherever this is drawn, and the tables written
here are a derived database, so they carry ODbL too. See LICENSES.md.

Why two levels. The simplified coastline is six times the detail of Natural Earth's 1:10m
around Boston and small enough to bundle, which covers everything down to about 100km across.
Past that it goes polygonal in turn, and only the full coastline holds up — 79 million points
of it, which cannot be bundled or read in one go, so it is cut into one-degree cells with an
index and the map reads only the cells it is looking at.

Shapefiles are read here directly. GDAL would do it in a line, but it is not a thing this
project otherwise needs installed, and the geometry in a .shp is a header and then a list of
doubles.
"""
import math
import os
import struct
import sys

EARTH = 20037508.342789244      # metres from the meridian to the antimeridian, in 3857


# --- Shapefiles ---------------------------------------------------------------------------

def polygons(path, mercator=False):
    """Every polygon in a shapefile, as a list of rings of (lon, lat).

    Yields rather than collects: the full coastline is a 1.3GB file, and holding all of it as
    Python tuples would want tens of gigabytes.
    """
    with open(path, "rb") as shapefile:
        shapefile.seek(100)                      # past the header
        while True:
            record = shapefile.read(8)
            if len(record) < 8:
                return
            _, length = struct.unpack(">ii", record)
            body = shapefile.read(length * 2)
            kind, = struct.unpack("<i", body[:4])
            if kind != 5:                        # 5 is Polygon; nothing else is wanted
                continue

            parts, points = struct.unpack("<ii", body[36:44])
            starts = list(struct.unpack(f"<{parts}i", body[44:44 + parts * 4]))
            starts.append(points)
            at = 44 + parts * 4

            flat = struct.unpack_from(f"<{points * 2}d", body, at)
            rings = []
            for part in range(parts):
                first, last = starts[part], starts[part + 1]
                pairs = list(zip(flat[first * 2:last * 2:2], flat[first * 2 + 1:last * 2:2]))
                if mercator:
                    pairs = [(x / EARTH * 180,
                              math.degrees(2 * math.atan(math.exp(y / EARTH * math.pi))
                                           - math.pi / 2))
                             for x, y in pairs]
                rings.append(pairs)
            yield rings


# --- Shaping ------------------------------------------------------------------------------

def simplify(points, tolerance):
    """Douglas-Peucker, iteratively: the rings here run to 200,000 points."""
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


def figure(value, precision):
    """A number as short as it can be written, and never in exponent form."""
    text = f"{value:.{precision}f}"
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in ("", "-", "-0") else text


def row(points, precision):
    return " ".join(f"{figure(lon, precision)} {figure(lat, precision)}"
                    for lon, lat in points)


def prepare(ring, tolerance, precision, smallest):
    points = simplify(ring, tolerance)

    out = []
    for lon, lat in points:
        point = (round(lon, precision), round(lat, precision))
        if not out or point != out[-1]:
            out.append(point)
    if len(out) < 4:
        return None

    lons = [p[0] for p in out]
    lats = [p[1] for p in out]
    if (max(lons) - min(lons)) < smallest and (max(lats) - min(lats)) < smallest:
        return None
    return out


# --- The simplified coastline, bundled ----------------------------------------------------

def build_simplified(source):
    """One table, six times the detail of Natural Earth's 1:10m, small enough to ship."""
    path = os.path.join(source, "simplified-land-polygons-complete-3857",
                        "simplified_land_polygons.shp")
    if not os.path.exists(path):
        sys.exit(f"{path}: missing. See the top of this file.")

    rings = points = 0
    with open("Resources/land-osm.txt", "w", encoding="utf-8") as out:
        out.write("# Coastline from OpenStreetMap, simplified for rendering, "
                  "© OpenStreetMap contributors, ODbL.\n")
        out.write("# lon lat lon lat …  Rebuild with Tools/make_coastline.py\n")
        for polygon in polygons(path, mercator=True):
            # Only outlines: this map fills water back in from its own layer, and an island
            # inside a lake painted as sea would be wrong twice over.
            ready = prepare(polygon[0], tolerance=0.0005, precision=4, smallest=0.005)
            if not ready:
                continue
            out.write(row(ready, 4) + "\n")
            rings += 1
            points += len(ready)

    size = os.path.getsize("Resources/land-osm.txt")
    print(f"Resources/land-osm.txt  {rings} rings  {points} points  {size / 1024:.0f} KB",
          file=sys.stderr)


# --- The full coastline, cut into cells ---------------------------------------------------

CELL = 1.0      # degrees


def cells_of(ring):
    """Every one-degree cell a ring reaches into."""
    lons = [p[0] for p in ring]
    lats = [p[1] for p in ring]
    west = math.floor(min(lons) / CELL)
    east = math.floor(max(lons) / CELL)
    south = math.floor(min(lats) / CELL)
    north = math.floor(max(lats) / CELL)
    for x in range(west, east + 1):
        for y in range(south, north + 1):
            yield x, y


def build_full(source, destination):
    """The whole coastline, in one file the map reads a cell at a time.

    79 million points cannot be read in one go, so each ring is written into every cell it
    reaches and an index says where each cell's rings are in the file. The map reads the cells
    it is looking at and nothing else.

    No Douglas-Peucker here, deliberately: this level of detail is the point of it. Rounding
    to four decimals — about eleven metres, and finer than the deepest zoom can show — does
    all the thinning that is wanted, by dropping points that land on top of each other.
    """
    path = os.path.join(source, "land-polygons-split-4326", "land_polygons.shp")
    if not os.path.exists(path):
        sys.exit(f"{path}: missing. See the top of this file.")

    os.makedirs(destination, exist_ok=True)
    table = os.path.join(destination, "coastline.txt")
    index = os.path.join(destination, "coastline-index.txt")

    # First pass: write every ring once per cell it reaches, noting where each went.
    placed = {}
    rings = written = points = 0
    with open(table, "w", encoding="utf-8") as out:
        for polygon in polygons(path):
            ready = prepare(polygon[0], tolerance=0, precision=4, smallest=0.0)
            if not ready:
                continue
            rings += 1
            line = row(ready, 4) + "\n"
            encoded = line.encode("utf-8")
            for cell in cells_of(ready):
                at = out.tell()
                out.write(line)
                placed.setdefault(cell, []).append((at, len(encoded)))
                written += 1
                points += len(ready)
            if rings % 50_000 == 0:
                print(f"  {rings} rings, {written} placements", file=sys.stderr)

    with open(index, "w", encoding="utf-8") as out:
        out.write("# Cells of the OpenStreetMap coastline: lon lat offset length …\n")
        out.write("# One degree each, west and south edges. "
                  "© OpenStreetMap contributors, ODbL.\n")
        out.write("# Rebuild with Tools/make_coastline.py\n")
        for (x, y) in sorted(placed):
            spans = " ".join(f"{at} {length}" for at, length in placed[(x, y)])
            out.write(f"{x} {y} {spans}\n")

    print(f"{table}  {rings} rings, {written} placements, {points} points, "
          f"{os.path.getsize(table) / 1e6:.0f} MB", file=sys.stderr)
    print(f"{index}  {len(placed)} cells, {os.path.getsize(index) / 1e6:.1f} MB",
          file=sys.stderr)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    what = sys.argv[1]
    if what == "simplified":
        build_simplified(sys.argv[2])
    elif what == "full":
        if len(sys.argv) < 4:
            sys.exit("full needs a destination directory")
        build_full(sys.argv[2], sys.argv[3])
    else:
        sys.exit(f"{what}: expected 'simplified' or 'full'")


if __name__ == "__main__":
    main()
