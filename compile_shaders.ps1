New-Item -ItemType Directory -Force -Path "./assets/shaders/spirv"

& "$env:VULKAN_SDK/bin/glslc.exe" ./assets/shaders/default_vertex.vert -o default_vertex.spv
& "$env:VULKAN_SDK/bin/glslc.exe" ./assets/shaders/default_fragment.frag -o default_fragment.spv

Move-Item -Path "default_vertex.spv" -Destination "./assets/shaders/spirv/default_vertex.spv" -Force
Move-Item -Path "default_fragment.spv" -Destination "./assets/shaders/spirv/default_fragment.spv" -Force

Write-Host "Shaders compiled and moved successfully!" -ForegroundColor Green
