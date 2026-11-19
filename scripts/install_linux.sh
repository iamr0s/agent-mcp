#!/usr/bin/env bash
set -euo pipefail

# Install or uninstall Agent MCP on Linux
# Usage:
#   ./scripts/install_linux.sh                  # Install venv, CLI (~/.local/bin), and .desktop launcher
#   ./scripts/install_linux.sh --cli-only       # Server/CLI only (no GUI deps or .desktop entry)
#   ./scripts/install_linux.sh --desktop        # Also create ~/Desktop/agent-mcp.desktop
#   ./scripts/install_linux.sh --systemd        # Also install & enable systemd --user background service
#   ./scripts/install_linux.sh --uninstall      # Remove symlinks, .desktop files, and systemd unit

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
[[ -x "$ROOT_DIR/venv/bin/python" ]] && VENV_DIR="$ROOT_DIR/venv"

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_DIR="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

CLI_ONLY=0
ADD_DESKTOP=0
ADD_SYSTEMD=0
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --cli-only)  CLI_ONLY=1 ;;
    --desktop)   ADD_DESKTOP=1 ;;
    --systemd)   ADD_SYSTEMD=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)
      sed -n '3,11p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ "$UNINSTALL" -eq 1 ]]; then
  echo "[Agent MCP] Uninstalling launchers & services..."
  rm -f "$BIN_DIR/agent-mcp" "$BIN_DIR/agent-mcp-gui"
  rm -f "$APPS_DIR/agent-mcp.desktop" "$DESKTOP_DIR/agent-mcp.desktop"
  if [[ -f "$SYSTEMD_DIR/agent-mcp.service" ]]; then
    systemctl --user disable --now agent-mcp.service 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/agent-mcp.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  echo "[Agent MCP] Done. Project directory '$ROOT_DIR' was kept intact."
  exit 0
fi

# 1. Create venv if needed
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  echo "[Agent MCP] Creating virtual environment at $VENV_DIR ..."
  python3 -m venv "$VENV_DIR"
fi

# 2. Install package
EXTRA=""
[[ "$CLI_ONLY" -eq 0 ]] && EXTRA="[full]"
echo "[Agent MCP] Installing agent-mcp$EXTRA ..."
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -e "${ROOT_DIR}${EXTRA}"

# 3. Symlink CLI binaries into ~/.local/bin
mkdir -p "$BIN_DIR"
ln -sf "$VENV_DIR/bin/agent-mcp" "$BIN_DIR/agent-mcp"
ln -sf "$VENV_DIR/bin/agent-mcp-gui" "$BIN_DIR/agent-mcp-gui"
echo "[Agent MCP] Linked CLI commands into $BIN_DIR"

# 4. Create XDG .desktop entry (unless --cli-only)
if [[ "$CLI_ONLY" -eq 0 ]]; then
  mkdir -p "$APPS_DIR"
  ICON_PATH="$ROOT_DIR/agent_mcp/assets/app_icon.ico"
  DESKTOP_FILE="$APPS_DIR/agent-mcp.desktop"
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Agent MCP
Comment=Cross-platform Local Agent MCP Server & Desktop Console
Exec=$VENV_DIR/bin/agent-mcp-gui
Path=$ROOT_DIR
Icon=$ICON_PATH
Terminal=false
Categories=Development;Utility;Network;
StartupNotify=true
EOF
  chmod +x "$DESKTOP_FILE"
  echo "[Agent MCP] Created application entry: $DESKTOP_FILE"

  if [[ "$ADD_DESKTOP" -eq 1 && -d "$DESKTOP_DIR" ]]; then
    cp "$DESKTOP_FILE" "$DESKTOP_DIR/agent-mcp.desktop"
    chmod +x "$DESKTOP_DIR/agent-mcp.desktop"
    echo "[Agent MCP] Created Desktop shortcut: $DESKTOP_DIR/agent-mcp.desktop"
  fi
fi

# 5. Optional systemd --user service for headless / always-on CLI server
if [[ "$ADD_SYSTEMD" -eq 1 ]]; then
  mkdir -p "$SYSTEMD_DIR"
  UNIT_FILE="$SYSTEMD_DIR/agent-mcp.service"
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Agent MCP Local Server
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT_DIR
ExecStart=$VENV_DIR/bin/agent-mcp run
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now agent-mcp.service
  echo "[Agent MCP] Enabled systemd user service: agent-mcp.service"
fi

echo ""
echo "[Agent MCP] Installation complete!"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "  Note: Add '$BIN_DIR' to your PATH (e.g. export PATH=\"\$HOME/.local/bin:\$PATH\")."
fi
echo "  GUI : agent-mcp gui  (or launch 'Agent MCP' from your application menu)"
echo "  CLI : agent-mcp setup  |  agent-mcp run  |  agent-mcp config"
