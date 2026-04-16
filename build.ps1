# build.ps1
$ErrorActionPreference = "Stop"

# --- CONFIGURATION ---
$ROOT_DIR = Get-Location
$PRESET_FILE = Join-Path $ROOT_DIR "build_presets.txt"
$ODIN_SOURCE_FILE = Join-Path $ROOT_DIR "configs.odin"

$ANDROID_DIR = Join-Path $ROOT_DIR "androidglue/apkbuild"
$KEYSTORE = ".keystore"
$APK_OUT = Join-Path $ROOT_DIR "OdinRenderer.apk"
$HIDDEN_EXT = ".buildtime-temp-hidden"

# --- HELPER: SCRAPE STRING VALUES FROM ODIN ARRAYS ---
Write-Host "--- Build System Initialization ---" -ForegroundColor Cyan

function Get-OdinArrayStrings([string]$arrayName) {
    if (Test-Path $ODIN_SOURCE_FILE) {
        $content = Get-Content $ODIN_SOURCE_FILE -Raw
        # Regex to find the array block and extract strings inside double quotes
        $regex = "(?s)$arrayName\s*::\s*\[[^\]]+\]string\s*\{([^\}]+)\}"
        if ($content -match $regex) {
            $block = $Matches[1]
            $strings = [regex]::Matches($block, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
            return $strings -join "|"
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
    Write-Host "WARNING: Odin source not found or empty. Manual validation fallback active." -ForegroundColor Yellow
    $VALID_TARGETS = "PC|MOBILE"
    $VALID_VARIANTS = "RELEASE|EDITOR|HEADLESS"
}

if (Test-Path $PRESET_FILE) {
    Write-Host "Available Presets:"
    Get-Content $PRESET_FILE | Where-Object { $_ -notmatch "^#" -and $_ -match ":" } | ForEach-Object {
        Write-Host "  - $($_.Split(':')[0])"
    }
}
Write-Host "-----------------------------------"

# --- INITIALIZE VARIABLES ---
$Target = ""
$Variant = ""
$Verbose = ""
$Tracking = ""
$CustomFlags = ""

# --- PARSE ARGUMENTS ---
foreach ($arg in $args) {
    switch -Regex ($arg) {
        "PRESET=(.*)" {
            $PresetName = $Matches[1]
            if (Test-Path $PRESET_FILE) {
                $Line = Get-Content $PRESET_FILE | Where-Object { $_ -like "$PresetName:*" } | Select-Object -First 1
                if ($Line) {
                    # Format: NAME:TARGET:VARIANT:VERBOSE:TRACKING:CUSTOM_FLAGS
                    $Parts = $Line.Split(":")
                    $Target      = $Parts[1]
                    $Variant     = $Parts[2]
                    $Verbose     = $Parts[3]
                    $Tracking    = $Parts[4]
                    if ($Parts.Count -ge 6) { $CustomFlags = $Parts[5] }
                } else {
                    Write-Error "Preset '$PresetName' not found in $PRESET_FILE"
                    exit 1
                }
            }
        }
        "TARGET=(.*)"     { $Target = $Matches[1] }
        "VARIANT=(.*)"    { $Variant = $Matches[1] }
        "VERBOSE=(.*)"    { $Verbose = $Matches[1] }
        "TRACKING=(.*)"   { $Tracking = $Matches[1] }
        "ODIN_FLAGS=(.*)" { $CustomFlags = $Matches[1] }
    }
}

# --- STRICT VALIDATION ---
$Missing = @()
if (-not $Target)   { $Missing += "TARGET" }
if (-not $Variant)  { $Missing += "VARIANT" }
if (-not $Verbose)  { $Missing += "VERBOSE" }
if (-not $Tracking) { $Missing += "TRACKING" }

if ($Missing.Count -gt 0) {
    Write-Host "`nERROR: Incomplete configuration." -ForegroundColor Red
    Write-Host "Usage (Preset): .\build.ps1 PRESET=[Name]"
    Write-Host "Usage (Manual): .\build.ps1 TARGET=[$VALID_TARGETS] VARIANT=[$VALID_VARIANTS] VERBOSE=[true|false] TRACKING=[true|false] ODIN_FLAGS=""..."""
    Write-Host "Missing requirements: $($Missing -join ', ')" -ForegroundColor Red
    exit 1
}

# --- CLEANUP & RESTORE FUNCTION ---
function Restore-OdinFiles {
    Write-Host "`n--- Restoring hidden Odin files ---" -ForegroundColor Cyan
    Get-ChildItem -Path $ROOT_DIR -Filter "*$HIDDEN_EXT" -Recurse -File | ForEach-Object {
        $OldName = $_.FullName
        $NewName = $_.FullName.Replace($HIDDEN_EXT, "")
        Move-Item -Path $OldName -Destination $NewName -Force
        Write-Host "  [+] Restored: $($_.Name.Replace($HIDDEN_EXT, ""))"
    }
}

try {
    # --- FILE HIDING LOGIC ---
    if ($Target -eq "MOBILE") {
        Write-Host "--- Target is MOBILE: Hiding desktop files ---" -ForegroundColor Yellow
        Get-ChildItem -Path $ROOT_DIR -Filter "*_desktop.odin" -File | ForEach-Object {
            Move-Item -Path $_.FullName -Destination ($_.FullName + $HIDDEN_EXT) -Force
        }
    } else {
        Write-Host "--- Target is PC: Hiding android files ---" -ForegroundColor Yellow
        Get-ChildItem -Path $ROOT_DIR -Filter "*_android.odin" -File | ForEach-Object {
            Move-Item -Path $_.FullName -Destination ($_.FullName + $HIDDEN_EXT) -Force
        }
    }

    # --- BUILD EXECUTION ---
    Write-Host "`n||| BUILDING: $Target | $Variant | FLAGS: $CustomFlags |||`n" -ForegroundColor Green

    $FinalFlags = @(
        "build", ".",
        "-define:BUILD_TARGET=$Target",
        "-define:BUILD_VARIANT=$Variant",
        "-define:VERBOSE_LOGGING=$Verbose",
        "-define:TRACKING_ALLOCATOR=$Tracking"
    )

    if ($CustomFlags) {
        # Split CustomFlags into separate arguments (handles spaces and quotes)
        $FinalFlags += [regex]::Matches($CustomFlags, '("[^"]+"|[^\s]+)') | ForEach-Object { $_.Value.Trim('"') }
    }

    if ($Target -eq "MOBILE") {
        # Android specific logic
        Set-Location $ANDROID_DIR
        if (-not (keytool -list -keystore $KEYSTORE -storepass android -alias androiddebugkey 2>$null)) {
            keytool -genkey -dname "CN=Android Debug, O=Android, C=US" -keystore $KEYSTORE `
                -alias androiddebugkey -storepass android -keypass android -keyalg RSA -validity 30000
        }

        Set-Location $ROOT_DIR
        $AndroidFlags = $FinalFlags + @("-target:linux_arm64", "-subtarget:android", "-build-mode:shared", "-extra-linker-flags=-lvulkan")
        & odin @AndroidFlags

        $LibName = Split-Path $ROOT_DIR -Leaf
        $LibPath = Join-Path $ANDROID_DIR "android/lib/lib/arm64-v8a"
        if (-not (Test-Path $LibPath)) { New-Item -ItemType Directory -Path $LibPath -Force }
        
        Move-Item -Path (Join-Path $ROOT_DIR "$LibName.so") -Destination (Join-Path $LibPath "libmain.so") -Force

        Set-Location $ANDROID_DIR
        & odin bundle android android -android-keystore:$KEYSTORE -android-keystore-password:android
        
        $BuiltApk = Get-ChildItem -Filter "*.apk" | Select-Object -First 1
        if ($BuiltApk) {
            Copy-Item -Path $BuiltApk.FullName -Destination $APK_OUT -Force
            Write-Host "APK Success: $APK_OUT" -ForegroundColor Green
        }
    } else {
        # Desktop specific logic
        Set-Location $ROOT_DIR
        & odin @FinalFlags
        Write-Host "Desktop Success!" -ForegroundColor Green
    }
}
finally {
    # This block always executes even on crash or manual termination
    Restore-OdinFiles
    Set-Location $ROOT_DIR
}
