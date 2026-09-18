#!/usr/bin/env python3
"""Builds the openAIP airspace table from openAIP's own API.

    python3 Tools/make_openaip.py

Worldwide airspace: classes A to E, plus the prohibited, restricted and danger areas, with
each ring's ceiling and floor. The FAA publishes airspace for the whole world too, but it
thins out fast outside the United States; openAIP is the community database that the rest of
the world keeps up to date, and it is where a European TMA or an African danger area actually
comes from.

You need a key. openAIP gives them away free — make an account at openaip.net, then
"My openAIP" and API keys — and this looks for it in, in order:

    --key on the command line
    the OPENAIP_API_KEY environment variable
    ~/.chartdesk/openaip-key.txt

Where it writes, and why not into the app: the release runner has no key, a worldwide
airspace database bundled at release time is stale by the next amendment cycle, and openAIP's
data is CC BY-NC — a condition better accepted on purpose than inherited with a download. The
table goes into Application Support instead, your own copy, kept as current as you keep it.
The same arrangement as the full OpenStreetMap coastline.

    ~/Library/Application Support/Chartdesk/openaip/airspace.txt
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.core.openaip.net/api/airspaces"
PAGE = 1000            # the endpoint's own default, and its documented maximum
PRECISION = 4          # about eleven metres, finer than an airspace boundary is surveyed
ATTEMPTS = 6
PAUSE = 0.4            # between pages, to stay a polite distance from the rate limit

# Not decoration. The API is behind Cloudflare, and urllib's own "Python-urllib/3.13" is
# refused before it ever reaches openAIP — Cloudflare error 1010, which reads as an
# authentication failure and is nothing of the kind. Any ordinary agent string gets through;
# this one says who is calling.
AGENT = "Chartdesk/1.1 (+https://github.com/georgeorge33/ChartDesk)"

# Only the fields the map draws, which is most of the payload saved. The whole database with
# every field is several hundred megabytes; this is a fraction of it.
FIELDS = "name,type,icaoClass,upperLimit,lowerLimit,geometry,country"

# openAIP's own numbering, from the published schema.
ICAO_CLASS = {0: "A", 1: "B", 2: "C", 3: "D", 4: "E", 5: "F", 6: "G", 8: "SUA"}
TYPE_RESTRICTED, TYPE_DANGER, TYPE_PROHIBITED = 1, 2, 3
UNIT_METRE, UNIT_FOOT, UNIT_FLIGHT_LEVEL = 0, 1, 6
DATUM_GROUND, DATUM_MEAN_SEA, DATUM_STANDARD = 0, 1, 2

# The types worth drawing. Airspace that covers a whole country — an FIR, an upper control
# area, an airway, an ADIZ — is true and useless on a map like this: it would put a line
# round the edge of the sheet and a pair of figures in the middle of the ocean. What is left
# is the terminal airspace you fly through and the areas you keep out of.
KEEP_TYPES = {
    1,   # restricted
    2,   # danger
    3,   # prohibited
    4,   # CTR
    5,   # TMZ
    6,   # RMZ
    7,   # TMA
    13,  # ATZ
    14,  # MATZ
    17,  # alert area
    18,  # warning area
    20,  # HTZ
    23,  # TIZ
    24,  # TIA
    25,  # military training area
    26,  # CTA
    36,  # military CTR
}


def key_from(argument):
    """The key, from wherever it is."""
    if argument:
        return argument.strip()
    from_environment = os.environ.get("OPENAIP_API_KEY", "").strip()
    if from_environment:
        return from_environment
    saved = os.path.expanduser("~/.chartdesk/openaip-key.txt")
    if os.path.exists(saved):
        with open(saved, encoding="utf-8") as handle:
            return handle.read().strip()
    return ""


def fetch(key, page, country=None):
    """One page, with retries.

    The key goes in the header rather than the query string so it stays out of anything that
    logs a URL.

    `fields` and a thousand-item page are both asked for rather than assumed: if the service
    turns either down — a field it does not know, a page size above its own cap — a 400 comes
    back and this drops them in turn rather than failing the whole run over a query string.
    """
    trims = [
        {"page": page, "limit": PAGE, "fields": FIELDS},   # what we want
        {"page": page, "limit": PAGE},                     # without the field list
        {"page": page, "limit": 100},                      # and with a small page
    ]
    trim = 0
    last = None
    for attempt in range(ATTEMPTS):
        query = dict(trims[min(trim, len(trims) - 1)])
        if country:
            query["country"] = country
        url = f"{API}?{urllib.parse.urlencode(query)}"
        request = urllib.request.Request(url, headers={
            "x-openaip-api-key": key,
            "Accept": "application/json",
            "User-Agent": AGENT,
        })
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as problem:
            body = problem.read().decode("utf-8", "replace")[:200]
            last = f"HTTP {problem.code}: {body}"
            # A key it does not know comes back as 404 "Failed to load user permissions",
            # which read as "no such page" would send this round the retry loop and read as
            # "no more data" would write an empty table and call it a day.
            refused = problem.code in (401, 403) or (
                problem.code == 404 and "permission" in body.lower())
            if refused:
                # A bad key will not come good by waiting, and six polite retries against an
                # authentication failure is how you get an address rate-limited.
                raise SystemExit(
                    f"openAIP refused the key — {last}\n"
                    "Check it at openaip.net under My openAIP.")
            if problem.code in (400, 422) and trim < len(trims) - 1:
                trim += 1
                print(f"    {last} — asking again with a plainer query", file=sys.stderr)
                continue
            wait = 65 if problem.code == 429 else 4 * (attempt + 1)
            print(f"    {last} — waiting {wait}s", file=sys.stderr)
            time.sleep(wait)
        except Exception as problem:            # truncated, timed out, refused
            last = f"{type(problem).__name__}: {problem}"
            print(f"    retrying page {page}: {last}", file=sys.stderr)
            time.sleep(3 * (attempt + 1))
    raise RuntimeError(f"giving up on page {page}: {last}")


def limit(vertical):
    """One vertical limit, as the token the table uses: SFC, 7000, FL195, 2500AGL, UNL.

    Self-describing rather than a number and a datum in separate columns, because "2500"
    means two different heights depending on what it is measured from, and the app has to
    draw the difference. The FAA's table writes plain feet and SFC, which are two of these
    five, so both tables read through the same parser.
    """
    if not isinstance(vertical, dict):
        return None
    value = vertical.get("value")
    if value is None:
        return None
    unit = vertical.get("unit", UNIT_FOOT)
    datum = vertical.get("referenceDatum", DATUM_MEAN_SEA)

    if unit == UNIT_FLIGHT_LEVEL:
        return f"FL{int(value)}"
    feet = int(round(value * 3.28084)) if unit == UNIT_METRE else int(value)
    if datum == DATUM_GROUND:
        return "SFC" if feet <= 0 else f"{feet}AGL"
    if datum == DATUM_STANDARD:
        return f"FL{max(feet // 100, 0)}"
    return str(feet)


def kind(airspace):
    """What to draw it as, or None to leave it out.

    An area you keep out of is drawn as that whatever its ICAO class says — a danger area
    classed G is still a danger area — and everything else is drawn by its class.
    """
    the_type = airspace.get("type")
    if the_type == TYPE_PROHIBITED:
        return "PROHIBITED"
    if the_type == TYPE_RESTRICTED:
        return "RESTRICTED"
    if the_type == TYPE_DANGER:
        return "DANGER"
    if the_type not in KEEP_TYPES:
        return None
    klass = ICAO_CLASS.get(airspace.get("icaoClass"))
    # F and G are uncontrolled, and SUA here means "unclassified" rather than an area to
    # avoid — a ring round every one of those is a layer that covers the world.
    return klass if klass in ("A", "B", "C", "D", "E") else None


def figure(value):
    text = f"{value:.{PRECISION}f}"
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in ("", "-", "-0") else text


def ring_of(geometry):
    """The outline. openAIP's schema allows one ring per airspace and no holes."""
    if not isinstance(geometry, dict) or geometry.get("type") != "Polygon":
        return []
    coordinates = geometry.get("coordinates") or []
    return coordinates[0] if coordinates else []


def convert(items):
    """Airspaces to table lines, with a tally of what went in and what did not."""
    lines, kept, dropped = [], {}, {"type": 0, "class": 0, "limits": 0, "ring": 0}
    for airspace in items:
        drawn = kind(airspace)
        if drawn is None:
            dropped["type" if airspace.get("type") not in KEEP_TYPES else "class"] += 1
            continue
        ceiling = limit(airspace.get("upperLimit"))
        floor = limit(airspace.get("lowerLimit"))
        if ceiling is None or floor is None:
            dropped["limits"] += 1
            continue

        thinned = []
        for point in ring_of(airspace.get("geometry")):
            if len(point) < 2:
                continue
            pair = (round(point[0], PRECISION), round(point[1], PRECISION))
            if not thinned or pair != thinned[-1]:
                thinned.append(pair)
        if len(thinned) < 4:
            dropped["ring"] += 1
            continue

        # Tabs separate the fields, so a name with a space in it needs no quoting — but one
        # with a tab in it would split the line, and openAIP is community-typed.
        name = (airspace.get("name") or "?").replace("\t", " ").strip() or "?"
        coordinates = " ".join(f"{figure(lon)} {figure(lat)}" for lon, lat in thinned)
        lines.append(f"{drawn}\t{name}\t{ceiling}\t{floor}\t{coordinates}")
        kept[drawn] = kept.get(drawn, 0) + 1
    return lines, kept, dropped


def default_out():
    return os.path.expanduser(
        "~/Library/Application Support/Chartdesk/openaip/airspace.txt")


def main():
    parser = argparse.ArgumentParser(description="Build the openAIP airspace table.")
    parser.add_argument("--key", help="openAIP API key (else OPENAIP_API_KEY, else "
                                      "~/.chartdesk/openaip-key.txt)")
    parser.add_argument("--out", default=default_out(), help="where to write the table")
    parser.add_argument("--country", help="ISO alpha-2 code, for a quick try of one country")
    parser.add_argument("--pages", type=int, help="stop after this many pages")
    arguments = parser.parse_args()

    key = key_from(arguments.key)
    if not key:
        raise SystemExit(
            "No openAIP key. Make a free account at openaip.net, create a key under "
            "My openAIP, then either export OPENAIP_API_KEY or put it in "
            "~/.chartdesk/openaip-key.txt")

    lines, kept, dropped = [], {}, {"type": 0, "class": 0, "limits": 0, "ring": 0}
    page, total_pages, seen = 1, None, 0
    while True:
        answer = fetch(key, page, arguments.country)
        items = answer.get("items") or []
        if not items:
            break
        total_pages = answer.get("totalPages", total_pages)
        seen += len(items)

        page_lines, page_kept, page_dropped = convert(items)
        lines.extend(page_lines)
        for klass, count in page_kept.items():
            kept[klass] = kept.get(klass, 0) + count
        for reason, count in page_dropped.items():
            dropped[reason] += count

        print(f"  page {page}{f' of {total_pages}' if total_pages else ''}: "
              f"{seen} airspaces, {len(lines)} kept", file=sys.stderr)
        if arguments.pages and page >= arguments.pages:
            break
        if not answer.get("nextPage"):
            break
        page = answer["nextPage"]
        time.sleep(PAUSE)

    if not lines:
        raise SystemExit("nothing came back — the table has been left alone")

    os.makedirs(os.path.dirname(os.path.abspath(arguments.out)), exist_ok=True)
    with open(arguments.out, "w", encoding="utf-8") as out:
        out.write("# Airspace from openAIP (© openAIP contributors, CC BY-NC 4.0).\n")
        out.write("# kind, name, ceiling, floor, then lon lat lon lat …\n")
        out.write("# Heights: SFC, feet above the sea, 2500AGL above the ground, FL195, "
                  "UNL.\n# Rebuild with Tools/make_openaip.py\n")
        for line in lines:
            out.write(line + "\n")

    size = os.path.getsize(arguments.out)
    tally = "  ".join(f"{klass} {count}" for klass, count in sorted(kept.items()))
    print(f"{arguments.out}\n  {seen} airspaces read, {len(lines)} drawn  {tally}\n"
          f"  left out: {dropped['type']} by type, {dropped['class']} by class, "
          f"{dropped['limits']} with no height, {dropped['ring']} with no ring\n"
          f"  {size / 1024 / 1024:.1f} MB", file=sys.stderr)


if __name__ == "__main__":
    main()
