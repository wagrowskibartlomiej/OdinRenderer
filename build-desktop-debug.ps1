$ErrorActionPreference = "Stop"

$HIDDEN_EXT = ".buildtime-temp-hidden"

function Cleanup {
    Write-Host "`n--- Restoring files names *_android.odin ---"
    $files = Get-ChildItem -Filter "*$HIDDEN_EXT" -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $newName = $f.Name.Replace($HIDDEN_EXT, "")
        Rename-Item -Path $f.FullName -NewName $newName
        Write-Host "Restored: $newName"
    }
    Write-Host "--------------------------------------------"
}

try {
    Write-Host "--- Hiding files names *_android.odin before calling odin build ---"
    $filesToHide = Get-ChildItem -Filter "*_android.odin" -ErrorAction SilentlyContinue
    foreach ($f in $filesToHide) {
        $newName = $f.Name + $HIDDEN_EXT
        Rename-Item -Path $f.FullName -NewName $newName
        Write-Host "Hidden: $newName"
    }
    Write-Host "-------------------------------------------------------------------"

    Write-Host "`n||| BUILDING |||`n"

    odin build . `
      -define:BUILD_TARGET=PC `
      -define:VERBOSE_LOGGING=true `
      -define:TRACKING_ALLOCATOR=true `
      -define:BUILD_VARIANT=EDITOR `
      -debug
}
finally {
    Cleanup
}
