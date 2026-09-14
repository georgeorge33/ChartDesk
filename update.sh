#!/bin/bash
#
# Installs the newest build of Chartdesk without compiling anything.
#
#   ./update.sh                 newest release, or newest green CI build
#   ./update.sh owner/repo      when run from outside the checkout
#
# Prefers a published release; falls back to the most recent successful Build
# run. CI builds are kept for 90 days, releases forever.
#
set -euo pipefail

APP_NAME="Chartdesk"
DEST="/Applications/${APP_NAME}.app"

step() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$1"; exit 1; }

command -v gh >/dev/null 2>&1 || fail "GitHub CLI not found. brew install gh"
gh auth status >/dev/null 2>&1 || fail "Not signed in. Run: gh auth login"

REPO="${1:-${CHARTDESK_REPO:-}}"
if [ -z "$REPO" ]; then
	cd "$(dirname "$0")"
	REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
[ -n "$REPO" ] || fail "Could not work out the repo. Pass it: ./update.sh owner/chartdesk"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step "Fetching the newest build of ${REPO}"
SOURCE=""
if gh release download --repo "$REPO" --pattern "${APP_NAME}.app.zip" --dir "$TMP" >/dev/null 2>&1; then
	SOURCE="release $(gh release view --repo "$REPO" --json tagName --jq .tagName 2>/dev/null || echo latest)"
else
	RUN_ID="$(gh run list --repo "$REPO" --workflow Build --status success --limit 1 \
		--json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
	[ -n "$RUN_ID" ] || fail "No release and no successful CI build to install."
	gh run download "$RUN_ID" --repo "$REPO" --name "${APP_NAME}-app" --dir "$TMP" >/dev/null \
		|| fail "Could not download the build artifact from run ${RUN_ID}."
	SOURCE="CI run ${RUN_ID}"
fi

ARCHIVE="${TMP}/${APP_NAME}.app.zip"
[ -f "$ARCHIVE" ] || ARCHIVE="$(find "$TMP" -name '*.zip' | head -1)"
[ -f "$ARCHIVE" ] || fail "The download contained no archive."

step "Unpacking (${SOURCE})"
ditto -x -k "$ARCHIVE" "${TMP}/unpacked"
APP="${TMP}/unpacked/${APP_NAME}.app"
[ -d "$APP" ] || fail "No ${APP_NAME}.app inside the archive."

# Downloads can carry the quarantine flag, and an ad-hoc signature does not
# survive Gatekeeper's check on a quarantined bundle.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --verify "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1 || true

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
	step "Quitting the running copy"
	osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
	sleep 1
fi

step "Installing to ${DEST}"
rm -rf "$DEST"
ditto "$APP" "$DEST"

VERSION="$(defaults read "${DEST}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
step "Chartdesk ${VERSION} installed from ${SOURCE}"
open "$DEST"
