#!/bin/bash

mkdir -p ./assets/shaders/spirv

$VULKAN_SDK/bin/glslc ./assets/shaders/default_vertex.vert -o default_vertex.spv
$VULKAN_SDK/bin/glslc ./assets/shaders/default_fragment.frag -o default_fragment.spv

mv default_vertex.spv ./assets/shaders/spirv/default_vertex.spv
mv default_fragment.spv ./assets/shaders/spirv/default_fragment.spv
