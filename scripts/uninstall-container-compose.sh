#!/bin/sh
set -eu

PRODUCT="${PRODUCT:-container-compose}"
PREFIX="${PREFIX:-$HOME/.local}"
TARGET_BINARY="$PREFIX/bin/$PRODUCT"

case "$TARGET_BINARY" in
  /usr/bin/*|/bin/*|/sbin/*|/usr/sbin/*)
    echo "Refusing to remove from a system-protected directory: $TARGET_BINARY" >&2
    exit 1
    ;;
esac

if [ ! -e "$TARGET_BINARY" ]; then
  echo "$TARGET_BINARY is not installed."
  exit 0
fi

if ! rm -f "$TARGET_BINARY"; then
  echo "Could not remove $TARGET_BINARY. Choose the correct PREFIX or retry with appropriate privileges." >&2
  exit 1
fi

echo "Removed $TARGET_BINARY"
