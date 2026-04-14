#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$ROOT/rust"
OUT_DIR="$ROOT/ios/Frameworks"
TMP_DIR="$(mktemp -d)"
LIB="rust_lib_flutter_nnnoiseless"

IOS_DEVICE_TARGET="aarch64-apple-ios"
IOS_SIM_ARM64_TARGET="aarch64-apple-ios-sim"
IOS_SIM_X64_TARGET="x86_64-apple-ios"

mkdir -p "$OUT_DIR"

make_framework () {
  local framework_dir="$1"
  local dylib_path="$2"

  mkdir -p "$framework_dir"
  cp "$dylib_path" "$framework_dir/$LIB"
  install_name_tool -id "@rpath/$LIB.framework/$LIB" "$framework_dir/$LIB"

  cat > "$framework_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$LIB</string>
  <key>CFBundleIdentifier</key>
  <string>com.sk3llo.rust-lib-flutter-nnnoiseless</string>
  <key>CFBundleName</key>
  <string>$LIB</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>MinimumOSVersion</key>
  <string>11.0</string>
</dict>
</plist>
PLIST
}

DEVICE_DYLIB="$RUST_DIR/target/$IOS_DEVICE_TARGET/release/lib$LIB.dylib"
SIM_ARM64_DYLIB="$RUST_DIR/target/$IOS_SIM_ARM64_TARGET/release/lib$LIB.dylib"
SIM_X64_DYLIB="$RUST_DIR/target/$IOS_SIM_X64_TARGET/release/lib$LIB.dylib"

SIM_UNIVERSAL="$TMP_DIR/lib$LIB-sim-universal.dylib"
lipo -create "$SIM_ARM64_DYLIB" "$SIM_X64_DYLIB" -output "$SIM_UNIVERSAL"

DEVICE_FRAMEWORK="$TMP_DIR/ios-arm64/$LIB.framework"
SIM_FRAMEWORK="$TMP_DIR/ios-arm64_x86_64-simulator/$LIB.framework"

make_framework "$DEVICE_FRAMEWORK" "$DEVICE_DYLIB"
make_framework "$SIM_FRAMEWORK" "$SIM_UNIVERSAL"

rm -rf "$OUT_DIR/$LIB.xcframework"

xcodebuild -create-xcframework \
  -framework "$DEVICE_FRAMEWORK" \
  -framework "$SIM_FRAMEWORK" \
  -output "$OUT_DIR/$LIB.xcframework"

echo "Built: $OUT_DIR/$LIB.xcframework"
