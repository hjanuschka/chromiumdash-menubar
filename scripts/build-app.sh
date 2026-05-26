#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP_NAME="Chromium Branches.app"
APP_DIR="$ROOT/.build/$APP_NAME"
BIN="$ROOT/.build/$CONFIG/ChromiumBranches"

cd "$ROOT"
swift build -c "$CONFIG"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/ChromiumBranches"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

cat > "$APP_DIR/Contents/PkgInfo" <<'EOF'
APPL????
EOF

printf 'Built: %s\n' "$APP_DIR"
printf 'Run:   open %q\n' "$APP_DIR"
