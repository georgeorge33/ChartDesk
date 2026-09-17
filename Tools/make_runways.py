#!/usr/bin/env python3
"""Builds Resources/runways.txt from OurAirports' runways.csv.

    python3 Tools/make_runways.py runways.csv > Resources/runways.txt

The source is public domain (ourairports.com, via github.com/davidmegginson/ourairports-data).
Only the designators are kept — the app works out a heading from the number and needs nothing
else — so a four-megabyte table becomes a few hundred kilobytes of one line per airport:

    KJFK 04L 04R 13L 13R 22L 22R 31L 31R

Closed runways are dropped, as are the idents that are not designators at all: a heliport's
"H1", a gravel strip's "N"/"S", "WATER", "ALL".
"""
import csv
import re
import sys

DESIGNATOR = re.compile(r"^(\d{1,2})([LCRS]?)$")


def designator(ident):
    """'9' -> '09', '04l' -> '04L', anything else -> None."""
    match = DESIGNATOR.match((ident or "").strip().upper())
    if not match:
        return None
    number = int(match.group(1))
    if not 1 <= number <= 36:
        return None
    return f"{number:02d}{match.group(2)}"


def sort_key(name):
    match = DESIGNATOR.match(name)
    return (int(match.group(1)), match.group(2))


def main():
    airports = {}
    with open(sys.argv[1], newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            if row["closed"] == "1":
                continue
            ident = (row["airport_ident"] or "").strip().upper()
            if not ident:
                continue
            for end in ("le_ident", "he_ident"):
                name = designator(row[end])
                if name:
                    airports.setdefault(ident, set()).add(name)

    print("# Runway designators by airport, from OurAirports (public domain).")
    print("# Rebuild with Tools/make_runways.py; see that file for what is kept and why.")
    for ident in sorted(airports):
        print(ident, " ".join(sorted(airports[ident], key=sort_key)))


if __name__ == "__main__":
    main()
