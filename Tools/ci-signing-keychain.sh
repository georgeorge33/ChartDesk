#!/bin/bash
#
# Puts Chartdesk's signing certificate into a throwaway keychain, for a build on CI.
#
# Reads the certificate from the environment -- CERTIFICATE, the .p12 in base64, and
# CERTIFICATE_PASSWORD -- and names the keychain it made in GITHUB_ENV as
# CHARTDESK_SIGN_KEYCHAIN, which is where build.sh looks. With no certificate in the
# environment it says so and exits nothing-doing, and the build is signed ad-hoc as it was
# before any of this existed.
#
# Why a certificate at all: macOS ties a permission it has granted to the signature's
# designated requirement, and for an ad-hoc signature that requirement is the build's own
# hash -- so every release looked like a new app and asked for the Downloads folder again.
# See the comment above the signing step in build.sh.
set -euo pipefail

if [ -z "${CERTIFICATE:-}" ]; then
	echo "No signing certificate in the environment; this build will be signed ad-hoc."
	exit 0
fi

KEYCHAIN="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/chartdesk-signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
CERTIFICATE_FILE="$(mktemp -t chartdesk-signing)"
trap 'rm -f "$CERTIFICATE_FILE"' EXIT

printf '%s' "$CERTIFICATE" | base64 --decode > "$CERTIFICATE_FILE"

rm -f "$KEYCHAIN"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# Long enough for a build, and no lock on sleep: a keychain that relocks halfway through is a
# signature that fails for no reason anybody can see.
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

security import "$CERTIFICATE_FILE" -k "$KEYCHAIN" -P "$CERTIFICATE_PASSWORD" \
	-T /usr/bin/codesign -A

# In the search list as well as named outright. `codesign --keychain` finds the certificate
# without this, but on a runner it then failed to reach the private key -- which is how the
# first attempt at this shipped a release still signed ad-hoc.
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

# Lets codesign use the key without a prompt there is nobody to answer.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" \
	"$KEYCHAIN" > /dev/null

echo "Identities in ${KEYCHAIN}:"
security find-identity -p codesigning "$KEYCHAIN"

if [ -n "${GITHUB_ENV:-}" ]; then
	echo "CHARTDESK_SIGN_KEYCHAIN=${KEYCHAIN}" >> "$GITHUB_ENV"
fi
