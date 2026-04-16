#!/usr/bin/env bash
set -euo pipefail

# --- CONFIGURATION ---
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRESET_FILE="$ROOT_DIR/build_presets.txt"
ODIN_SOURCE_FILE="$ROOT_DIR/configs.odin" 

ANDROID_DIR="$ROOT_DIR/androidglue/apkbuild"
MANIFEST_PATH="$ANDROID_DIR/android/AndroidManifest.xml"
KEYSTORE=".keystore"
APK_OUT="$ROOT_DIR/OdinRenderer.apk"
HIDDEN_EXT=".buildtime-temp-hidden"

# Assets configuration
ASSETS_SRC="$ROOT_DIR/assets.packed"
ANDROID_ASSETS_DIR="$ANDROID_DIR/android/assets"

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
    grep -v "^#" "$PRESET_FILE" | awk -F':' '{print "  - " $1}' | sed 's/[[:space:]]*$//' || echo "  (No presets defined)"
fi
echo "-----------------------------------"

# --- INITIALIZE VARIABLES ---
TARGET=""
VARIANT=""
VERBOSE=""
TRACKING=""
CUSTOM_FLAGS=""
APK_DEBUG=""

# --- PARSE ARGUMENTS ---
# 1. Catch APK-DEBUG from command line (priority)
for arg in "$@"; do
    [[ $arg == APK-DEBUG=* ]] && APK_DEBUG="${arg#*=}"
done

# 2. Parse PRESET or manual arguments
for arg in "$@"; do
    case $arg in
        PRESET=*)
            PRESET_NAME="${arg#*=}"
            # Clean spaces around colons for the parser
            LINE=$(grep "^[[:space:]]*$PRESET_NAME[[:space:]]*:" "$PRESET_FILE" | sed 's/[[:space:]]*:[[:space:]]*/:/g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
            
            if [ -n "$LINE" ]; then
                # Fields: 1:NAME 2:TARGET 3:VARIANT 4:VERBOSE 5:TRACKING 6:APK_DEBUG 7:FLAGS
                TARGET=$(echo "$LINE" | cut -d':' -f2)
                VARIANT=$(echo "$LINE" | cut -d':' -f3)
                VERBOSE=$(echo "$LINE" | cut -d':' -f4)
                TRACKING=$(echo "$LINE" | cut -d':' -f5)
                P_APK_DEBUG=$(echo "$LINE" | cut -d':' -f6)
                P_FLAGS=$(echo "$LINE" | cut -d':' -f7-)
                
                CUSTOM_FLAGS=$P_FLAGS
                [ -z "$APK_DEBUG" ] && APK_DEBUG=$P_APK_DEBUG
            else
                echo "ERROR: Preset '$PRESET_NAME' not found in $PRESET_FILE"
                exit 1
            fi
            ;;
        TARGET=*)   TARGET="${arg#*=}" ;;
        VARIANT=*)  VARIANT="${arg#*=}" ;;
        VERBOSE=*)  VERBOSE="${arg#*=}" ;;
        TRACKING=*) TRACKING="${arg#*=}" ;;
        ODIN_FLAGS=*) CUSTOM_FLAGS="${arg#*=}" ;;
    esac
done

# Default values
APK_DEBUG="${APK_DEBUG:-false}"

# --- STRICT VALIDATION ---
MISSING=""
[ -z "$TARGET" ]   && MISSING+=" TARGET"
[ -z "$VARIANT" ]  && MISSING+=" VARIANT"
[ -z "$VERBOSE" ]  && MISSING+=" VERBOSE"
[ -z "$TRACKING" ] && MISSING+=" TRACKING"

if [ -n "$MISSING" ]; then
    echo -e "\nERROR: Incomplete configuration."
    echo "Usage (Preset): $0 PRESET=[Name] (optional: APK-DEBUG=true)"
    echo "Usage (Manual): $0 TARGET=[$VALID_TARGETS] VARIANT=[$VALID_VARIANTS] VERBOSE=[true|false] TRACKING=[true|false] ODIN_FLAGS=\"...\""
    echo -e "\nMissing requirements:$MISSING"
    exit 1
fi

if [ "$TARGET" = "PC" ] && [ "$APK_DEBUG" = "true" ]; then
    echo "ERROR: APK-DEBUG=true is invalid for PC builds."
    exit 1
fi

# --- CLEANUP TRAP ---
cleanup() {
    echo -e "\n--- Restoring environment ---"
    find "$ROOT_DIR" -maxdepth 3 -name "*${HIDDEN_EXT}" -type f -exec sh -c 'mv "$1" "${1%.*}"' _ {} \;
    
    if [ "$TARGET" = "MOBILE" ] && [ -f "$MANIFEST_PATH" ]; then
        sed -i 's/android:debuggable="true"/android:debuggable="false"/g' "$MANIFEST_PATH"
        echo "AndroidManifest.xml: reset debuggable to false"
    fi
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

# --- BUILD INFO DISPLAY ---
echo -e "\nBUILD OPTIONS:"
echo "  TARGET       : $TARGET"
echo "  VARIANT      : $VARIANT"
echo "  VERBOSE      : $VERBOSE"
echo "  TRACKING     : $TRACKING"
[ "$TARGET" = "MOBILE" ] && echo "  APK-DEBUG    : $APK_DEBUG"
echo "  CUSTOM FLAGS : $CUSTOM_FLAGS"
echo -e "----------------------------\n"

# --- BUILD EXECUTION ---
# shellcheck disable=SC2206
FINAL_FLAGS=(
    "-define:BUILD_TARGET=$TARGET"
    "-define:BUILD_VARIANT=$VARIANT"
    "-define:VERBOSE_LOGGING=$VERBOSE"
    "-define:TRACKING_ALLOCATOR=$TRACKING"
    $CUSTOM_FLAGS
)

if [ "$TARGET" = "MOBILE" ]; then
    # 1. Patch AndroidManifest.xml
    if [ -f "$MANIFEST_PATH" ]; then
        echo "Updating manifest: debuggable=$APK_DEBUG"
        sed -i "s/android:debuggable=\"[^\"]*\"/android:debuggable=\"$APK_DEBUG\"/g" "$MANIFEST_PATH"
    fi

    # 2. Keystore Check/Generation
    cd "$ANDROID_DIR"
    if ! keytool -list -keystore "$KEYSTORE" -storepass android -alias androiddebugkey >/dev/null 2>&1; then
        echo "Keystore not found. Generating debug keystore..."
        keytool -genkey -dname "CN=Android Debug, O=Android, C=US" -keystore "$KEYSTORE" \
            -alias androiddebugkey -storepass android -keypass android -keyalg RSA -validity 30000
    fi

    # 3. Compile Odin code to Shared Library (.so)
    cd "$ROOT_DIR"
    odin build . "${FINAL_FLAGS[@]}" -target:linux_arm64 -subtarget:android -build-mode:shared -extra-linker-flags="-lvulkan"

    # 4. Setup Android Directory Structure
    LIB_NAME="$(basename "$ROOT_DIR")"
    mkdir -p "$ANDROID_DIR/android/lib/lib/arm64-v8a"
    mv "$ROOT_DIR/$LIB_NAME.so" "$ANDROID_DIR/android/lib/lib/arm64-v8a/libmain.so"

    # --- ASSET PACKAGING ---
    if [ -f "$ASSETS_SRC" ]; then
        echo "--- Packaging assets ---"
        mkdir -p "$ANDROID_ASSETS_DIR"
        rm -rf "${ANDROID_ASSETS_DIR:?}"/*
        cp "$ASSETS_SRC" "$ANDROID_ASSETS_DIR/"
    fi

    # 5. Bundle and Sign APK
    cd "$ANDROID_DIR"
    odin bundle android android -android-keystore:"$KEYSTORE" -android-keystore-password:"android"
    
    # Export final APK
    cp "$(ls *.apk | head -n1)" "$APK_OUT"
    echo "APK Build Successful: $APK_OUT"
else
    # 6. Desktop Build
    cd "$ROOT_DIR"
    odin build . "${FINAL_FLAGS[@]}"
    echo "Desktop Build Successful!"
fi
