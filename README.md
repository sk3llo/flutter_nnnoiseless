<div align="center">

# Flutter NNNoiseless

_Real-Time and Batch Audio Noise Reduction for Flutter. Port of the [nnnoiseless](https://github.com/jneem/nnnoiseless) Rust project, based on Recurrent neural network and powered by [Flutter Rust Bridge](https://pub.dev/packages/flutter_rust_bridge)._

<p align="center">
  <a href="https://pub.dev/packages/flutter_nnnoiseless">
     <img src="https://img.shields.io/pub/v/flutter_nnnoiseless?logo=dart&color=blue" alt="pub">
  </a>
  <a href="https://buymeacoffee.com/sk3llo" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/default-orange.png" alt="Buy Me A Coffee" height="21" width="114"></a>
</p>
</div>


## Supported platforms


| Platform  | Supported |
|-----------|-----------|
| Android   | ✅        |
| iOS       | ✅        |
| MacOS     | ✅        |
| Windows   | ✅        |
| Linux     | In progress       |


## Requirements

- `Flutter 3.0.0` or higher
- `iOS 11.0` or higher
- `macOS 10.15` or higher
- `Android SDK 23` or higher
- `Windows 10` or higher

## Setup

No extra setup is needed in most cases: prebuilt, signed native libraries are
downloaded automatically at build time. If a prebuilt binary isn't available
for your platform, the build falls back to compiling from source, which
requires a [Rust](https://www.rust-lang.org/learn/get-started) installation.

## Getting started

### Real-time denoising

Create a `NoiselessSession` per audio stream. Each session owns its own
denoiser state, so multiple sessions can run concurrently and nothing leaks
between recordings:

```dart
final session = await NoiselessSession.create(sampleRate: 48000);

// Pipe a raw 16-bit PCM mono stream (e.g. from the `record` package):
micStream.transform(session.transformer).listen(playOrSave);

// ...or process chunks yourself and read voice activity per chunk:
final result = await session.process(chunk);
save(result.audio);                     // denoised PCM at your sample rate
if (result.isVoice()) showSpeakingIndicator();

// At the end of a recording:
final tail = await session.flush();     // drain buffered audio
await session.reset();                  // reuse for the next recording...
session.dispose();                      // ...or release it
```

Sample rates other than 48000Hz are resampled internally and the denoised
audio is returned at your input rate. A `wet` parameter (0.0-1.0) controls
how aggressive the suppression is.

### Voice activity detection (VAD)

`process` returns the RNNoise speech probability for every 10ms frame:

```dart
final result = await session.process(chunk);
print(result.voiceProbability);         // 0.0-1.0, max over the chunk
print(result.voiceProbabilities);       // per-frame values
```

### Denoising a file

```dart
await Noiseless.instance.denoiseFile(
  inputPathStr: 'assets/noise.wav',
  outputPathStr: 'assets/output.wav',
);
```

Supports 16/24/32-bit int and 32-bit float WAV at any sample rate; the
output is 16-bit WAV at the input's sample rate.