#!/bin/bash
#
# Builds Chartdesk.app.
#
#   ./build.sh            build
#   ./build.sh --run      build, then launch
#   ./build.sh --install  build, copy to /Applications, launch
#   ./build.sh --spm      build through SwiftPM instead of calling swiftc directly
#   ./build.sh --doctor   print toolchain details and exit
#
# The default path calls swiftc directly. The app has no dependencies, so SwiftPM
# buys us nothing and its newer XCBuild backend needs a full Xcode install to even
# start up. Calling the compiler works with the Command Line Tools alone.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Chartdesk"
APP="build/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
DEPLOYMENT_TARGET="26.0"

step() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m  ! \033[0m%s\n' "$1"; }

# --- Macro plugins ---------------------------------------------------------
# SwiftUI's @State, @StateObject and friends are macros now, so the compiler has
# to be handed the plugin directories. Xcode passes these automatically; swiftc
# on its own does not. The SwiftUIMacros plugin ships inside Xcode's macOS
# platform directory, NOT in the Command Line Tools, so this looks in every
# plausible place rather than assuming one layout.
PLUGIN_FLAGS=()
PLUGIN_DIRS_FOUND=()
APPLICATIONS_DIR="${CHARTDESK_APPLICATIONS_DIR:-/Applications}"

add_plugin_dir() {
	local dir="$1" server="${2:-}"
	[ -d "$dir" ] || return 0
	case " ${PLUGIN_DIRS_FOUND[*]-} " in
	*" $dir "*) return 0 ;;
	esac
	PLUGIN_DIRS_FOUND+=("$dir")
	if [ -n "$server" ] && [ -x "$server" ]; then
		PLUGIN_FLAGS+=(-external-plugin-path "${dir}#${server}")
	else
		PLUGIN_FLAGS+=(-plugin-path "$dir")
	fi
}

# Every plugin layout under one Developer directory (Xcode.app or CommandLineTools).
scan_developer_root() {
	local dev="$1"
	[ -d "$dev" ] || return 0

	local platform="${dev}/Platforms/MacOSX.platform/Developer/usr"
	add_plugin_dir "${platform}/lib/swift/host/plugins" "${platform}/bin/swift-plugin-server"
	add_plugin_dir "${platform}/local/lib/swift/host/plugins" "${platform}/bin/swift-plugin-server"

	local toolchain="${dev}/Toolchains/XcodeDefault.xctoolchain/usr"
	add_plugin_dir "${toolchain}/lib/swift/host/plugins" "${toolchain}/bin/swift-plugin-server"
	add_plugin_dir "${toolchain}/local/lib/swift/host/plugins" "${toolchain}/bin/swift-plugin-server"

	add_plugin_dir "${dev}/usr/lib/swift/host/plugins" "${dev}/usr/bin/swift-plugin-server"
}

discover_plugins() {
	PLUGIN_FLAGS=()
	PLUGIN_DIRS_FOUND=()

	# An explicit override always wins.
	if [ -n "${CHARTDESK_PLUGIN_DIR:-}" ]; then
		add_plugin_dir "$CHARTDESK_PLUGIN_DIR" "${CHARTDESK_PLUGIN_SERVER:-}"
	fi

	local frontend toolchain_usr
	frontend="$(xcrun --find swift-frontend 2>/dev/null || true)"
	[ -n "$frontend" ] || frontend="$(xcrun --find swiftc 2>/dev/null || true)"
	if [ -n "$frontend" ]; then
		toolchain_usr="$(cd "$(dirname "$frontend")/.." && pwd)"
		add_plugin_dir "${toolchain_usr}/lib/swift/host/plugins" "${toolchain_usr}/bin/swift-plugin-server"
		add_plugin_dir "${toolchain_usr}/local/lib/swift/host/plugins" "${toolchain_usr}/bin/swift-plugin-server"
	fi

	scan_developer_root "$(xcode-select -p 2>/dev/null || true)"
	add_plugin_dir "${SDK_PATH}/usr/lib/swift/host/plugins" ""

	# Any Xcode sitting in /Applications, selected or not.
	local app
	for app in "${APPLICATIONS_DIR}"/Xcode*.app; do
		[ -d "$app" ] || continue
		scan_developer_root "${app}/Contents/Developer"
	done
}

swiftui_macro_present() {
	local dir
	for dir in ${PLUGIN_DIRS_FOUND[@]+"${PLUGIN_DIRS_FOUND[@]}"}; do
		if ls "$dir" 2>/dev/null | grep -qi 'swiftuimacros'; then
			return 0
		fi
	done
	return 1
}

installed_xcode() {
	local app
	for app in "${APPLICATIONS_DIR}"/Xcode*.app; do
		[ -d "$app" ] && { echo "$app"; return 0; }
	done
	return 1
}

find_macros_deep() {
	local root
	echo "Searching for SwiftUIMacros (this can take a minute)…"
	for root in "$APPLICATIONS_DIR" /Library/Developer "$HOME/Library/Developer"; do
		[ -d "$root" ] || continue
		find "$root" -maxdepth 12 -iname '*SwiftUIMacros*' -print 2>/dev/null || true
	done
	echo "Done. If nothing was listed, the plugin is not on this machine."
}

macro_help() {
	local xcode
	echo
	echo "SwiftUI's @State is a macro on this SDK, and its plugin (SwiftUIMacros)"
	echo "was not found. It ships inside Xcode, not the Command Line Tools."
	echo
	if xcode="$(installed_xcode)"; then
		echo "Xcode is already installed at:"
		echo "    ${xcode}"
		echo "Point the toolchain at it and build again:"
		echo "    sudo xcode-select -s ${xcode}/Contents/Developer"
	else
		echo "No Xcode found in ${APPLICATIONS_DIR}. Options:"
		echo "  1. Install Xcode from the App Store, then:"
		echo "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
		echo "  2. If the plugin lives somewhere unusual, find it with:"
		echo "       ./build.sh --find-macros"
		echo "     then point the build at it:"
		echo "       CHARTDESK_PLUGIN_DIR=/path/to/host/plugins ./build.sh"
	fi
	echo
	echo "  ./build.sh --force   compiles anyway, if you want to see the errors"
	echo
}

doctor() {
	echo "xcode-select -p : $(xcode-select -p 2>&1 || true)"
	echo "swiftc          : $(xcrun --find swiftc 2>&1 || true)"
	echo "swift version   : $(swift --version 2>&1 | head -1 || true)"
	echo "macOS SDK       : ${SDK_PATH:-unknown}"
	echo "SDK version     : $(xcrun --show-sdk-version --sdk macosx 2>&1 || true)"
	echo "arch            : $(uname -m)"
	echo "Xcode installed : $(installed_xcode || echo 'none found')"
	echo "macro plugins   :"
	local dir
	if [ "${#PLUGIN_DIRS_FOUND[@]}" -eq 0 ] 2>/dev/null; then
		echo "                  none found"
	else
		for dir in ${PLUGIN_DIRS_FOUND[@]+"${PLUGIN_DIRS_FOUND[@]}"}; do
			echo "                  ${dir}"
		done
	fi
	if swiftui_macro_present; then
		echo "SwiftUIMacros   : found"
	else
		echo "SwiftUIMacros   : NOT found — @State will fail to compile"
	fi
}

MODE="direct"
FORCE="no"
ACTION="${1:-}"
case "$ACTION" in
--spm) MODE="spm"; ACTION="${2:-}" ;;
--force) FORCE="yes"; ACTION="${2:-}" ;;
esac

# --- Toolchain -------------------------------------------------------------
if ! xcrun --find swiftc >/dev/null 2>&1; then
	echo "Swift compiler not found. Install Apple's command line tools:"
	echo "    xcode-select --install"
	exit 1
fi

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
if [ ! -d "$SDK_PATH" ]; then
	echo "No macOS SDK at ${SDK_PATH}."
	exit 1
fi

discover_plugins

if [ "$ACTION" = "--doctor" ] || [ "${1:-}" = "--doctor" ]; then
	doctor
	exit 0
fi

if [ "$ACTION" = "--find-macros" ] || [ "${1:-}" = "--find-macros" ]; then
	find_macros_deep
	exit 0
fi

mkdir -p build

if [ "$MODE" = "spm" ]; then
	step "Compiling through SwiftPM"
	if ! swift build -c release --build-system native 2>/dev/null; then
		warn "--build-system native unavailable, retrying plain"
		swift build -c release
	fi
	BINARY="$(swift build -c release --show-bin-path)/${APP_NAME}"
else
	step "Compiling with swiftc (${DEPLOYMENT_TARGET}+, $(uname -m))"

	COUNT="$(find Sources -name '*.swift' | wc -l | tr -d ' ')"
	if [ "$COUNT" -eq 0 ]; then
		echo "No Swift sources found under Sources/."
		exit 1
	fi
	echo "    ${COUNT} source files"

	if swiftui_macro_present; then
		echo "    ${#PLUGIN_DIRS_FOUND[@]} macro plugin path(s), SwiftUIMacros found"
	elif [ "$FORCE" = "yes" ]; then
		warn "SwiftUIMacros not found — compiling anyway because --force was given"
	else
		macro_help
		exit 1
	fi

	SOURCES=()
	while IFS= read -r -d '' FILE; do
		SOURCES+=("$FILE")
	done < <(find Sources -name '*.swift' -print0)

	BINARY="build/${APP_NAME}.bin"
	rm -f "$BINARY"
	# Extra frontend flags for a one-off investigation, e.g. finding what is slow to compile:
	#   CHARTDESK_SWIFT_FLAGS="-Xfrontend -warn-long-function-bodies=100" ./build.sh
	read -r -a EXTRA_FLAGS <<<"${CHARTDESK_SWIFT_FLAGS:-}"
	xcrun swiftc \
		-swift-version 5 \
		-parse-as-library \
		-O \
		${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
		-sdk "$SDK_PATH" \
		-target "$(uname -m)-apple-macos${DEPLOYMENT_TARGET}" \
		${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"} \
		-module-name "$APP_NAME" \
		-o "$BINARY" \
		"${SOURCES[@]}"
fi

if [ ! -x "$BINARY" ]; then
	echo "Build finished but ${BINARY} is missing."
	exit 1
fi

# --- Bundle ----------------------------------------------------------------
step "Assembling ${APP}"
rm -rf "$APP"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "$BINARY" "${CONTENTS}/MacOS/${APP_NAME}"
cp Resources/Info.plist "${CONTENTS}/Info.plist"
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# The runway table, which the wind panel needs to offer an airport's own runways.
if [ -f Resources/runways.txt ]; then
	cp Resources/runways.txt "${CONTENTS}/Resources/runways.txt"
else
	warn "Resources/runways.txt missing — runway menus will fall back to 01-36"
fi

# The map's geography, at each level of detail, plus airport and runway positions. The
# geography is one file per layer per tier: the map reads the tier its zoom calls for.
for TABLE in land-110 lakes-110 borders-110 \
             land-50 lakes-50 borders-50 \
             land-10 lakes-10 borders-10 \
             land-osm states cities \
             airports runway-ends; do
	if [ -f "Resources/${TABLE}.txt" ]; then
		cp "Resources/${TABLE}.txt" "${CONTENTS}/Resources/${TABLE}.txt"
	else
		warn "Resources/${TABLE}.txt missing — the map will be short of it"
	fi
done

if ! plutil -lint "${CONTENTS}/Info.plist" >/dev/null 2>&1; then
	warn "Info.plist failed plutil -lint"
fi

# --- Icon ------------------------------------------------------------------
if [ -f Resources/AppIcon.png ] && command -v iconutil >/dev/null 2>&1; then
	step "Building icon"
	ICON_TMP="$(mktemp -d)"
	ICONSET="${ICON_TMP}/AppIcon.iconset"
	mkdir -p "$ICONSET"
	for SIZE in 16 32 128 256 512; do
		sips -z "$SIZE" "$SIZE" Resources/AppIcon.png \
			--out "${ICONSET}/icon_${SIZE}x${SIZE}.png" >/dev/null
		sips -z "$((SIZE * 2))" "$((SIZE * 2))" Resources/AppIcon.png \
			--out "${ICONSET}/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
	done
	iconutil -c icns "$ICONSET" -o "${CONTENTS}/Resources/AppIcon.icns"
	rm -rf "$ICON_TMP"
else
	warn "No icon built (Resources/AppIcon.png or iconutil missing)"
fi

# --- Signature -------------------------------------------------------------
# Signed with a certificate when there is one to hand, ad-hoc when there is not.
#
# This matters more than it sounds. When macOS grants a permission -- reading ~/Downloads, in
# this app's case -- it ties the grant to the signature's *designated requirement*. Signed
# ad-hoc, that requirement is the build's own hash:
#
#     designated => cdhash H"ccb6080e..."
#
# so every build is a different app as far as the system is concerned, and a permission you
# granted is asked for again after each update. Signed with a certificate it is the bundle
# identifier and the certificate instead:
#
#     designated => identifier "local.chartdesk.app" and certificate root = H"bad019d0..."
#
# which is the same next build and the same next release, and the answer sticks.
#
# The certificate is self-signed and carries no trust -- Gatekeeper turns this app away either
# way, exactly as it does an ad-hoc one -- so it is not there to vouch for who built this. It
# is there to say that this is still the same app.
SIGN_IDENTITY="${CHARTDESK_SIGN_IDENTITY:-Chartdesk Signing}"
SIGN_KEYCHAIN="${CHARTDESK_SIGN_KEYCHAIN:-}"

SIGN_AS=(--sign -)
SIGN_LABEL="ad-hoc"
if security find-identity -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} 2>/dev/null \
	| grep -qF "$SIGN_IDENTITY"; then
	SIGN_AS=(--sign "$SIGN_IDENTITY")
	SIGN_LABEL="$SIGN_IDENTITY"
	if [ -n "$SIGN_KEYCHAIN" ]; then
		SIGN_AS+=(--keychain "$SIGN_KEYCHAIN")
	fi
fi

step "Signing (${SIGN_LABEL})"
# codesign refuses a bundle carrying Finder info or a resource fork, and iCloud Drive adds
# exactly that to anything under a synced Desktop or Documents folder -- including this one.
#
# `xattr -cr` is not enough on its own: it leaves com.apple.FinderInfo on the bundle directory
# itself, which is the attribute codesign actually trips over, and iCloud puts it back within
# moments of it being cleared. So the tree is cleaned once, and then the one directory that
# matters is cleared immediately before each attempt with nothing in between to lose the race
# to -- and there are several attempts, because occasionally iCloud still wins one.
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete 2>/dev/null || true

SIGNED=no
SIGN_ERROR=""
for ATTEMPT in 1 2 3 4 5; do
	xattr -c "$APP" 2>/dev/null || true
	if SIGN_ERROR="$(codesign --force "${SIGN_AS[@]}" "$APP" 2>&1)"; then
		SIGNED=yes
		break
	fi
done
if [ "$SIGNED" = no ]; then
	warn "Signing (${SIGN_LABEL}) failed; the app may be refused on Apple silicon."
	# And what codesign said about it. This used to go to /dev/null, which meant a release
	# went out signed ad-hoc and nothing anywhere said why.
	printf '%s\n' "$SIGN_ERROR" | sed 's/^/    /' >&2
fi

step "Built ${APP}"

case "$ACTION" in
--install)
	step "Installing to /Applications"
	rm -rf "/Applications/${APP_NAME}.app"
	cp -R "$APP" /Applications/
	# `cp` brings the Finder info iCloud stamped on the built bundle along with it, and
	# codesign --verify objects to it just as signing did. /Applications is not synced, so
	# cleared once here it stays cleared.
	xattr -c "/Applications/${APP_NAME}.app" 2>/dev/null || true
	open "/Applications/${APP_NAME}.app"
	;;
--run)
	open "$APP"
	;;
*)
	echo
	echo "    open ${APP}          launch it"
	echo "    ./build.sh --install       put it in /Applications"
	;;
esac
