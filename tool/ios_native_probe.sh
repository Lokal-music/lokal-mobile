#!/usr/bin/env bash
# Compile the actual Rust engine for an iPhone or iOS simulator without direct
# USB. This bypasses Cargokit intentionally; it is NOT an app/IPA/linkage test.
set -euo pipefail

probe_root="$(cd "$(dirname "$0")/.." && pwd)"
probe_target="${1:-aarch64-apple-ios}"
probe_min_ios="16.0"

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This probe requires macOS with Xcode; use the manual iOS native probe workflow.' >&2
  exit 2
fi

case "$probe_target" in
  aarch64-apple-ios)
    probe_sdk=iphoneos
    probe_clang_target=arm64-apple-ios16.0
    ;;
  aarch64-apple-ios-sim|x86_64-apple-ios)
    probe_sdk=iphonesimulator
    probe_clang_target=arm64-apple-ios16.0-simulator
    if [[ "$probe_target" == x86_64-apple-ios ]]; then
      probe_clang_target=x86_64-apple-ios16.0-simulator
    fi
    ;;
  *)
    echo "Unsupported iOS target: $probe_target" >&2
    exit 2
    ;;
esac

probe_toolchain="$(python3 - "$probe_root/rust/Cargo.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], 'rb') as source:
    version = tomllib.load(source)['package']['rust-version']
    print(version + '.0' if version.count('.') == 1 else version)
PY
)"
probe_sdk_path="$(xcrun --sdk "$probe_sdk" --show-sdk-path)"
xcodebuild -version
printf 'Probe target: %s; SDK: %s; deployment target: %s\n' "$probe_target" "$probe_sdk" "$probe_min_ios"
rustup toolchain install "$probe_toolchain" --profile minimal --no-self-update
rustup target add --toolchain "$probe_toolchain" "$probe_target"

# A tree check distinguishes the proposed iOS feature set from Android's default
# USB-enabled build. It does not change the manifest or dependency lockfile.
probe_tree="$(cargo "+$probe_toolchain" tree --locked --manifest-path "$probe_root/rust/Cargo.toml" \
  --target "$probe_target" --no-default-features --features native_audio,rquickjs/bindgen --edges normal,build)"
if [[ "$probe_tree" =~ (rusb|libusb1-sys)[[:space:]]v ]]; then
  echo 'Direct USB dependencies remain in the iOS graph; probe refused.' >&2
  exit 1
fi

# cc selects the Apple cross compiler from the Rust target. bindgen additionally
# needs the matching Apple SDK rather than the host macOS headers.
SDKROOT="$probe_sdk_path" \
IPHONEOS_DEPLOYMENT_TARGET="$probe_min_ios" \
BINDGEN_EXTRA_CLANG_ARGS="${BINDGEN_EXTRA_CLANG_ARGS:-} --target=$probe_clang_target -isysroot \"$probe_sdk_path\"" \
cargo "+$probe_toolchain" build --locked --release --lib \
  --manifest-path "$probe_root/rust/Cargo.toml" \
  --target "$probe_target" --no-default-features --features native_audio,rquickjs/bindgen

git -C "$probe_root" diff --exit-code -- rust/Cargo.lock pubspec.lock
printf 'PASS: Rust engine compiled for %s without direct USB. App linkage and runtime remain untested.\n' "$probe_target"
