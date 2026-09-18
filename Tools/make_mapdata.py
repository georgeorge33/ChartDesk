#!/usr/bin/env python3
"""Builds the map's bundled tables.

    python3 Tools/make_mapdata.py countries-50m.json ne_50m_lakes.geojson airports.csv

Writes Resources/land.txt, borders.txt, lakes.txt and airports.txt. Every source is public
domain: Natural Earth at 1:50m for the geography (by way of world-atlas' TopoJSON and the
natural-earth-vector GeoJSON), OurAirports for the fields.

Three files rather than one because each is drawn differently: land is filled, lakes are
filled back in with the sea's colour, and borders are stroked. Borders are the arcs that two
countries share, so a border is one line rather than two on top of each other, and a coastline
is not mistaken for one.

Longitudes are *unwrapped*: a ring crossing the antimeridian keeps counting past 180 rather
than jumping to -179. A jump is what drew those sweeping horizontal lines across Siberia and
Antarctica — the renderer draws each ring a second time shifted by 360° to cover the seam.

Coordinates are rounded to two decimals, about a kilometre, and rings smaller than a fifth of
a degree are dropped: at 1:50m the file is mostly islands too small to see.
"""
import csv
import json
import sys

PRECISION = 2
MIN_SPAN = 0.2


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


def polygons(geometry):
    """Every ring in a geometry, whichever of the two polygon shapes it is."""
    if geometry["type"] == "Polygon":
        return list(geometry["arcs"])
    if geometry["type"] == "MultiPolygon":
        return [ring for polygon in geometry["arcs"] for ring in polygon]
    return []


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


def thin(points):
    result = []
    for lon, lat in points:
        point = (round(lon, PRECISION), round(lat, PRECISION))
        if not result or point != result[-1]:
            result.append(point)
    return result


def worth_drawing(points):
    if len(points) < 4:
        return False
    lons = [p[0] for p in points]
    lats = [p[1] for p in points]
    return (max(lons) - min(lons)) >= MIN_SPAN or (max(lats) - min(lats)) >= MIN_SPAN


def write(path, header, lines):
    with open(path, "w", encoding="utf-8") as out:
        out.write(f"# {header}\n")
        out.write("# lon lat lon lat …  Longitudes may run past ±180; see Tools/make_mapdata.py\n")
        for points in lines:
            out.write(" ".join(f"{lon:g} {lat:g}" for lon, lat in points) + "\n")
    return len(lines)


def main():
    countries_file, lakes_file, airports_file = sys.argv[1], sys.argv[2], sys.argv[3]
    topology = json.load(open(countries_file, encoding="utf-8"))
    arcs = decode_arcs(topology)

    # --- Land, filled --------------------------------------------------------------------
    land = []
    for geometry in topology["objects"]["land"]["geometries"]:
        for ring in polygons(geometry):
            points = thin(unwrap(stitch(arcs, ring)))
            if worth_drawing(points):
                land.append(points)

    # --- Borders: the arcs two countries have in common ----------------------------------
    used = {}
    for geometry in topology["objects"]["countries"]["geometries"]:
        seen = set()
        for ring in polygons(geometry):
            for index in ring:
                seen.add(index if index >= 0 else ~index)
        for index in seen:
            used[index] = used.get(index, 0) + 1

    borders = []
    for index, count in used.items():
        if count < 2:
            continue
        points = thin(unwrap(arcs[index]))
        if len(points) >= 2:
            borders.append(points)

    # --- Lakes, filled back in with the sea ----------------------------------------------
    lakes = []
    for feature in json.load(open(lakes_file, encoding="utf-8"))["features"]:
        geometry = feature["geometry"]
        rings = ([geometry["coordinates"]] if geometry["type"] == "Polygon"
                 else geometry["coordinates"])
        for polygon in rings:
            # The first ring is the outline; the rest are islands within the lake.
            points = thin(unwrap([(p[0], p[1]) for p in polygon[0]]))
            if worth_drawing(points):
                lakes.append(points)

    counts = [
        ("Resources/land.txt", write("Resources/land.txt",
                                     "Land at 1:50m from Natural Earth (public domain).", land)),
        ("Resources/borders.txt", write("Resources/borders.txt",
                                        "Shared country borders at 1:50m, Natural Earth.",
                                        borders)),
        ("Resources/lakes.txt", write("Resources/lakes.txt",
                                      "Lakes at 1:50m from Natural Earth.", lakes)),
    ]

    # --- Airports ------------------------------------------------------------------------
    wanted = {"large_airport", "medium_airport"}
    rows = 0
    with open("Resources/airports.txt", "w", encoding="utf-8") as out:
        out.write("# Airports from OurAirports (public domain): ident, lat, lon, name, town, "
                  "country.\n# Rebuild with Tools/make_mapdata.py\n")
        with open(airports_file, newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
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
    counts.append(("Resources/airports.txt", rows))

    for path, count in counts:
        print(f"{path}: {count}", file=sys.stderr)


if __name__ == "__main__":
    main()
