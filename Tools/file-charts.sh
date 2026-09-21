#!/bin/bash
#
# Moves charts saved by planner-chart-download.user.js into the Chartdesk library.
#
#   ./file-charts.sh              move whatever is waiting
#   ./file-charts.sh --dry-run    say what would move, touch nothing
#   ./file-charts.sh --force      replace even a chart that matches byte for byte
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
# A chart already in the library is compared rather than trusted. Identical to the download,
# it stays as it is and the download is dropped — nothing can be lost by discarding a copy
# that matches byte for byte, and leaving it behind only means deciding about it again next
# run. Different, and the download is the newer issue, because charts are redrawn every AIRAC
# cycle and the planner serves the current one; it replaces what is there.
#
# So the library is still never overwritten by something that is not a chart, and never
# rewritten with the same bytes, which would churn a synced folder for nothing. --force
# replaces even a match, which is only of use for repairing a file that has gone bad.
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
		sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'
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
replaced=0
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
	local source="$1" icao="$2" name="$3" destination verb past
	# Firefox does not overwrite a repeated download, it numbers it: a second sweep of an
	# airport arrives as AGC(1).png, which would be filed as a chart of its own and sit
	# beside the one it was meant to replace. Only a bare number in brackets at the very end
	# goes; a chart really called "RNAV (GPS) 01" keeps its brackets.
	name="$(printf '%s' "$name" | sed -E 's/ *\(([0-9]+)\)(\.[Pp][Nn][Gg])$/\2/')"
	destination="$LIBRARY/$icao/$name"

	if printf '%s' "$claimed" | grep -Fqx "$icao/$name"; then
		printf '  keep   %s — another download this run is already filed as that\n' \
			"${source#"$DOWNLOADS"/}"
		skipped=$((skipped + 1))
		return 0
	fi

	verb=file
	past=filed
	if [ -e "$destination" ]; then
		if [ "$FORCE" = no ] && cmp -s "$source" "$destination"; then
			skipped=$((skipped + 1))
			# Safe to drop: it matches what is filed exactly, so there is nothing in it
			# that the library does not already hold.
			if [ "$DRY_RUN" = yes ]; then
				printf '  same   %s/%s — matches byte for byte, download would be dropped\n' \
					"$icao" "$name"
			else
				rm -f "$source"
				printf '  same   %s/%s — matches byte for byte, download dropped\n' \
					"$icao" "$name"
			fi
			return 0
		fi
		verb=replace
		past=replaced
	fi

	claimed="${claimed}${icao}/${name}
"

	if [ "$DRY_RUN" = yes ]; then
		printf '  would %s %s → %s/%s\n' "$verb" "${source#"$DOWNLOADS"/}" "$icao" "$name"
		if [ "$verb" = replace ]; then replaced=$((replaced + 1)); else moved=$((moved + 1)); fi
		return 0
	fi

	mkdir -p "$LIBRARY/$icao"
	mv -f "$source" "$destination"
	printf '  %-8s %s/%s\n' "$past" "$icao" "$name"
	if [ "$verb" = replace ]; then replaced=$((replaced + 1)); else moved=$((moved + 1)); fi
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

if [ "$moved" -eq 0 ] && [ "$replaced" -eq 0 ] && [ "$skipped" -eq 0 ]; then
	echo "Nothing to file."
else
	printf 'Filed %d, replaced %d, already had %d.\n' "$moved" "$replaced" "$skipped"
fi
exit 0
