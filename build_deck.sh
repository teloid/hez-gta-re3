#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="${BUILD_DIR:-build}"
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
VENV_DIR="${VENV_DIR:-.venv-deck-build}"
CHECK_ONLY=0

if [[ "${1:-}" == "--check-only" ]]; then
	CHECK_ONLY=1
fi

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "error: required command '$1' is missing"
		exit 1
	fi
}

echo "[1/7] Checking prerequisites..."
require_cmd git
require_cmd python3
require_cmd c++
require_cmd pkg-config
PKG_CONFIG_BIN="/usr/bin/pkg-config"
if [[ ! -x "$PKG_CONFIG_BIN" ]]; then
	PKG_CONFIG_BIN="$(command -v pkg-config)"
fi

# Steam Deck builds are native Linux builds; user shell/toolchain overrides can
# hide system pkg-config files like /usr/lib/pkgconfig/gl.pc.
unset PKG_CONFIG_SYSROOT_DIR
unset PKG_CONFIG_DIR
export PKG_CONFIG_LIBDIR="/usr/lib/pkgconfig:/usr/share/pkgconfig"
export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/share/pkgconfig"

declare -a REQUIRED_PC_MODULES=(
	gl
	x11
	x11-xcb
	fontenc
	ice
	sm
	xau
	xaw7
	xcomposite
	xcursor
	xdamage
	xdmcp
	xext
	xfixes
	xi
	xinerama
	xkbfile
	xmu
	xmuu
	xpm
	xrandr
	xrender
	xres
	xscrnsaver
	xt
	xtst
	xv
	xxf86vm
	xcb-xkb
	xcb-icccm
	xcb-image
	xcb-keysyms
	xcb-randr
	xcb-render
	xcb-renderutil
	xcb-shape
	xcb-shm
	xcb-sync
	xcb-xfixes
	xcb-xinerama
	xcb
	xcb-atom
	xcb-aux
	xcb-event
	xcb-util
	xcb-dri3
	xcb-cursor
	xcb-dri2
	xcb-glx
	xcb-present
	xcb-composite
	xcb-ewmh
	xcb-res
	uuid
)
declare -a MISSING_PC_MODULES=()
for module in "${REQUIRED_PC_MODULES[@]}"; do
	# Match Conan xorg/system probing behavior to catch transitive failures.
	if ! "$PKG_CONFIG_BIN" --print-errors --cflags-only-other "$module" >/dev/null 2>&1; then
		MISSING_PC_MODULES+=("$module")
	fi
done

if (( ${#MISSING_PC_MODULES[@]} > 0 )); then
	echo "error: pkg-config is missing required module(s): ${MISSING_PC_MODULES[*]}"
	echo "pkg-config binary: $PKG_CONFIG_BIN"
	echo "pkg-config default pc_path: $("$PKG_CONFIG_BIN" --variable pc_path pkg-config 2>/dev/null || echo '<unknown>')"
	echo "PKG_CONFIG_LIBDIR: ${PKG_CONFIG_LIBDIR:-<unset>}"
	echo "PKG_CONFIG_PATH: ${PKG_CONFIG_PATH:-<unset>}"
	echo "pkg-config detailed errors:"
	for module in "${MISSING_PC_MODULES[@]}"; do
		echo "  [$module]"
		"$PKG_CONFIG_BIN" --print-errors --cflags-only-other "$module" || true
	done
	if [[ -f /usr/lib/pkgconfig/gl.pc ]]; then
		echo "gl.pc exists at /usr/lib/pkgconfig/gl.pc"
	fi
	if [[ -f /usr/lib/pkgconfig/x11.pc ]]; then
		echo "x11.pc exists at /usr/lib/pkgconfig/x11.pc"
	else
		echo "x11.pc is missing on disk at /usr/lib/pkgconfig/x11.pc"
		echo "Tip: pacman package DB may be out of sync with filesystem."
		echo "Run integrity check and force reinstall WITHOUT --needed."
		echo "  sudo pacman -Qkk libx11 libxcb libxau libxdmcp libxext libxrandr libxi libxcursor libxinerama libxxf86vm libfontenc libice libsm libxaw libxcomposite libxdamage libxfixes libxkbfile libxmu libxpm libxrender libxres libxss libxt libxtst libxv xcb-util xcb-util-cursor xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm util-linux-libs"
		echo "  sudo pacman -S --overwrite '*' pkgconf libglvnd mesa libx11 libxcb libxau libxdmcp libxext libxrandr libxi libxcursor libxinerama libxxf86vm libfontenc libice libsm libxaw libxcomposite libxdamage libxfixes libxkbfile libxmu libxpm libxrender libxres libxss libxt libxtst libxv xcb-util xcb-util-cursor xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm util-linux-libs xorgproto xtrans"
	fi
	echo "Install Linux/OpenGL/X11/XCB development packages and retry:"
	echo "  sudo pacman -Syu --needed pkgconf libglvnd mesa libx11 libxcb libxau libxdmcp libxext libxrandr libxi libxcursor libxinerama libxxf86vm libfontenc libice libsm libxaw libxcomposite libxdamage libxfixes libxkbfile libxmu libxpm libxrender libxres libxss libxt libxtst libxv xcb-util xcb-util-cursor xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm util-linux-libs xorgproto xtrans"
	exit 1
fi

if (( CHECK_ONLY == 1 )); then
	echo "Dependency check complete: all required pkg-config modules are present."
	exit 0
fi

echo "[2/7] Updating submodules..."
git submodule update --init --recursive
if [[ ! -f vendor/librw/CMakeLists.txt ]]; then
	echo "error: vendor/librw is missing (submodule init failed)"
	exit 1
fi

echo "[3/7] Preparing Conan v1 in virtualenv..."
python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"
python3 -m pip install --upgrade pip
python3 -m pip install "conan<2"

if ! conan --version | grep -qE "^Conan version 1\\."; then
	echo "error: this project expects Conan 1.x"
	exit 1
fi

echo "[4/7] Verifying debug menu config..."
TMP_MACROS_FILE="$(mktemp)"
TMP_CHECK_CPP="$(mktemp)"
cat > "$TMP_CHECK_CPP" <<'EOF'
#include "src/core/config.h"
EOF
c++ -dM -E -x c++ -I. "$TMP_CHECK_CPP" > "$TMP_MACROS_FILE"
rm -f "$TMP_CHECK_CPP"

if grep -q "^#define MASTER" "$TMP_MACROS_FILE"; then
	echo "error: MASTER is enabled; debug menu would be disabled"
	rm -f "$TMP_MACROS_FILE"
	exit 1
fi

if ! grep -q "^#define DEBUGMENU" "$TMP_MACROS_FILE"; then
	echo "error: DEBUGMENU is not enabled by current preprocessor config"
	rm -f "$TMP_MACROS_FILE"
	exit 1
fi
rm -f "$TMP_MACROS_FILE"

if [[ ! -f "$HOME/.conan/profiles/default" ]]; then
	conan profile new default --detect
fi

if ! conan remote list | grep -q "^conancenter:"; then
	conan remote add conancenter https://center.conan.io
fi

echo "[5/7] Exporting librw recipe..."
conan export vendor/librw librw/master@

echo "[6/7] Installing dependencies..."
mkdir -p "$BUILD_DIR"
conan install . re3/master@ \
	-if "$BUILD_DIR" \
	-o re3:audio=openal \
	-o librw:platform=gl3 \
	-o librw:gl3_gfxlib=glfw \
	--build missing \
	-s re3:build_type="$BUILD_TYPE" \
	-s librw:build_type="$BUILD_TYPE"

echo "[7/7] Building..."
conan build . -if "$BUILD_DIR" -bf "$BUILD_DIR" -pf package

echo
echo "Build complete."
echo "Build type: $BUILD_TYPE"
echo "Build folder: $BUILD_DIR"
echo "Debug menu check: PASS (DEBUGMENU enabled, MASTER disabled)"
