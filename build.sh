#!/usr/bin/env bash
set -euo pipefail

# --- CONFIGURATION ---
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRESET_FILE="$ROOT_DIR/build_presets.txt"
ODIN_SOURCE_FILE="$ROOT_DIR/configs.odin" # Path to the strings and enums in code

ANDROID_DIR="$ROOT_DIR/androidglue/apkbuild"
KEYSTORE=".keystore"
APK_OUT="$ROOT_DIR/OdinRenderer.apk"
HIDDEN_EXT=".buildtime-temp-hidden"

# --- HELPER: SCRAPE STRING VALUES FROM ODIN ARRAYS ---
echo "--- Build System Initialization ---"

get_odin_array_strings() {
    local array_name=$1
    if [ -f "$ODIN_SOURCE_FILE" ]; then
        sed -n "/$array_name ::/,/}/p" "$ODIN_SOURCE_FILE" | grep -o '"[^"]*"' | sed 's/"//g' | tr '\n' '|' | sed 's/|$//'
    else
        echo ""
    fi
}

VALID_TARGETS=$(get_odin_array_strings "Build_Targets")
VALID_VARIANTS=$(get_odin_array_strings "Build_Variants")

if [ -n "$VALID_TARGETS" ]; then
    echo "Detected Targets:  [$VALID_TARGETS]"
    echo "Detected Variants: [$VALID_VARIANTS]"
else
    echo "WARNING: Odin source not found. Manual validation fallback active."
    VALID_TARGETS="PC|MOBILE"
    VALID_VARIANTS="RELEASE|EDITOR|HEADLESS"
fi

if [ -f "$PRESET_FILE" ]; then
    echo "Available Presets:"
    grep -v "^#" "$PRESET_FILE" | awk -F':' '{print "  - " $1}' || echo "  (No presets defined)"
fi
echo "-----------------------------------"

# --- INITIALIZE VARIABLES ---
TARGET=""
VARIANT=""
VERBOSE=""
TRACKING=""
CUSTOM_FLAGS=""

# --- PARSE ARGUMENTS ---
for arg in "$@"; do
    case $arg in
        PRESET=*)
            PRESET_NAME="${arg#*=}"
            LINE=$(grep "^$PRESET_NAME:" "$PRESET_FILE" || true)
            if [ -n "$LINE" ]; then
                # build_presets.txt: NAME:TARGET:VARIANT:VERBOSE:TRACKING:CUSTOM_FLAGS
                IFS=':' read -r P_NAME TARGET VARIANT VERBOSE TRACKING CUSTOM_FLAGS <<< "$LINE"
            else
                echo "ERROR: Preset '$PRESET_NAME' not found in $PRESET_FILE"
                exit 1
            fi
            ;;
        TARGET=*)       TARGET="${arg#*=}" ;;
        VARIANT=*)      VARIANT="${arg#*=}" ;;
        VERBOSE=*)      VERBOSE="${arg#*=}" ;;
        TRACKING=*)     TRACKING="${arg#*=}" ;;
        ODIN_FLAGS=*)   CUSTOM_FLAGS="${arg#*=}" ;;
    esac
done

# --- STRICT VALIDATION ---
MISSING=""
[ -z "$TARGET" ]   && MISSING+=" TARGET"
[ -z "$VARIANT" ]  && MISSING+=" VARIANT"
[ -z "$VERBOSE" ]  && MISSING+=" VERBOSE"
[ -z "$TRACKING" ] && MISSING+=" TRACKING"

if [ -n "$MISSING" ]; then
    echo -e "\nERROR: Incomplete configuration."
    echo "Usage (Preset): $0 PRESET=[Name]"
    echo "Usage (Manual): $0 TARGET=[$VALID_TARGETS] VARIANT=[$VALID_VARIANTS] VERBOSE=[true|false] TRACKING=[true|false] ODIN_FLAGS=\"...\""
    echo -e "\nMissing requirements:$MISSING"
    exit 1
fi

# --- CLEANUP TRAP ---
cleanup() {
    echo -e "\n--- Restoring hidden Odin files ---"
    find "$ROOT_DIR" -maxdepth 3 -name "*${HIDDEN_EXT}" -type f -exec sh -c 'mv "$1" "${1%.*}"' _ {} \;
}
trap cleanup EXIT

# --- FILE HIDING LOGIC ---
if [ "$TARGET" = "MOBILE" ]; then
    echo "--- Target is MOBILE: Hiding desktop files ---"
    find "$ROOT_DIR" -maxdepth 2 -name "*_desktop.odin" -type f -exec mv {} {}${HIDDEN_EXT} \;
else
    echo "--- Target is PC: Hiding android files ---"
    find "$ROOT_DIR" -maxdepth 2 -name "*_android.odin" -type f -exec mv {} {}${HIDDEN_EXT} \;
fi

# --- BUILD EXECUTION ---
echo -e "\n||| BUILDING: $TARGET | $VARIANT | FLAGS: $CUSTOM_FLAGS |||\n"

# shellcheck disable=SC2206
FINAL_FLAGS=(
    "-define:BUILD_TARGET=$TARGET"
    "-define:BUILD_VARIANT=$VARIANT"
    "-define:VERBOSE_LOGGING=$VERBOSE"
    "-define:TRACKING_ALLOCATOR=$TRACKING"
    $CUSTOM_FLAGS
)

if [ "$TARGET" = "MOBILE" ]; then
    cd "$ANDROID_DIR"
    if ! keytool -list -keystore "$KEYSTORE" -storepass android -alias androiddebugkey >/dev/null 2>&1; then
        keytool -genkey -dname "CN=Android Debug, O=Android, C=US" -keystore "$KEYSTORE" \
            -alias androiddebugkey -storepass android -keypass android -keyalg RSA -validity 30000
    fi

    cd "$ROOT_DIR"
    odin build . "${FINAL_FLAGS[@]}" -target:linux_arm64 -subtarget:android -build-mode:shared -extra-linker-flags="-lvulkan"

    LIB_NAME="$(basename "$ROOT_DIR")"
    mkdir -p "$ANDROID_DIR/android/lib/lib/arm64-v8a"
    mv "$ROOT_DIR/$LIB_NAME.so" "$ANDROID_DIR/android/lib/lib/arm64-v8a/libmain.so"

    cd "$ANDROID_DIR"
    odin bundle android android -android-keystore:"$KEYSTORE" -android-keystore-password:"android"
    cp "$(ls *.apk | head -n1)" "$APK_OUT"
    echo "APK Success: $APK_OUT"
else
    cd "$ROOT_DIR"
    odin build . "${FINAL_FLAGS[@]}"
    echo "Desktop Success!"
fi
