#!/usr/bin/env sh
set -e

HIDDEN_EXT=".buildtime-temp-hidden"

cleanup() {
    echo "--- Restoring files names *_android.odin ---"
    for f in *${HIDDEN_EXT}; do
        if [ -e "$f" ]; then
            mv "$f" "${f%$HIDDEN_EXT}"
            echo "Restored: ${f%$HIDDEN_EXT}"
        fi
    done
    echo "--------------------------------------------"
}

trap cleanup EXIT

echo "--- Hiding files names *_android.odin before calling odin build ---"
for f in *_android.odin; do
    if [ -e "$f" ]; then
        mv "$f" "${f}${HIDDEN_EXT}"
        echo "Hidden: ${f}${HIDDEN_EXT}"
    fi
done
echo "-------------------------------------------------------------------"

echo ""
echo "||| BUILDING |||"
echo ""
odin build . \
  -define:BUILD_TARGET=PC \
  -define:BUILD_VARIANT=RELEASE \
  -o:aggressive
