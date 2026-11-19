#!/usr/bin/env bash
set -euo pipefail

# Install or uninstall Agent MCP on macOS
# Usage:
#   ./scripts/install_macos.sh                  # Install venv, CLI (~/.local/bin), and ~/Applications/Agent MCP.app
#   ./scripts/install_macos.sh --cli-only       # Server/CLI only (no GUI deps or .app bundle)
#   ./scripts/install_macos.sh --launchd        # Also install LaunchAgent for headless CLI auto-start
#   ./scripts/install_macos.sh --uninstall      # Remove symlinks, .app bundle, and LaunchAgent

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
[[ -x "$ROOT_DIR/venv/bin/python" ]] && VENV_DIR="$ROOT_DIR/venv"

BIN_DIR="$HOME/.local/bin"
APP_BUNDLE="$HOME/Applications/Agent MCP.app"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/io.github.iamr0s.agent-mcp.plist"

CLI_ONLY=0
ADD_LAUNCHD=0
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --cli-only)  CLI_ONLY=1 ;;
    --launchd)   ADD_LAUNCHD=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)
      sed -n '3,10p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ "$UNINSTALL" -eq 1 ]]; then
  echo "[Agent MCP] Uninstalling macOS launchers & LaunchAgent..."
  rm -f "$BIN_DIR/agent-mcp" "$BIN_DIR/agent-mcp-gui"
  rm -rf "$APP_BUNDLE"
  if [[ -f "$LAUNCH_PLIST" ]]; then
    launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
    rm -f "$LAUNCH_PLIST"
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

# 4. Generate ~/Applications/Agent MCP.app bundle (unless --cli-only)
if [[ "$CLI_ONLY" -eq 0 ]]; then
  mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
  cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Agent MCP</string>
  <key>CFBundleDisplayName</key>
  <string>Agent MCP</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.iamr0s.agent-mcp</string>
  <key>CFBundleVersion</key>
  <string>1.2.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>agent-mcp-launcher</string>
  <key>LSUIElement</key>
  <false/>
</dict>
</plist>
EOF

  cat > "$APP_BUNDLE/Contents/MacOS/agent-mcp-launcher" <<EOF
#!/usr/bin/env bash
cd "$ROOT_DIR"
exec "$VENV_DIR/bin/agent-mcp-gui"
EOF
  chmod +x "$APP_BUNDLE/Contents/MacOS/agent-mcp-launcher"
  echo "[Agent MCP] Created macOS app bundle: $APP_BUNDLE"
fi

# 5. Optional LaunchAgent for headless CLI auto-start
if [[ "$ADD_LAUNCHD" -eq 1 ]]; then
  mkdir -p "$(dirname "$LAUNCH_PLIST")" "$ROOT_DIR/logs"
  cat > "$LAUNCH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>io.github.iamr0s.agent-mcp</string>
  <key>WorkingDirectory</key>
  <string>$ROOT_DIR</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VENV_DIR/bin/agent-mcp</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$ROOT_DIR/logs/launchd.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$ROOT_DIR/logs/launchd.stderr.log</string>
</dict>
</plist>
EOF
  launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
  launchctl load "$LAUNCH_PLIST"
  echo "[Agent MCP] Loaded LaunchAgent: $LAUNCH_PLIST"
fi

echo ""
echo "[Agent MCP] Installation complete!"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "  Note: Add '$BIN_DIR' to your PATH in ~/.zshrc (export PATH=\"\$HOME/.local/bin:\$PATH\")."
fi
echo "  GUI : Open '~/Applications/Agent MCP.app' or run: agent-mcp gui"
echo "  CLI : agent-mcp setup  |  agent-mcp run  |  agent-mcp config"
