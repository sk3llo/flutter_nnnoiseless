## 1.1.0

- **New `NoiselessSession` API** for real-time denoising: instance-based (run
  multiple concurrent streams), with `process`, `flush`, `reset` and
  `dispose`, plus a `StreamTransformer` (`session.transformer`) for piping a
  microphone stream straight through the denoiser
- **Voice activity detection**: `process` returns the RNNoise speech
  probability for every 10ms frame (`DenoiseResult.voiceProbabilities`,
  `voiceProbability`, `isVoice()`)
- **Output at your sample rate**: sessions resample internally (streaming,
  artifact-free via `rubato`) and return audio at the input rate instead of
  always 48kHz
- **Dry/wet mix**: `wet` parameter (0.0-1.0) controls suppression strength
- **`denoiseFile` robustness**: supports 16/24/32-bit int and 32-bit float
  WAV input (previously crashed on anything but 16-bit int) and preserves
  the input sample rate in the output file
- RNNoise's warm-up frame is silenced instead of leaking into the output
- Deprecated `Noiseless.denoiseChunk` in favor of `NoiselessSession`
- Upgraded `flutter_rust_bridge` to 2.12.0
- Example app updated to the session API with a live voice-probability log

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