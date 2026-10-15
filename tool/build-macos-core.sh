#!/usr/bin/env bash
# Build universal (arm64 + x86_64) libgvcore.dylib for macOS.
set -euo pipefail

cd "$(dirname "$0")/../core"

rustup target add aarch64-apple-darwin x86_64-apple-darwin
cargo build --release --lib --target aarch64-apple-darwin
cargo build --release --lib --target x86_64-apple-darwin

mkdir -p target/release
lipo -create \
  target/aarch64-apple-darwin/release/libgvcore.dylib \
  target/x86_64-apple-darwin/release/libgvcore.dylib \
  -output target/release/libgvcore.dylib

install_name_tool -id "@rpath/libgvcore.dylib" target/release/libgvcore.dylib
echo "Built universal libgvcore.dylib (arm64 + x86_64)"
