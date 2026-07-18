import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_nnnoiseless/flutter_nnnoiseless.dart';
import 'package:flutter_nnnoiseless/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:wav/wav.dart';

/// Host-arch Rust library, built with `cargo build --release` in `rust/`.
const _dylibPath = 'rust/target/release/librust_lib_flutter_nnnoiseless.dylib';

/// 1 second of a 440Hz tone mixed with white noise, as 16-bit PCM bytes.
Uint8List _noisySine(int sampleRate) {
  final rng = Random(42);
  final samples = Int16List(sampleRate);
  for (var i = 0; i < samples.length; i++) {
    final tone = 0.5 * sin(2 * pi * 440 * i / sampleRate);
    final noise = 0.1 * (rng.nextDouble() * 2 - 1);
    samples[i] = ((tone + noise) * 32767).clamp(-32768, 32767).toInt();
  }
  return samples.buffer.asUint8List();
}

void main() {
  final dylib = File(_dylibPath);

  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
  });

  test('denoiseChunk processes consecutive 48kHz chunks', () async {
    final input = _noisySine(48000);

    final first = await Noiseless.instance.denoiseChunk(input: input);
    final second = await Noiseless.instance.denoiseChunk(input: input);

    // 48000 samples = 100 full frames of 480 -> all input consumed.
    expect(first.length, input.length);
    expect(second.length, input.length);
    // Output must be valid 16-bit PCM and not all silence.
    expect(first.length.isEven, isTrue);
    expect(first.buffer.asInt16List().any((s) => s != 0), isTrue);
  }, skip: !dylib.existsSync() ? 'Rust dylib not built' : false);

  test('denoiseChunk buffers partial frames across calls', () async {
    // 100 samples is less than one 480-sample frame: no output yet.
    final partial = Uint8List.view(_noisySine(48000).buffer, 0, 200);
    final empty = await Noiseless.instance.denoiseChunk(input: partial);
    expect(empty, isEmpty);
  }, skip: !dylib.existsSync() ? 'Rust dylib not built' : false);

  test('denoiseFile round-trips a WAV file', () async {
    final dir = await Directory.systemTemp.createTemp('nnnoiseless_test');
    final inputPath = '${dir.path}/input.wav';
    final outputPath = '${dir.path}/output.wav';

    final pcm = _noisySine(48000).buffer.asInt16List();
    final channel = Float64List.fromList(
      pcm.map((s) => s / 32767.0).toList(),
    );
    await Wav([channel], 48000).writeFile(inputPath);

    await Noiseless.instance.denoiseFile(
      inputPathStr: inputPath,
      outputPathStr: outputPath,
    );

    final output = await Wav.readFile(outputPath);
    expect(output.samplesPerSecond, 48000);
    expect(output.channels.single, isNotEmpty);

    await dir.delete(recursive: true);
  }, skip: !dylib.existsSync() ? 'Rust dylib not built' : false);
}
