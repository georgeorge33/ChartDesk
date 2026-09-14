#!/usr/bin/env python3
"""DEPRECATED — scheduled for removal in Chartdesk 1.0.

Taxi routing did not work well enough in practice to keep, and this importer exists only
to feed it. It still works; it is simply no longer maintained.

Fetch an airport's taxi network from OpenStreetMap and cache it for Chartdesk.

    Tools/taxi_import.py KBOS                 one airport
    Tools/taxi_import.py KBOS EGLL EIDW       several
    Tools/taxi_import.py KBOS --out /tmp      somewhere other than the cache

Data comes from the Overpass API, which is free and needs no account. It is also a shared
community service: this fetches one airport per run and writes the result to disk, so a chart
is never queried twice. Chartdesk itself never touches the network — it only reads what this
script leaves behind.

OpenStreetMap data is © OpenStreetMap contributors, licensed under the ODbL.
"""

import argparse
import collections
import json
import re
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# The main instance is frequently busy; the mirrors are checked in order.
ENDPOINTS = [
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://overpass.osm.ch/api/interpreter",
]

USER_AGENT = "chartdesk-taxi-import/1.0 (+https://github.com/georgeorge33/ChartDesk)"

# Ways are asked for by body so their node ids come back, then `>;` collects those nodes.
# Geometry alone would not do: shared node ids are what tell us two taxiways actually meet,
# and guessing that from coordinates would be a guess.
AREA_QUERY = """
[out:json][timeout:120];
(
  way["aeroway"="aerodrome"]["icao"="{icao}"];
  relation["aeroway"="aerodrome"]["icao"="{icao}"];
);
map_to_area->.apt;
(
  way["aeroway"="taxiway"](area.apt);
  way["aeroway"="taxilane"](area.apt);
  way["aeroway"="runway"](area.apt);
)->.lines;
.lines out body;
.lines >; out skel qt;
(
  node["aeroway"="parking_position"](area.apt);
  way["aeroway"="parking_position"](area.apt);
  node["aeroway"="holding_position"](area.apt);
)->.points;
.points out tags center;
"""

# Fallback for airports whose aerodrome is a node, or is not tagged with an ICAO code.
RADIUS_QUERY = """
[out:json][timeout:120];
(
  way["aeroway"="taxiway"](around:{radius},{lat},{lon});
  way["aeroway"="taxilane"](around:{radius},{lat},{lon});
  way["aeroway"="runway"](around:{radius},{lat},{lon});
)->.lines;
.lines out body;
.lines >; out skel qt;
(
  node["aeroway"="parking_position"](around:{radius},{lat},{lon});
  way["aeroway"="parking_position"](around:{radius},{lat},{lon});
  node["aeroway"="holding_position"](around:{radius},{lat},{lon});
)->.points;
.points out tags center;
"""

LOCATE_QUERY = """
[out:json][timeout:60];
nwr["aeroway"="aerodrome"]["icao"="{icao}"];
out center 1;
"""


def overpass(query, want_ways=False):
    """Runs a query against the first endpoint that gives a usable answer.

    `want_ways` matters more than it looks: an instance under load can return a perfectly
    valid empty result, and treating that as the answer would silently fall back to the
    cruder radius search. When ways are expected, an empty reply is a reason to ask the
    next mirror rather than to give up."""
    last = None
    for endpoint in ENDPOINTS:
        host = endpoint.split("/")[2]
        request = urllib.request.Request(
            endpoint,
            data=urllib.parse.urlencode({"data": query}).encode(),
            headers={"User-Agent": USER_AGENT},
        )
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                data = json.loads(response.read())
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as error:
            last = f"{endpoint}: {error}"
            print(f"    {host} unavailable, trying another", file=sys.stderr)
            time.sleep(1)
            continue

        if want_ways and not any(e.get("type") == "way" for e in data.get("elements", [])):
            last = f"{endpoint}: empty result"
            print(f"    {host} returned nothing, trying another", file=sys.stderr)
            time.sleep(1)
            continue

        return data

    if want_ways:
        return None
    raise SystemExit(f"No Overpass endpoint answered. Last error was {last}")


def locate(icao):
    data = overpass(LOCATE_QUERY.format(icao=icao))
    for element in data.get("elements", []):
        centre = element.get("center") or element
        if "lat" in centre and "lon" in centre:
            return float(centre["lat"]), float(centre["lon"])
    return None


def designator(tags):
    """The taxiway's name as a pilot would say it.

    OSM puts the designator in `ref`, but plenty of airports only carry a `name`, and the
    name is prose: Heathrow's taxiway A is named "Taxiway A", and Dublin has
    "F1 (Temp Closed)". Nobody reads back "taxiway alpha one temp closed", so the prose is
    trimmed to the designator itself. A semicolon means one stretch of pavement carries two.
    """
    raw = (tags.get("ref") or tags.get("name") or "").strip()
    if not raw:
        return []

    names = []
    for part in raw.split(";"):
        part = re.sub(r"\([^)]*\)", " ", part)          # drop "(Temp Closed)" and friends
        part = " ".join(part.split()).upper()
        # "TAXIWAY A" -> "A". Left alone for things like "APRON TWY 1", where the words are
        # part of the designator rather than a label in front of it.
        part = re.sub(r"^TAXIWAY\s+", "", part)
        part = part.strip(" -,")
        if part:
            names.append(part)
    return names


def collect(icao, radius):
    """Fetches the airport twice and merges the results.

    Neither scope is sufficient alone. The aerodrome boundary is precise but is often drawn
    tightly around the airfield, leaving terminal aprons outside it — at Boston that loses
    every apron taxilane, which is exactly the pavement that joins a gate to the taxiways. A
    plain radius search catches those but can reach a neighbouring airfield. Taking the union
    gets everything; `report` then counts disconnected clusters, so anything foreign that did
    come along is visible rather than silent.
    """
    merged, scopes = {}, []

    def absorb(elements):
        """One OSM object can arrive twice: once tagged, once as a bare geometry vertex a
        way happens to run through. Keeping only the last would throw the tags away — which
        is precisely what holding positions are, nodes sitting on a taxiway — so the two
        copies are combined field by field."""
        for element in elements:
            key = (element["type"], element["id"])
            existing = merged.get(key)
            if existing is None:
                merged[key] = dict(element)
                continue
            for field, value in element.items():
                if value and not existing.get(field):
                    existing[field] = value

    area = overpass(AREA_QUERY.format(icao=icao), want_ways=True)
    if area is not None:
        absorb(area.get("elements", []))
        scopes.append("aerodrome boundary")

    where = locate(icao)
    if where is not None:
        near = overpass(RADIUS_QUERY.format(radius=radius, lat=where[0], lon=where[1]),
                        want_ways=True)
        if near is not None:
            absorb(near.get("elements", []))
            scopes.append(f"{radius} m radius")

    if not merged:
        raise SystemExit(f"Found no taxiway data for {icao} in OpenStreetMap.")

    return list(merged.values()), " + ".join(scopes)


def position_of(element):
    """Point features come back either as a node with a position, or as a short way whose
    centre Overpass works out for us."""
    if "lat" in element and "lon" in element:
        return float(element["lat"]), float(element["lon"])
    centre = element.get("center")
    if centre:
        return float(centre["lat"]), float(centre["lon"])
    return None


def build(icao, elements, scope):
    """Turns Overpass output into the compact, index-addressed form Chartdesk reads."""
    coords = {e["id"]: (e["lat"], e["lon"])
              for e in elements if e["type"] == "node" and "lat" in e}

    used, index = [], {}

    def place(node_id):
        if node_id not in index:
            index[node_id] = len(used)
            lat, lon = coords[node_id]
            used.append([round(lat, 7), round(lon, 7)])
        return index[node_id]

    edges, runways, stands, holds = [], [], [], []
    skipped = 0

    for element in elements:
        tags = element.get("tags") or {}
        kind = tags.get("aeroway")

        if kind in ("taxiway", "taxilane", "runway"):
            node_ids = [n for n in element.get("nodes", []) if n in coords]
            if len(node_ids) < 2:
                skipped += 1
                continue
            path = [place(n) for n in node_ids]
            names = designator(tags)
            if kind == "runway":
                runways.append({"ref": (names[0] if names else ""), "n": path})
            else:
                # Taxilanes are marked so the router can prefer real taxiways and so a
                # route drawn along an apron lane can be shown for what it is.
                edges.append({"refs": names, "n": path, "lane": kind == "taxilane"})

        elif kind in ("parking_position", "holding_position"):
            where = position_of(element)
            if where is None:
                continue
            entry = {"ref": (designator(tags) or [""])[0],
                     "at": [round(where[0], 7), round(where[1], 7)]}
            (stands if kind == "parking_position" else holds).append(entry)

    return {
        "icao": icao,
        "source": "OpenStreetMap via Overpass API",
        "licence": "ODbL, © OpenStreetMap contributors",
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "scope": scope,
        "nodes": used,
        "edges": edges,
        "runways": runways,
        "stands": stands,
        "holds": holds,
    }, skipped


def cache_directory():
    base = os.path.expanduser("~/Library/Application Support/Chartdesk/taxi")
    os.makedirs(base, exist_ok=True)
    return base


def report(network, skipped):
    edges = network["edges"]
    lanes = [e for e in edges if e.get("lane")]
    named = [e for e in edges if e["refs"]]
    designators = sorted({r for e in named for r in e["refs"]})

    print(f"    {len(edges)} segments ({len(lanes)} apron taxilanes), "
          f"{len(named)} carrying a designator")
    print(f"    {len(network['runways'])} runway segments, {len(network['nodes'])} vertices")
    if designators:
        print(f"    designators: {' '.join(designators)}")
    else:
        print("    WARNING: no taxiway designators found — routes cannot be named here")
    if skipped:
        print(f"    {skipped} segments skipped for having fewer than two known nodes")

    # A junction is any node two segments have in common — usually partway along both of
    # them rather than at either end, which is why every vertex is counted, not just the tips.
    seen = {}
    for way in edges + network["runways"]:
        for node in set(way["n"]):
            seen[node] = seen.get(node, 0) + 1
    shared = sum(1 for count in seen.values() if count > 1)
    print(f"    {shared} shared nodes where segments meet")
    if shared == 0 and len(edges) > 1:
        print("    WARNING: nothing connects — routing will not work at this airport")

    stands = [s for s in network["stands"] if s["ref"]]
    print(f"    {len(stands)}/{len(network['stands'])} parking positions named, "
          f"{len(network['holds'])} holding positions")
    if network["stands"] and not lanes:
        print("    note: no apron taxilanes mapped here, so gates do not join the taxi "
              "network — routes from a stand will be approximate")

    # Anything that came along from a neighbouring airfield shows up as a second cluster.
    parent = list(range(len(network["nodes"])))
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb: parent[ra] = rb
    for way in edges + network["runways"]:
        for a, b in zip(way["n"], way["n"][1:]):
            union(a, b)
    sizes = collections.Counter(find(i) for i in range(len(network["nodes"])))
    big = [n for n in sizes.values() if n >= 20]
    if len(big) > 1:
        print(f"    NOTE: {len(big)} separate clusters of pavement "
              f"({', '.join(str(n) for n in sorted(big, reverse=True))} vertices) — check "
              f"whether a neighbouring airfield came along, and re-run with a smaller --radius")
    else:
        share = 100 * max(sizes.values()) // max(len(network["nodes"]), 1)
        print(f"    one connected airfield ({share}% of vertices in the main cluster)")

    lats = [n[0] for n in network["nodes"]]
    lons = [n[1] for n in network["nodes"]]
    span = max(lats) - min(lats), max(lons) - min(lons)
    print(f"    extent {span[0]:.4f}° lat by {span[1]:.4f}° lon")


def main():
    parser = argparse.ArgumentParser(description="Cache an airport's taxi network for Chartdesk.")
    parser.add_argument("icao", nargs="+", help="ICAO codes, e.g. KBOS EGLL")
    parser.add_argument("--out", metavar="DIR", help="write here instead of the Chartdesk cache")
    parser.add_argument("--radius", type=int, default=4000,
                        help="fallback search radius in metres (default 4000)")
    args = parser.parse_args()

    target = args.out or cache_directory()
    os.makedirs(target, exist_ok=True)

    for code in args.icao:
        code = code.upper()
        print(f"{code}:")
        elements, scope = collect(code, args.radius)
        network, skipped = build(code, elements, scope)
        report(network, skipped)

        path = os.path.join(target, f"{code}.json")
        with open(path, "w") as handle:
            json.dump(network, handle, separators=(",", ":"))
        print(f"    wrote {path} ({os.path.getsize(path) // 1024} KB)")


if __name__ == "__main__":
    main()
