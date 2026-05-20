#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="${BUILD_DIR:-build}"
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
VENV_DIR="${VENV_DIR:-.venv-deck-build}"

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
export PKG_CONFIG_LIBDIR="/usr/lib/pkgconfig:/usr/share/pkgconfig"
export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/share/pkgconfig"

if ! "$PKG_CONFIG_BIN" --exists gl; then
	echo "error: pkg-config cannot find 'gl' (gl.pc)."
	echo "pkg-config binary: $PKG_CONFIG_BIN"
	echo "pkg-config default pc_path: $("$PKG_CONFIG_BIN" --variable pc_path pkg-config 2>/dev/null || echo '<unknown>')"
	echo "PKG_CONFIG_LIBDIR: ${PKG_CONFIG_LIBDIR:-<unset>}"
	echo "PKG_CONFIG_PATH: ${PKG_CONFIG_PATH:-<unset>}"
	if [[ -f /usr/lib/pkgconfig/gl.pc ]]; then
		echo "gl.pc exists at /usr/lib/pkgconfig/gl.pc"
	fi
	echo "Install OpenGL development packages and retry:"
	echo "  sudo pacman -Syu --needed libglvnd mesa pkgconf"
	exit 1
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
