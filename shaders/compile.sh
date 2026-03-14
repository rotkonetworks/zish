#!/bin/sh
# Compile GLSL compute shaders to SPIR-V
# Requires: glslangValidator (from vulkan-tools or glslang)
# Output: ~/.zish/shaders/*.spv

set -e

DIR="$(dirname "$0")"
OUT="${HOME}/.zish/shaders"
mkdir -p "$OUT"

for f in "$DIR"/*.comp; do
    name="$(basename "$f" .comp)"
    echo "compiling $name..."
    glslangValidator -V --target-env vulkan1.3 "$f" -o "$OUT/$name.spv"
done

echo "shaders installed to $OUT"
ls -la "$OUT"/*.spv
