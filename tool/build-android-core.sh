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

# A C++ symbol left undefined here does not fail the build: the app fails to
# start on the device instead. Nothing else on Android provides them.
ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK_LATEST_HOME:-}}}"
nm=$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/llvm-nm 2>/dev/null | head -1 || true)
if [ -n "$nm" ]; then
  for abi in "${abis[@]}"; do
    missing=$("$nm" -D --undefined-only "../android/app/src/main/jniLibs/$abi/libgvcore.so" | grep ' _Z' || true)
    if [ -n "$missing" ]; then
      echo "libgvcore.so for $abi needs C++ symbols nothing provides:" >&2
      echo "$missing" | head -20 >&2
      exit 1
    fi
  done
  echo "Checked libgvcore.so: no C++ symbols left undefined"
else
  echo "::warning::llvm-nm not found, so libgvcore.so was not checked for undefined C++ symbols"
fi

echo "Built libgvcore.so for: ${abis[*]}"
