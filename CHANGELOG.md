## 1.0.2

- **Fixed `denoiseChunk` crashing with a stack overflow**: the Dart wrapper was
  recursively calling itself instead of the underlying Rust binding, so
  real-time denoising never worked in 1.0.1
- Removed leftover placeholder comments from the public wrapper
- Fixed iOS/macOS podspec metadata (placeholder summary/description, broken
  homepage URL, stale `0.0.1` version) and aligned the macOS deployment
  target with the documented `10.15` minimum
- Corrected the meaningless `flutter: ">=1.10.0"` SDK constraint to `>=3.0.0`

## 1.0.1

- Changed method `denoiseInRealtime` to `denoiseChunk` for readability
- Added description to the `denoise` methods
- Removed rust_builder
- Updated README.md

## 1.0.0

* Initial release