#!/bin/sh
set -eu

PRODUCT="${PRODUCT:-container-compose}"
CONFIGURATION="${CONFIGURATION:-release}"
PREFIX="${PREFIX:-$HOME/.local}"
BUILD_PATH="${BUILD_PATH:-/private/tmp/container-compose-swift-build-install}"
BIN_DIR="$PREFIX/bin"

swift build \
  --configuration "$CONFIGURATION" \
  --product "$PRODUCT" \
  --build-path "$BUILD_PATH"

BUILD_PRODUCTS_DIR="$(swift build \
  --configuration "$CONFIGURATION" \
  --build-path "$BUILD_PATH" \
  --show-bin-path)"

SOURCE_BINARY="$BUILD_PRODUCTS_DIR/$PRODUCT"
TARGET_BINARY="$BIN_DIR/$PRODUCT"

if [ ! -x "$SOURCE_BINARY" ]; then
  echo "Built binary not found at $SOURCE_BINARY" >&2
  exit 1
fi

case "$TARGET_BINARY" in
  /usr/bin/*|/bin/*|/sbin/*|/usr/sbin/*)
    echo "Refusing to install into a system-protected directory: $TARGET_BINARY" >&2
    exit 1
    ;;
esac

if [ -e "$TARGET_BINARY" ] && [ "${FORCE:-0}" != "1" ]; then
  if ! cmp -s "$SOURCE_BINARY" "$TARGET_BINARY"; then
    echo "$TARGET_BINARY already exists and differs from the built binary." >&2
    echo "Set FORCE=1 to replace it." >&2
    exit 1
  fi
fi

if ! mkdir -p "$BIN_DIR"; then
  echo "Could not create $BIN_DIR. Choose a writable PREFIX or retry with appropriate privileges." >&2
  exit 1
fi

TEMP_BINARY="$(mktemp "$BIN_DIR/.container-compose.XXXXXX")"
cleanup() {
  rm -f "$TEMP_BINARY"
}
trap cleanup EXIT

cp "$SOURCE_BINARY" "$TEMP_BINARY"
chmod 0755 "$TEMP_BINARY"

if ! mv "$TEMP_BINARY" "$TARGET_BINARY"; then
  echo "Could not install $TARGET_BINARY. Choose a writable PREFIX or retry with appropriate privileges." >&2
  exit 1
fi
trap - EXIT

echo "Installed $PRODUCT to $TARGET_BINARY"
echo "Ensure $BIN_DIR is on PATH, then run '$PRODUCT --help'."
