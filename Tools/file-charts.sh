#!/bin/bash
#
# Moves charts saved by planner-chart-download.user.js into the Chartdesk library.
#
#   ./file-charts.sh              move whatever is waiting
#   ./file-charts.sh --dry-run    say what would move, touch nothing
#   ./file-charts.sh --force      replace charts already in the library
#
# Two shapes are recognised, being the two the userscript can produce:
#
#   ~/Downloads/KBOS/AGC.png      the airport folder, which Firefox creates for it
#   ~/Downloads/KBOS AGC.png      flat, from a name with the airport in front
#
# Both land as <library>/KBOS/AGC.png — a folder per airport with the chart's code as the
# name, which is how the library is already laid out.
#
# Anything else in the download folder is left alone: a file only moves if an airport code
# says where it goes, and the code has to be four CAPITAL letters. That last part matters —
# "four letters then a space" would also describe "Scan 1.png" and a "Docs" folder, and a
# script that files your downloads into your chart library should not be guessing. The
# userscript always writes the code in capitals, so nothing it saves is affected.
#
# Nothing in the library is ever overwritten or deleted without --force, because that folder
# is the one thing here that is not replaceable.
#
# Override the two locations with CHART_DOWNLOADS and CHART_LIBRARY.

set -euo pipefail

DOWNLOADS="${CHART_DOWNLOADS:-$HOME/Downloads}"
LIBRARY="${CHART_LIBRARY:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Charts}"

DRY_RUN=no
FORCE=no
for argument in "$@"; do
	case "$argument" in
	-n | --dry-run) DRY_RUN=yes ;;
	-f | --force) FORCE=yes ;;
	-h | --help)
		sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "Unknown option: $argument" >&2
		exit 2
		;;
	esac
done

[ -d "$DOWNLOADS" ] || { echo "No download folder at $DOWNLOADS" >&2; exit 1; }
[ -d "$LIBRARY" ] || { echo "No chart library at $LIBRARY" >&2; exit 1; }

moved=0
skipped=0
# Destinations this run has already spoken for. Two downloads can name the same chart — a
# flat "KBOS AGC.png" and a "KBOS/AGC.png" beside it — and without this the dry run would
# promise to file both while a real run filed one, which is the wrong way round for a preview
# to be wrong. It also stops --force having the two of them overwrite each other.
claimed=

# An airport code is four capitals, and that is the whole of what makes a file a chart here.
is_icao() {
	printf '%s' "$1" | grep -Eq '^[A-Z]{4}$'
}

file_chart() {
	local source="$1" icao="$2" name="$3" destination
	destination="$LIBRARY/$icao/$name"

	if printf '%s' "$claimed" | grep -Fqx "$icao/$name"; then
		printf '  keep   %s — another download this run is already filed as that\n' \
			"${source#"$DOWNLOADS"/}"
		skipped=$((skipped + 1))
		return 0
	fi

	if [ -e "$destination" ] && [ "$FORCE" = no ]; then
		printf '  keep   %s/%s — already in the library\n' "$icao" "$name"
		skipped=$((skipped + 1))
		return 0
	fi

	claimed="${claimed}${icao}/${name}
"

	if [ "$DRY_RUN" = yes ]; then
		printf '  would move %s → %s/%s\n' "${source#"$DOWNLOADS"/}" "$icao" "$name"
		moved=$((moved + 1))
		return 0
	fi

	mkdir -p "$LIBRARY/$icao"
	mv -f "$source" "$destination"
	printf '  moved  %s/%s\n' "$icao" "$name"
	moved=$((moved + 1))
}

echo "From $DOWNLOADS"
echo "To   $LIBRARY"
[ "$DRY_RUN" = yes ] && echo "(dry run)"

# An airport folder the download put a chart into.
while IFS= read -r -d '' chart; do
	folder="$(basename "$(dirname "$chart")")"
	is_icao "$folder" || continue
	file_chart "$chart" "$folder" "$(basename "$chart")"
done < <(find "$DOWNLOADS" -mindepth 2 -maxdepth 2 -type f -iname '*.png' -print0)

# A flat file with the airport in front of the name.
while IFS= read -r -d '' chart; do
	base="$(basename "$chart")"
	printf '%s' "$base" | grep -Eq '^[A-Z]{4}[ _-]' || continue
	file_chart "$chart" "${base:0:4}" "$(printf '%s' "${base:5}" | sed 's/^[ _-]*//')"
done < <(find "$DOWNLOADS" -mindepth 1 -maxdepth 1 -type f -iname '*.png' -print0)

# Tidy up the folders the downloads came in, but only once they are empty: rmdir refuses
# anything else, which is the point of using it rather than rm.
if [ "$DRY_RUN" = no ]; then
	while IFS= read -r -d '' folder; do
		is_icao "$(basename "$folder")" || continue
		rmdir "$folder" 2>/dev/null || true
	done < <(find "$DOWNLOADS" -mindepth 1 -maxdepth 1 -type d -print0)
fi

if [ "$moved" -eq 0 ] && [ "$skipped" -eq 0 ]; then
	echo "Nothing to file."
else
	printf 'Filed %d, kept %d.\n' "$moved" "$skipped"
	[ "$skipped" -gt 0 ] && echo "Run again with --force to replace the ones already there."
fi
exit 0
