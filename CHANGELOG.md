## 1.2.0

- **Multi-channel sessions**: `NoiselessSession.create(channels: n)` denoises
  interleaved PCM with up to 8 channels, each with independent RNNoise state;
  channel alignment survives arbitrary chunk sizes
- **Custom RNNoise models**: pass `model:` bytes in the nnnoiseless training
  format to `NoiselessSession.create` to use your own trained weights
- **File progress and cancellation**: `denoiseFile` accepts `onProgress`
  (fraction 0.0 to 1.0) and `cancelToken` (throws
  `DenoiseCancelledException` on cancel)
- Precompiled binaries now include Linux ARM64
  (`aarch64-unknown-linux-gnu`)
- CI now builds the example app for Linux desktop
- Hardening from an adversarial review pass:
  - sessions survive chunks split at odd byte offsets (a one-byte carry
    keeps 16-bit sample pairs and channel alignment intact)
  - `NoiselessCancelToken` can safely be constructed before any other
    plugin call (the native token is created lazily); tokens are one-shot
    and documented as such
  - cancellation is detected from the token state, never by matching the
    error message
  - `denoiseFile` reports progress and honors cancellation during the
    resample and write phases too, cleans up a partially-written output
    file on cancel, no longer panics on WAVs whose sample count is not a
    multiple of the channel count, and surfaces Rust panics as errors
    instead of silent success
  - a throwing `onProgress` callback now cancels the native work
  - whole-file denoising runs on a dedicated thread so it cannot starve
    real-time sessions; session creation moved off the UI thread
- Note for implementers extending `Noiseless`: `denoiseFile` gained two
  optional named parameters, so overrides must be updated to match

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