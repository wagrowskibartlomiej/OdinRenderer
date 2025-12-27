#!/bin/bash

mkdir -p ./assets/shaders/spirv

$VULKAN_SDK/bin/glslc ./assets/shaders/default_vertex.vert -o default_vertex.spv
$VULKAN_SDK/bin/glslc ./assets/shaders/default_fragment.frag -o default_fragment.spv
