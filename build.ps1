# --- CONFIGURATION ---
$ROOT_DIR = Get-Location
$PRESET_FILE = Join-Path $ROOT_DIR "build_presets.txt"
$ODIN_SOURCE_FILE = Join-Path $ROOT_DIR "configs.odin"

$ANDROID_DIR = Join-Path $ROOT_DIR "androidglue/apkbuild"
$MANIFEST_PATH = Join-Path $ANDROID_DIR "android/AndroidManifest.xml"
$KEYSTORE = ".keystore"
$APK_OUT = Join-Path $ROOT_DIR "OdinRenderer.apk"
$HIDDEN_EXT = ".buildtime-temp-hidden"

# Assets configuration
$ASSETS_SRC = Join-Path $ROOT_DIR "assets.packed"
$ANDROID_ASSETS_DIR = Join-Path $ANDROID_DIR "android/assets"

Write-Host "--- Build System Initialization ---"

# --- HELPER: SCRAPE STRING VALUES FROM ODIN ARRAYS ---
function Get-OdinArrayStrings([string]$arrayName) {
    if (Test-Path $ODIN_SOURCE_FILE) {
        $content = Get-Content $ODIN_SOURCE_FILE -Raw
        $pattern = "$arrayName :: \{(.*?)\}"
        if ($content -match $pattern) {
            $matches = [regex]::Matches($matches[1], '"([^"]*)"')
            return ($matches.Value -replace '"', '') -join "|"
        }
    }
    return ""
}

$VALID_TARGETS = Get-OdinArrayStrings "Build_Targets"
$VALID_VARIANTS = Get-OdinArrayStrings "Build_Variants"

if ($VALID_TARGETS) {
    Write-Host "Detected Targets:  [$VALID_TARGETS]"
    Write-Host "Detected Variants: [$VALID_VARIANTS]"
} else {
    Write-Host "WARNING: Odin source not found. Manual validation fallback active."
    $VALID_TARGETS = "PC|MOBILE"
    $VALID_VARIANTS = "RELEASE|EDITOR|HEADLESS"
}

if (Test-Path $PRESET_FILE) {
    Write-Host "Available Presets:"
    Get-Content $PRESET_FILE | Where-Object { $_ -match "^[^#\s]" } | ForEach-Object {
        Write-Host "  - $($_.Split(':')[0].Trim())"
    }
}
Write-Host "-----------------------------------"

# --- INITIALIZE VARIABLES ---
$TARGET = ""
$VARIANT = ""
$VERBOSE = ""
$TRACKING = ""
$CUSTOM_FLAGS = ""
$APK_DEBUG = ""

# --- PARSE ARGUMENTS ---
foreach ($arg in $args) {
    if ($arg -like "APK-DEBUG=*") { $APK_DEBUG = $arg.Split('=')[1] }
    if ($arg -like "PRESET=*") {
        $presetName = $arg.Split('=')[1]
        $line = Get-Content $PRESET_FILE | Where-Object { $_ -match "^[^\w]*$presetName[^\w]*:" } | Select-Object -First 1
        
        if ($line) {
            # Clean spaces around colons and split
            $parts = ($line -replace '\s*:\s*', ':').Trim().Split(':')
            $TARGET = $parts[1]
            $VARIANT = $parts[2]
            $VERBOSE = $parts[3]
            $TRACKING = $parts[4]
            $p_apk_debug = $parts[5]
            $CUSTOM_FLAGS = ($parts[6..($parts.Length - 1)]) -join ":"
            
            if (-not $APK_DEBUG) { $APK_DEBUG = $p_apk_debug }
        } else {
            Write-Error "Preset '$presetName' not found in $PRESET_FILE"
            exit 1
        }
    }
    # Manual overrides
    if ($arg -like "TARGET=*")   { $TARGET = $arg.Split('=')[1] }
    if ($arg -like "VARIANT=*")  { $VARIANT = $arg.Split('=')[1] }
    if ($arg -like "VERBOSE=*")  { $VERBOSE = $arg.Split('=')[1] }
    if ($arg -like "TRACKING=*") { $TRACKING = $arg.Split('=')[1] }
    if ($arg -like "ODIN_FLAGS=*") { $CUSTOM_FLAGS = $arg.Split('=')[1] }
}

$APK_DEBUG = if ($APK_DEBUG) { $APK_DEBUG } else { "false" }

# --- STRICT VALIDATION ---
if (-not $TARGET -or -not $VARIANT -or -not $VERBOSE -or -not $TRACKING) {
    Write-Host "`nERROR: Incomplete configuration." -ForegroundColor Red
    Write-Host "Usage (Preset): .\build.ps1 PRESET=[Name] (optional: APK-DEBUG=true)"
    Write-Host "Usage (Manual): .\build.ps1 TARGET=[$VALID_TARGETS] VARIANT=[$VALID_VARIANTS] VERBOSE=[true|false] TRACKING=[true|false] ODIN_FLAGS='...'"
    exit 1
}

if ($TARGET -eq "PC" -and $APK_DEBUG -eq "true") {
    Write-Error "APK-DEBUG=true is invalid for PC builds."
    exit 1
}

try {
    # --- FILE HIDING LOGIC ---
    if ($TARGET -eq "MOBILE") {
        Write-Host "--- Target is MOBILE: Hiding desktop files ---"
        Get-ChildItem -Path $ROOT_DIR -Filter "*_desktop.odin" -Depth 1 | ForEach-Object {
            Move-Item $_.FullName ($_.FullName + $HIDDEN_EXT) -Force
        }
    } else {
        Write-Host "--- Target is PC: Hiding android files ---"
        Get-ChildItem -Path $ROOT_DIR -Filter "*_android.odin" -Depth 1 | ForEach-Object {
            Move-Item $_.FullName ($_.FullName + $HIDDEN_EXT) -Force
        }
    }

    # --- BUILD INFO DISPLAY ---
    Write-Host "`nBUILD OPTIONS:" -ForegroundColor Cyan
    Write-Host "  TARGET       : $TARGET"
    Write-Host "  VARIANT      : $VARIANT"
    Write-Host "  VERBOSE      : $VERBOSE"
    Write-Host "  TRACKING     : $TRACKING"
    if ($TARGET -eq "MOBILE") { Write-Host "  APK-DEBUG    : $APK_DEBUG" }
    Write-Host "  CUSTOM FLAGS : $CUSTOM_FLAGS"
    Write-Host "----------------------------`n"

    $FINAL_FLAGS = @(
        "-define:BUILD_TARGET=$TARGET",
        "-define:BUILD_VARIANT=$VARIANT",
        "-define:VERBOSE_LOGGING=$VERBOSE",
        "-define:TRACKING_ALLOCATOR=$TRACKING"
    )
    if ($CUSTOM_FLAGS) { $FINAL_FLAGS += $CUSTOM_FLAGS.Split(' ') }

    if ($TARGET -eq "MOBILE") {
        # 1. Patch Manifest
        if (Test-Path $MANIFEST_PATH) {
            Write-Host "Updating manifest: debuggable=$APK_DEBUG"
            $content = Get-Content $MANIFEST_PATH -Raw
            $content = $content -replace 'android:debuggable="[^"]*"', "android:debuggable=`"$APK_DEBUG`""
            Set-Content $MANIFEST_PATH $content
        }

        # 2. Keystore
        Push-Location $ANDROID_DIR
        if (-not (Test-Path $KEYSTORE)) {
            Write-Host "Generating debug keystore..."
            keytool -genkey -dname "CN=Android Debug, O=Android, C=US" -keystore $KEYSTORE `
                -alias androiddebugkey -storepass android -keypass android -keyalg RSA -validity 30000
        }

        # 3. Odin Build
        Pop-Location
        odin build . @FINAL_FLAGS -target:linux_arm64 -subtarget:android -build-mode:shared -extra-linker-flags="-lvulkan"

        # 4. Lib Placement
        $LIB_NAME = (Get-Item $ROOT_DIR).Name
        $DEST_LIB_DIR = Join-Path $ANDROID_DIR "android/lib/lib/arm64-v8a"
        if (-not (Test-Path $DEST_LIB_DIR)) { New-Item -ItemType Directory -Path $DEST_LIB_DIR -Force }
        Move-Item "$ROOT_DIR\$LIB_NAME.so" "$DEST_LIB_DIR\libmain.so" -Force

        # 5. Assets
        if (Test-Path $ASSETS_SRC) {
            if (-not (Test-Path $ANDROID_ASSETS_DIR)) { New-Item -ItemType Directory -Path $ANDROID_ASSETS_DIR -Force }
            Remove-Item "$ANDROID_ASSETS_DIR\*" -Recurse -Force
            Copy-Item $ASSETS_SRC $ANDROID_ASSETS_DIR
        }

        # 6. Bundle
        Push-Location $ANDROID_DIR
        odin bundle android android -android-keystore:$KEYSTORE -android-keystore-password:"android"
        
        $generatedApk = Get-ChildItem "*.apk" | Select-Object -First 1
        Copy-Item $generatedApk $APK_OUT -Force
        Write-Host "APK Build Successful: $APK_OUT" -ForegroundColor Green
    } else {
        # Desktop Build
        odin build . @FINAL_FLAGS
        Write-Host "Desktop Build Successful!" -ForegroundColor Green
    }
}
finally {
    # --- CLEANUP (The PS equivalent of 'trap') ---
    Write-Host "`n--- Restoring environment ---" -ForegroundColor Gray
    Get-ChildItem -Path $ROOT_DIR -Filter "*$HIDDEN_EXT" -Recurse -Depth 2 | ForEach-Object {
        $newName = $_.FullName -replace [regex]::Escape($HIDDEN_EXT), ''
        Move-Item $_.FullName $newName -Force
    }

    if ($TARGET -eq "MOBILE" -and (Test-Path $MANIFEST_PATH)) {
        $content = Get-Content $MANIFEST_PATH -Raw
        $content = $content -replace 'android:debuggable="true"', 'android:debuggable="false"'
        Set-Content $MANIFEST_PATH $content
        Write-Host "AndroidManifest.xml: reset debuggable to false"
    }
}
