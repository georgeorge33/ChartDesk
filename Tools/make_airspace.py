#!/usr/bin/env python3
"""Builds Resources/airspace.txt from the FAA's own airspace service.

    python3 Tools/make_airspace.py

Class B, C and D, with the ceiling and floor of every shelf, which is what lets the map label
a ring "70/20" the way a chart does. Public domain: a work of the United States government,
like the CIFP the procedures come from.

Not United States only, as it turns out. The FAA publishes airspace worldwide — 1,579
airports, from CYVR to EGLL to YSSY — though the further from the United States the thinner it
gets, so treat anything outside it as a courtesy rather than a guarantee.

Fetched rather than downloaded from a file because the FAA publishes this as a feature
service. 4,400 polygons, two thousand to a request.
"""
import json
import os
import time
import sys
import urllib.parse
import urllib.request

SERVICE = ("https://services6.arcgis.com/ssFJjBXIUyZDrSYZ/ArcGIS/rest/services"
           "/Airspace/FeatureServer/0/query")
WANTED = ("IDENT_TXT,NAME_TXT,CLASS_CODE,DISTVERTUPPER_VAL,DISTVERTUPPER_UOM,"
          "DISTVERTUPPER_CODE,DISTVERTLOWER_VAL,DISTVERTLOWER_UOM,DISTVERTLOWER_CODE")
PRECISION = 4          # about eleven metres, finer than an airspace boundary is surveyed
PAGE = 150          # a page of 2,000 with geometry is 19MB, and the connection drops part-way
ATTEMPTS = 8
PAUSE = 2.0         # the service allows so many request units a minute, and geometry is dear


def fetch(where, offset):
    """One page, with retries.

    The service truncates a large response rather than refusing it, so this used to die with
    `IncompleteRead` — and the first version of this script reported "0 features" because the
    failure happened to land where nothing checked for it.
    """
    query = urllib.parse.urlencode({
        "where": where,
        "outFields": WANTED,
        "returnGeometry": "true",
        "outSR": "4326",
        "resultOffset": offset,
        "resultRecordCount": PAGE,
        "f": "geojson",
    })
    last = None
    for attempt in range(ATTEMPTS):
        try:
            with urllib.request.urlopen(f"{SERVICE}?{query}", timeout=180) as response:
                page = json.loads(response.read().decode("utf-8"))
        except Exception as problem:            # truncated, timed out, refused
            last = f"{type(problem).__name__}: {problem}"
            print(f"    retrying at {offset}: {last}", file=sys.stderr)
            time.sleep(3 * (attempt + 1))
            continue

        # A refusal comes back as a perfectly good HTTP 200 with an error in the body. Read as
        # "no features" it looks exactly like the end of the data, which is how the first run
        # of this stopped at 500 of 4,371 and said nothing was wrong.
        problem = page.get("error")
        if problem:
            code = problem.get("code")
            last = f"{code}: {problem.get('message')}"
            wait = 65 if code == 429 else 5 * (attempt + 1)
            print(f"    {last} — waiting {wait}s", file=sys.stderr)
            time.sleep(wait)
            continue
        return page
    raise RuntimeError(f"giving up at offset {offset}: {last}")


def figure(value):
    text = f"{value:.{PRECISION}f}"
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in ("", "-", "-0") else text


def rings(geometry):
    if not geometry:
        return []
    kind, coordinates = geometry["type"], geometry["coordinates"]
    if kind == "Polygon":
        polygons = [coordinates]
    elif kind == "MultiPolygon":
        polygons = coordinates
    else:
        return []
    # Outlines only. An airspace hole is vanishingly rare and would need the fill cut back
    # out of itself, which is not a thing this map does for a translucent layer.
    return [polygon[0] for polygon in polygons if polygon]


def feet(properties, which):
    value = properties.get(f"DISTVERT{which}_VAL")
    unit = (properties.get(f"DISTVERT{which}_UOM") or "FT").upper()
    code = (properties.get(f"DISTVERT{which}_CODE") or "").upper()
    if value is None:
        return None, code
    if unit == "FL":                     # flight level, given in hundreds
        return int(value * 100), code
    if unit in ("M", "METERS"):
        return int(value * 3.28084), code
    return int(value), code


def main():
    out_path = "Resources/airspace.txt"
    where = "CLASS_CODE IN ('B','C','D')"

    lines = []
    kept = {"B": 0, "C": 0, "D": 0}
    points = 0
    offset = 0
    while True:
        page = fetch(where, offset)
        features = page.get("features", [])
        if not features:
            break
        for feature in features:
            properties = feature.get("properties") or {}
            klass = (properties.get("CLASS_CODE") or "").strip().upper()
            if klass not in kept:
                continue
            upper, _ = feet(properties, "UPPER")
            lower, lowerCode = feet(properties, "LOWER")
            # The service uses negative sentinels where it has no figure -- -9998 and
            # -999800 both turn up -- and a ring labelled "-99/SFC" is worse than no ring.
            if upper is None or upper <= 0:
                continue
            # A floor at the surface is drawn "SFC" rather than "0", the way a chart has it.
            floor = "SFC" if lowerCode == "SFC" or not lower else str(lower)
            ident = (properties.get("IDENT_TXT") or "").strip().upper() or "?"

            for ring in rings(feature.get("geometry")):
                thinned = []
                for point in ring:
                    pair = (round(point[0], PRECISION), round(point[1], PRECISION))
                    if not thinned or pair != thinned[-1]:
                        thinned.append(pair)
                if len(thinned) < 4:
                    continue
                coordinates = " ".join(f"{figure(lon)} {figure(lat)}" for lon, lat in thinned)
                lines.append(f"{klass}\t{ident}\t{upper}\t{floor}\t{coordinates}")
                kept[klass] += 1
                points += len(thinned)

        offset += len(features)
        print(f"  {offset} features", file=sys.stderr)
        if len(features) < PAGE:
            break
        time.sleep(PAUSE)

    with open(out_path, "w", encoding="utf-8") as out:
        out.write("# Class B, C and D airspace from the FAA (public domain, United States "
                  "only).\n")
        out.write("# class, ident, ceiling in feet, floor in feet or SFC, then lon lat lon "
                  "lat …\n# Rebuild with Tools/make_airspace.py\n")
        for line in lines:
            out.write(line + "\n")

    size = os.path.getsize(out_path)
    print(f"{out_path}  B {kept['B']}  C {kept['C']}  D {kept['D']}  "
          f"{points} points  {size / 1024:.0f} KB", file=sys.stderr)


if __name__ == "__main__":
    main()
