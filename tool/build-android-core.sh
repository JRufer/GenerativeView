#!/usr/bin/env bash
# Cross-compile the Rust core for Android and drop the .so files where
# Gradle picks them up. Run this before `flutter build apk`.
#
#   tool/build-android-core.sh                 # arm64-v8a, armeabi-v7a, x86_64
#   tool/build-android-core.sh arm64-v8a       # just the tablet ABI (fastest)
#
# Needs: the Android NDK (ANDROID_NDK_HOME), `cargo install cargo-ndk`, and
# the matching Rust targets:
#   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
set -euo pipefail

cd "$(dirname "$0")/../core"

if [ "$#" -gt 0 ]; then abis=("$@"); else abis=(arm64-v8a armeabi-v7a x86_64); fi
targets=()
for abi in "${abis[@]}"; do targets+=(-t "$abi"); done

cargo ndk "${targets[@]}" --platform 24 \
  -o ../android/app/src/main/jniLibs \
  build --release --lib

echo "Built libgvcore.so for: ${abis[*]}"
