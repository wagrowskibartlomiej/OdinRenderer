#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_DIR="$ROOT_DIR/androidglue/apkbuild"
KEYSTORE=".keystore"
APK_OUT="$ROOT_DIR/OdinRenderer.apk"

cd "$ANDROID_DIR"

if ! keytool -list \
    -keystore "$KEYSTORE" \
    -storepass android \
    -alias androiddebugkey >/dev/null 2>&1; then

  keytool -genkey \
    -dname "CN=Android Debug, O=Android, C=US" \
    -keystore "$KEYSTORE" \
    -alias androiddebugkey \
    -storepass android \
    -keypass android \
    -keyalg RSA \
    -validity 30000
fi

echo "Building Odin shared library"

cd "$ROOT_DIR"

odin build . \
  -define:DESKTOP_BUILD=false \
  -define:VERBOSE_LOG=false \
  -o:aggressive \
  -target:linux_arm64 \
  -subtarget:android \
  -build-mode:shared \
  -show-system-calls \
  -extra-linker-flags="-lvulkan"


name="$(basename "$ROOT_DIR")"

mkdir -p "$ANDROID_DIR/android/lib/lib/arm64-v8a"
mv "$ROOT_DIR/$name.so" \
   "$ANDROID_DIR/android/lib/lib/arm64-v8a/libmain.so"

echo "Bundling APK"

cd "$ANDROID_DIR"

odin bundle android android \
  -android-keystore:"$KEYSTORE" \
  -android-keystore-password:"android"

APK_BUILT="$(ls *.apk | head -n1)"
cp "$APK_BUILT" "$APK_OUT"

echo "APK ready: $APK_OUT"


