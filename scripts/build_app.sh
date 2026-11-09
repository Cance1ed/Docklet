#!/usr/bin/env bash
# Builds Docklet.app from the SwiftPM target. Works with Command Line Tools only (no Xcode required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
# Keep the build database off iCloud/OneDrive-synced folders: SQLite fails there.
SCRATCH="${SCRATCH:-$HOME/Library/Caches/DockletBuild}"
APP_DIR="$ROOT/build/Docklet.app"

echo "▸ Building ($CONFIG)…"
swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c "$CONFIG"

BIN="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c "$CONFIG" --show-bin-path)/Docklet"
[ -x "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

echo "▸ Assembling app bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/Docklet"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi

# A stable signing identity keeps the Accessibility grant alive across rebuilds;
# ad-hoc signatures change their cdhash every build and silently revoke it.
IDENTITY="${DOCKLET_SIGN_IDENTITY:-Docklet Self Signed}"
if security find-certificate -c "${IDENTITY}" >/dev/null 2>&1; then
  echo "▸ Signing with '${IDENTITY}'…"
  codesign --force --deep --options runtime --sign "${IDENTITY}" "$APP_DIR"
else
  echo "▸ Signing (ad-hoc)…"
  echo "  提示：运行 ./scripts/create_signing_identity.sh 可避免每次重建都要重新授权辅助功能。"
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "✓ Built $APP_DIR"

if [ "${INSTALL:-0}" = "1" ]; then
  echo "▸ Installing to /Applications…"
  RUNNING_PID="$(pgrep -f '/Applications/Docklet.app/Contents/MacOS/Docklet' || true)"
  [ -n "$RUNNING_PID" ] && kill "$RUNNING_PID" && sleep 1
  rm -rf /Applications/Docklet.app
  cp -R "$APP_DIR" /Applications/
  echo "✓ Installed /Applications/Docklet.app"
  echo "  启动： open /Applications/Docklet.app"
else
  echo "  运行： open \"$APP_DIR\""
  echo "  安装： INSTALL=1 ./scripts/build_app.sh"
fi
