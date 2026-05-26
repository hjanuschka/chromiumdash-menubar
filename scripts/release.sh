#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 0.1.0" >&2
  exit 2
fi

VERSION="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/.build/Chromium Branches.app"
RELEASE_DIR="$ROOT/.build/releases"
ZIP_PATH="$RELEASE_DIR/ChromiumBranches-macOS-$VERSION.zip"
TAG="v$VERSION"
REPO="hjanuschka/chromiumdash-menubar"

cd "$ROOT"

./scripts/build-app.sh

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

shasum -a 256 "$ZIP_PATH" | tee "$ZIP_PATH.sha256"

cat <<EOF

Release artifact built:
  $ZIP_PATH
  $ZIP_PATH.sha256
EOF

if [[ "${SKIP_GH_RELEASE:-0}" == "1" ]]; then
  echo "SKIP_GH_RELEASE=1 set, not publishing to GitHub."
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is not installed. Artifact was built but not published." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

NOTES=$(cat <<EOF
ChromiumDash Menubar $VERSION

Tiny macOS menu bar app showing Chrome Stable/Beta/Dev/Canary milestones, branch countdowns, and ChromiumDash schedule dates.

Download the zip, unzip it, then open "Chromium Branches.app".
EOF
)

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG exists, uploading assets with --clobber."
  gh release upload "$TAG" "$ZIP_PATH" "$ZIP_PATH.sha256" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$ZIP_PATH" "$ZIP_PATH.sha256" \
    --repo "$REPO" \
    --title "ChromiumDash Menubar $VERSION" \
    --notes "$NOTES"
fi
