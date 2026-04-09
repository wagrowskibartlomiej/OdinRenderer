@echo off
:: THIS IS EXPERMIENTAL
setlocal enabledelayedexpansion

set "HIDDEN_EXT=.buildtime-temp-hidden"

echo --- Hiding files names *_android.odin before calling odin build ---
for %%f in (*_android.odin) do (
    ren "%%f" "%%f%HIDDEN_EXT%"
    echo Hidden: %%f%HIDDEN_EXT%
)
echo -------------------------------------------------------------------

echo.
echo ^|^|^| BUILDING ^|^|^|
echo.

odin build . ^
  -define:BUILD_TARGET=PC ^
  -define:VERBOSE_LOGGING=true ^
  -define:TRACKING_ALLOCATOR=true ^
  -define:BUILD_VARIANT=EDITOR ^
  -debug

set BUILD_ERROR=%errorlevel%

echo.
echo --- Restoring files names *_android.odin ---
for %%f in (*%HIDDEN_EXT%) do (
    set "fname=%%f"
    ren "%%f" "!fname:%HIDDEN_EXT%=!"
    echo Restored: !fname:%HIDDEN_EXT%=!
)
echo --------------------------------------------

if %BUILD_ERROR% neq 0 exit /b %BUILD_ERROR%
