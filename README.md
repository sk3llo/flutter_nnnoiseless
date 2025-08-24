<div align="center">

# Flutter NNNoiseless

_Real-Time and Batch Audio Noise Reduction for Flutter. Port of the [nnnoiseless](https://github.com/jneem/nnnoiseless) Rust project, based on Recurrent neural network and powered by [Flutter Rust Bridge](https://pub.dev/packages/flutter_rust_bridge)._

<p align="center">
  <a href="https://pub.dev/packages/flutter_nnnoiseless">
     <img src="https://img.shields.io/badge/pub-1.0.0-blue?logo=dart" alt="pub">
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

[Rust](https://www.rust-lang.org/learn/get-started) installation is required in order to generate necessary bindings.

## Getting started

1. Create `noiseless` instance:

```dart
final noiseless = Noiseless.instance;
```

2. Use it to denoise an audio file:

```dart
await noiseless.denoiseFile(inputPathStr: 'assets/noise.wav', outputPathStr: 'assets/output.wav');
```

3. Or in real-time Flutter audio input via a `Stream`:

```dart
stream.listen((input) async {
  final result = await noiseless.denoiseChunk(input: input);
});
```