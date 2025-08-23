### Flutter NNNoiseless

Port of the [nnnoiseless](https://github.com/jneem/nnnoiseless) Rust project to Flutter. Based on Recurrent neural network for audio noise reduction and connected to Flutter using [Flutter Rust Bridge](https://pub.dev/packages/flutter_rust_bridge).

## Getting started

1. Generate rust bridge bindings:

```
flutter_rust_bridge_codegen integrate
```

2. Create an instance of the NNNoiseless class:

```
final nnnoiseless = Noiseless.instance;
```

## Usage

Use the instance to reduce noise in an audio file:

```
await nnnoiseless.denoise(inputPathStr: 'assets/noise.wav', outputPathStr: 'assets/output.wav');
```

Or in real-time Flutter audio input via a `Stream`:

```
stream.listen((input) async {
  final result = await Noiseless.instance.denoiseRealtime(input: input);
});
```

## Requirements

- `Flutter 3.0.0` or higher
- `osx 10.15` or higher
- `rust_flutter_bridge 2.0.0` or higher