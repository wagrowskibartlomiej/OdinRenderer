#!/bin/bash

SHADER_DIR="./assets/shaders"
SPIRV_DIR="$SHADER_DIR/spirv"

mkdir -p "$SPIRV_DIR"

compile_shaders() {
    for shader in "$SHADER_DIR"/*.{vert,frag}; do

        [ -e "$shader" ] || continue

        filename=$(basename "$shader")

        basename_no_ext="${filename%.*}"

        output_file="$SPIRV_DIR/$basename_no_ext.spv"

        echo "Compiling: $filename -> $basename_no_ext.spv"

        $VULKAN_SDK/bin/glslc "$shader" -o "$output_file" --target-env=vulkan1.0
    done
}

compile_shaders

echo "Compiled shaders are in $SPIRV_DIR"
