#!/usr/bin/env python3
"""Fetches airports' ground layouts from OpenStreetMap, ahead of needing them.

    python3 Tools/make_layouts.py KBOS
    python3 Tools/make_layouts.py KBOS EGLL LEMD EIDW

The app fetches a layout by itself the first time you zoom into an airport, and keeps it. The
only reason for this script is that Overpass is a free, shared, community-run service whose
answer takes anywhere from twenty seconds to three minutes depending on how busy it is —
measured, the same query for Madrid took 48s one minute and 152s the next. Run this over the
fields you actually fly and they are simply there when you arrive.

Writes exactly what the app writes, to the place the app reads:

    ~/Library/Application Support/Chartdesk/layouts/ICAO.json

OpenStreetMap data is © OpenStreetMap contributors, licensed under the ODbL.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# The main instance is the busiest; the mirrors are tried in order.
ENDPOINTS = [
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://overpass.osm.ch/api/interpreter",
]
AGENT = "Chartdesk/1.1 (+https://github.com/georgeorge33/ChartDesk)"

# The aerodrome by its code, and a circle round it for the many small fields that are a bare
# node with no boundary mapped at all. Asked for as one query because a second round trip to
# a service this slow is a minute you do not get back.
QUERY = """
[out:json][timeout:90];
(
  way["aeroway"="aerodrome"]["icao"="{icao}"];
  relation["aeroway"="aerodrome"]["icao"="{icao}"];
);
map_to_area->.apt;
(
  way["aeroway"~"^(runway|taxiway|taxilane|apron)$"](area.apt);
  way["aeroway"~"^(runway|taxiway|taxilane|apron)$"](around:{radius},{lat},{lon});
  way["area:aeroway"~"^(runway|taxiway|taxilane|apron)$"](area.apt);
  way["area:aeroway"~"^(runway|taxiway|taxilane|apron)$"](around:{radius},{lat},{lon});
);
out geom;
(
  node["aeroway"~"^(parking_position|holding_position)$"](area.apt);
  way["aeroway"="parking_position"](area.apt);
  node["aeroway"~"^(parking_position|holding_position)$"](around:{radius},{lat},{lon});
  way["aeroway"="parking_position"](around:{radius},{lat},{lon});
);
out geom;
"""


def pick(table, country=None, size=None):
    """The airports to fetch, from the table the app already ships.

    `--country US --size 0` is the ninety-five large American fields, which is what "all the
    major airports" comes to and about thirty megabytes of answers.
    """
    chosen = []
    with open(table, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 7:
                continue
            if country and fields[5].upper() != country.upper():
                continue
            if size is not None and fields[6] != str(size):
                continue
            chosen.append(fields[0])
    return sorted(chosen)


def where(icao, table):
    """The airport's position, from the table the app already ships."""
    wanted = icao.upper()
    with open(table, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 3 and fields[0].upper() == wanted:
                return float(fields[1]), float(fields[2])
    return None


def fetch(icao, latitude, longitude, radius):
    body = QUERY.format(icao=icao.upper(), lat=f"{latitude:.5f}",
                        lon=f"{longitude:.5f}", radius=radius)
    last = "no answer"
    for endpoint in ENDPOINTS:
        started = time.time()
        request = urllib.request.Request(
            endpoint, data=urllib.parse.urlencode({"data": body}).encode(),
            headers={"User-Agent": AGENT})
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                raw = response.read()
        except Exception as problem:
            last = f"{urllib.parse.urlparse(endpoint).netloc}: {problem}"
            print(f"    {last}", file=sys.stderr)
            continue
        took = time.time() - started
        try:
            answer = json.loads(raw)
        except ValueError:
            last = "the answer was not JSON"
            continue
        # Overpass reports its own failures in the body, with a perfectly good HTTP 200 and
        # an empty element list. Read as "no aeroways here" that looks exactly like a field
        # nobody has mapped — which is how Albuquerque came back as "nothing to draw".
        remark = answer.get("remark")
        if remark:
            last = remark.strip()
            print(f"    {urllib.parse.urlparse(endpoint).netloc}: {last}", file=sys.stderr)
            continue
        return raw, answer, took
    raise RuntimeError(last)


def tally(answer):
    counts = {}
    for element in answer.get("elements", []):
        tags = element.get("tags") or {}
        # An outline is counted as what it is, so the line says how much of a field is
        # drawn pavement rather than a centreline with a width tag.
        kind = tags.get("aeroway")
        if tags.get("area:aeroway"):
            kind = "area:" + tags["area:aeroway"]
        if kind:
            counts[kind] = counts.get(kind, 0) + 1
    return counts


def main():
    parser = argparse.ArgumentParser(description="Fetch airport ground layouts.")
    parser.add_argument("icao", nargs="*", help="ICAO codes, or none with --country")
    parser.add_argument("--country", help="fetch every airport in this country instead")
    parser.add_argument("--size", type=int, choices=[0, 1, 2],
                        help="0 large, 1 medium, 2 small with a scheduled service")
    parser.add_argument("--radius", type=int, default=4000,
                        help="metres round the field, for airports with no boundary mapped")
    parser.add_argument("--table", default="Resources/airports.txt",
                        help="where to look the airports' positions up")
    # v2 is the query with stands and holding positions in it; an answer from the first
    # version is not missing them, it simply never asked.
    parser.add_argument("--out", default=os.path.expanduser(
        "~/Library/Application Support/Chartdesk/layouts/v2"))
    arguments = parser.parse_args()

    wanted = arguments.icao or pick(arguments.table, arguments.country, arguments.size)
    if not wanted:
        raise SystemExit("nothing to fetch: name some airports, or pass --country")

    os.makedirs(arguments.out, exist_ok=True)
    # Already on disk is already done: this is meant to be run again and again as the list
    # grows, and Overpass should not be asked twice for the same field.
    done = {name[:-5] for name in os.listdir(arguments.out) if name.endswith(".json")}
    wanted = [icao for icao in wanted if icao.upper() not in done]
    print(f"{len(wanted)} to fetch, {len(done)} already on disk", file=sys.stderr)

    missed = []
    for icao in wanted:
        icao = icao.upper()
        position = where(icao, arguments.table)
        if position is None:
            print(f"{icao}: not in {arguments.table}", file=sys.stderr)
            continue
        print(f"{icao}: asking Overpass…", file=sys.stderr)
        try:
            raw, answer, took = fetch(icao, position[0], position[1], arguments.radius)
        except RuntimeError as problem:
            print(f"{icao}: {problem}", file=sys.stderr)
            missed.append(icao)
            continue

        counts = tally(answer)
        if not counts:
            print(f"{icao}: no aeroways in the answer — either nobody has mapped this "
                  f"field, or Overpass answered with nothing and said so quietly",
                  file=sys.stderr)
            missed.append(icao)
            continue
        path = os.path.join(arguments.out, f"{icao}.json")
        with open(path, "wb") as out:
            out.write(raw)
        parts = ", ".join(f"{count} {kind}" for kind, count in sorted(counts.items()))
        print(f"{icao}: {parts}  ({len(raw) / 1024:.0f} KB in {took:.0f}s)", file=sys.stderr)

    if missed:
        # Overpass being busy is the usual reason, and it is busy in bursts: the ones it
        # turned down five minutes ago it will often hand over now. Run again for them.
        print(f"\n{len(missed)} came back empty or refused: {' '.join(missed)}",
              file=sys.stderr)
        print("Run the same command again to have another go at those.", file=sys.stderr)


if __name__ == "__main__":
    main()
