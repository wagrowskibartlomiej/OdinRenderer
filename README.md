# OdinRenderer

Version: 0.1 Alpha \
**A lot of features are missing, there's no typical game engine Editor, you need to change the code directly.** \
**There are probably a lot of bugs, use at your own risk, definitely NOT production ready!** \
Simple 3D rendering engine, written in Odin that uses Vulkan and can be built for Windows, Linux and Android ARM64 (experimental since Odin doesn't support Android)

## How to build
You can build the engine, for three different platforms. **Since Android is not supported yet** the building scripts **build.sh** and **build.ps1** are used - using plain **odin build .** won't work.

### What do you  need for Desktop builds
    1. Odin (at least version 2026-05 dev or any non breaking compatibile with that)
    2. Vulkan SDK
### What do you need for APK builds
    1. The desktop prerequisites listed above
    2. Android SDK with ODIN_NDK env variable
    3. Something for keystore generation

### Building process
Building APK is only available on Linux. Maybe it can work on Windows, but I'm not sure. My best bet would be to use WSL to build APK on Windows.

Using build scripts you need to either pass required defines or use preset from **presets.txt** file, which is the recommended way. \
Example: **./build.sh PRESET=DESKTOP-DEBUG**

First, building the debug preset or editor variant is needed, because it'll build **assets.packed** file from **assets** directory. Then the code will use assets that were loaded that way. After the **assets.packed** is built you can build Release or APK. They require **assets.packed** file to launch.

## Debugging
### RenderDoc
    1. You can use RenderDoc with the engine.
    2. If you're on Wayland passing hint to GLFW for using X11 should help if you're experiencing any bugs. 
    3. I've also managed to sucessfully capture frames from Android with RenderDoc.
### Vulkan Validation Layers
    1. Validation Layers should work properly when **configuration.engine** file has them **enabled**.
    2. If you want to use Validation Layers on Android you need to place layers .so file next to libmain.so, from there it'll be bundled in APK and from my experience it works fine.
### Logging
    1. You can use **-define:VERBOSE_LOGGING=true** to enable more detailed logs.
    2. Logging on Android does work, by using logger that writes to Logcat.
