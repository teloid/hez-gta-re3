#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "Usage: $0 <steam-gta3-dir> [re3-binary-path]"
	echo "Example: $0 \"$HOME/.local/share/Steam/steamapps/common/Grand Theft Auto 3\" ./build/bin/linux-amd64-librw_gl3_glfw-oal/RelWithDebInfo/re3"
	exit 1
fi

GAME_DIR="$1"
BINARY_PATH="${2:-./build/bin/linux-amd64-librw_gl3_glfw-oal/RelWithDebInfo/re3}"

if [[ ! -d "$GAME_DIR" ]]; then
	echo "error: game directory does not exist: $GAME_DIR"
	exit 1
fi
GAME_DIR="$(cd "$GAME_DIR" && pwd)"

if [[ ! -f "$BINARY_PATH" ]]; then
	echo "error: re3 binary not found at: $BINARY_PATH"
	exit 1
fi

if [[ ! -f "$GAME_DIR/DATA/GTA3.DAT" && ! -f "$GAME_DIR/data/gta3.dat" ]]; then
	echo "warning: GTA III data not detected in: $GAME_DIR"
fi

install -m 0755 "$BINARY_PATH" "$GAME_DIR/re3"

cat > "$GAME_DIR/gta3.exe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
# Ignore Steam/Proton passthrough args and run native binary directly.
exec ./re3
EOF
chmod +x "$GAME_DIR/gta3.exe"

cat > "$GAME_DIR/run_re3_steam.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
unset LD_PRELOAD
# Ignore Steam's %command% passthrough args.
exec ./re3
EOF
chmod +x "$GAME_DIR/run_re3_steam.sh"

cat <<EOF
Installed:
  $GAME_DIR/re3
  $GAME_DIR/gta3.exe         (native wrapper, for manual launches)
  $GAME_DIR/run_re3_steam.sh (Steam launch wrapper)

Steam setup (recommended):
  1) GTA III -> Properties -> Compatibility -> disable forced Proton.
  2) GTA III -> Properties -> General -> Launch Options:
     "$GAME_DIR/run_re3_steam.sh" %command%

If Steam still fails to launch, try adding it as a Non-Steam game:
  $GAME_DIR/run_re3_steam.sh
EOF
