#!/bin/bash
#
# Puts this folder on GitHub.
#
#   ./publish.sh                 create/push "chartdesk", public
#   ./publish.sh my-name         use a different repo name
#   ./publish.sh my-name private make it private
#
set -euo pipefail
cd "$(dirname "$0")"

REPO="${1:-chartdesk}"
VISIBILITY="--${2:-public}"

if ! command -v git >/dev/null 2>&1; then
	echo "git not found. Install the Xcode command line tools first."
	exit 1
fi

if [ ! -d .git ]; then
	git init -b main
fi

git add -A
git commit -m "Chartdesk: a macOS browser for local LIDO chart images" || echo "Nothing new to commit."

if git remote get-url origin >/dev/null 2>&1; then
	git push -u origin main
	echo "Pushed to $(git remote get-url origin)"
	exit 0
fi

if command -v gh >/dev/null 2>&1; then
	gh repo create "$REPO" "$VISIBILITY" --source=. --remote=origin --push
	echo "Published: $(gh repo view "$REPO" --json url --jq .url 2>/dev/null || echo "$REPO")"
else
	cat <<'NEXT'

The GitHub CLI is not installed, so the repo has to be created in the browser.

  1. brew install gh && gh auth login    then run this script again
     — or —
  2. Create an empty repo at https://github.com/new, then:

       git remote add origin "https://github.com/$(gh api user --jq .login)/chartdesk.git"
       git push -u origin main

NEXT
fi
