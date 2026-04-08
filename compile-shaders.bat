@echo off

if not exist "assets\shaders\spirv" mkdir "assets\shaders\spirv"

"%VULKAN_SDK%\bin\glslc.exe" assets\shaders\default_vertex.vert -o default_vertex.spv
"%VULKAN_SDK%\bin\glslc.exe" assets\shaders\default_fragment.frag -o default_fragment.spv

move /Y default_vertex.spv assets\shaders\spirv\default_vertex.spv
move /Y default_fragment.spv assets\shaders\spirv\default_fragment.spv

echo Shaders compiled successfully!
pause
