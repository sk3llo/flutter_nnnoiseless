<div align="center">

# Flutter NNNoiseless

_Real-time and batch audio noise reduction for Flutter. A port of the [nnnoiseless](https://github.com/jneem/nnnoiseless) Rust crate (RNNoise), powered by [Flutter Rust Bridge](https://pub.dev/packages/flutter_rust_bridge)._

<p align="center">
  <a href="https://pub.dev/packages/flutter_nnnoiseless">
     <img src="https://img.shields.io/pub/v/flutter_nnnoiseless?logo=dart&color=blue" alt="pub">
  </a>
  <a href="https://buymeacoffee.com/sk3llo" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/default-orange.png" alt="Buy Me A Coffee" height="21" width="114"></a>
</p>
</div>

## Features

- Real-time denoising of raw PCM audio streams, such as microphone input
- Voice activity detection (VAD): a speech probability for every 10ms frame
- Batch denoising of WAV files (16/24/32-bit int and 32-bit float), with progress reporting and cancellation
- Multiple concurrent sessions, each with fully isolated state
- Multi-channel audio: interleaved PCM with up to 8 channels per session
- Custom RNNoise models trained on your own noise profiles
- Built-in streaming resampling: feed any sample rate, get the same rate back
- Adjustable suppression strength via a dry/wet mix parameter
- No Rust toolchain required: prebuilt, signed native libraries are downloaded automatically at build time

## Supported platforms

| Platform | Supported | Minimum version |
|----------|-----------|-----------------|
| Android  | ✅        | SDK 23          |
| iOS      | ✅        | 11.0            |
| macOS    | ✅        | 10.15           |
| Windows  | ✅        | Windows 10      |
| Linux    | In progress | -             |

Requires Flutter 3.0.0 or higher.

## Installation

```shell
flutter pub add flutter_nnnoiseless
```

No further setup is needed in most cases. If a prebuilt binary is not available for your platform, the build falls back to compiling from source, which requires a [Rust](https://www.rust-lang.org/learn/get-started) installation.

## Usage

### Real-time denoising

Create a `NoiselessSession` per audio stream. Each session owns its own denoiser state, so multiple sessions can run concurrently and nothing leaks between recordings.

The simplest way is to pipe a raw 16-bit PCM mono stream (for example from the `record` package) through the session's transformer:

```dart
final session = await NoiselessSession.create(sampleRate: 48000);

micStream.transform(session.transformer).listen(playOrSave);
```

Alternatively, process chunks yourself:

```dart
final result = await session.process(chunk);
save(result.audio); // denoised PCM at your sample rate
```

At the end of a recording:

```dart
final tail = await session.flush(); // drain buffered audio
await session.reset();              // reuse for the next recording...
session.dispose();                  // ...or release it
```

Sample rates other than 48000Hz are resampled internally and the denoised audio is returned at your input rate. The `wet` parameter of `NoiselessSession.create` (0.0 to 1.0) controls how aggressive the suppression is.

Sessions handle interleaved multi-channel audio and custom RNNoise models too:

```dart
final stereo = await NoiselessSession.create(channels: 2);

final custom = await NoiselessSession.create(
  model: await File('my_model.rnn').readAsBytes(),
);
```

### Voice activity detection

`process` returns the RNNoise speech probability for every 10ms frame:

```dart
final result = await session.process(chunk);

print(result.voiceProbability);   // 0.0 to 1.0, max over the chunk
print(result.voiceProbabilities); // per-frame values

if (result.isVoice()) {
  showSpeakingIndicator();
}
```

### Denoising a file

```dart
final token = NoiselessCancelToken();

await Noiseless.instance.denoiseFile(
  inputPathStr: 'assets/noise.wav',
  outputPathStr: 'assets/output.wav',
  onProgress: (fraction) => print('${(fraction * 100).round()}%'),
  cancelToken: token, // token.cancel() aborts with DenoiseCancelledException
);
```

Both `onProgress` and `cancelToken` are optional. Input can be 16/24/32-bit int or 32-bit float WAV at any sample rate. The output is written as 16-bit WAV at the input's sample rate.

### Saving PCM output as WAV

```dart
await Noiseless.instance.pcmToWav(
  pcmData: denoisedBytes,
  outputPath: '/path/to/output', // '.wav' is appended automatically
  sampleRate: 48000,
);
```

## How it works

The heavy lifting is done in Rust by [nnnoiseless](https://github.com/jneem/nnnoiseless), a rewrite of the [RNNoise](https://jmvalin.ca/demo/rnnoise/) recurrent neural network. Audio is processed in 480-sample frames at 48kHz; other sample rates are converted on the fly with a streaming resampler, so chunk boundaries stay artifact-free.

Native libraries for each platform are built in CI, signed, and attached to GitHub Releases. At build time [cargokit](https://github.com/irondash/cargokit) downloads the binary for your target, verifies its signature, and links it into your app. If no prebuilt binary matches, it compiles the crate locally instead.

## Example

The [example app](example/) records from the microphone, denoises the stream in real time, logs the voice probability, and saves both the raw and denoised audio as WAV files for comparison.

## License

Distributed under the LGPL-3.0 license. See [LICENSE](LICENSE) for details.
