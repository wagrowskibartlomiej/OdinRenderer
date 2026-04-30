#!/bin/bash

mkdir -p ./assets/shaders/spirv

$VULKAN_SDK/bin/glslc ./assets/shaders/default_vertex.vert -o default_vertex.spv --target-env=vulkan1.0
$VULKAN_SDK/bin/glslc ./assets/shaders/default_fragment.frag -o default_fragment.spv --target-env=vulkan1.0

mv default_vertex.spv ./assets/shaders/spirv/default_vertex.spv
mv default_fragment.spv ./assets/shaders/spirv/default_fragment.spv
