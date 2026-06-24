#!/bin/sh
# remux installer — downloads the latest release and installs remux.app.
#   curl -fsSL https://raw.githubusercontent.com/mylesndavid/remux/main/install.sh | bash
set -e

REPO="mylesndavid/remux"
APP="remux.app"
ASSET="remux-macos.zip"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

if [ "$(uname)" != "Darwin" ]; then
  echo "remux is macOS only." >&2
  exit 1
fi

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading remux…"
curl -fsSL "$URL" -o "$TMP/${ASSET}"

echo "Installing to ${DEST}/${APP}…"
ditto -x -k "$TMP/${ASSET}" "$TMP/extracted"
SRC="$(/usr/bin/find "$TMP/extracted" -maxdepth 2 -name "$APP" -type d | head -1)"
[ -n "$SRC" ] || { echo "Couldn't find $APP in the downloaded archive." >&2; exit 1; }

rm -rf "${DEST:?}/${APP}"
cp -R "$SRC" "${DEST}/${APP}"
# Unsigned/unnotarized build: clear quarantine so Gatekeeper doesn't block it.
xattr -dr com.apple.quarantine "${DEST}/${APP}" 2>/dev/null || true

echo "✓ Installed ${DEST}/${APP}"
open "${DEST}/${APP}" 2>/dev/null || true
