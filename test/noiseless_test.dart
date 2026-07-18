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

  group('NoiselessSession', () {
    test('processes chunks and reports VAD', () async {
      final session = await NoiselessSession.create();
      final result = await session.process(_noisySine(48000));

      expect(result.audio.length, 48000 * 2);
      // 100 frames of 10ms each.
      expect(result.voiceProbabilities.length, 100);
      expect(
        result.voiceProbabilities.every((p) => p >= 0.0 && p <= 1.0),
        isTrue,
      );
      session.dispose();
    });

    test('VAD is higher for tonal signal than for pure noise', () async {
      final session = await NoiselessSession.create();
      final tonal = await session.process(_noisySine(48000));
      await session.reset();

      final rng = Random(7);
      final noise = Int16List(48000);
      for (var i = 0; i < noise.length; i++) {
        noise[i] = ((rng.nextDouble() * 2 - 1) * 3000).toInt();
      }
      final noisy = await session.process(noise.buffer.asUint8List());

      expect(
        tonal.voiceProbability,
        greaterThan(noisy.voiceProbability),
        reason: 'a steady tone should look more voice-like than white noise',
      );
      session.dispose();
    });

    test('16kHz session returns audio at 16kHz and can flush the tail',
        () async {
      final session = await NoiselessSession.create(sampleRate: 16000);
      final input = _noisySine(16000); // 1 second at 16kHz
      final result = await session.process(input);
      final tail = await session.flush();

      final total = result.audio.length + tail.length;
      // Output should be within ~15% of the input length (resampler and
      // frame buffering trim the edges).
      expect(total, greaterThan(input.length * 0.85));
      expect(total, lessThanOrEqualTo(input.length * 1.15));
      session.dispose();
    });

    test('two concurrent sessions do not share state', () async {
      final a = await NoiselessSession.create();
      final b = await NoiselessSession.create();

      // Feed a partial frame to session A only: 200 samples < 480.
      final partial = Uint8List.view(_noisySine(48000).buffer, 0, 400);
      final resultA = await a.process(partial);
      expect(resultA.audio, isEmpty);

      // Session B must not see A's buffered samples.
      final resultB = await b.process(_noisySine(48000));
      expect(resultB.audio.length, 48000 * 2);

      a.dispose();
      b.dispose();
    });

    test('reset clears buffered samples', () async {
      final session = await NoiselessSession.create();
      final partial = Uint8List.view(_noisySine(48000).buffer, 0, 400);
      await session.process(partial);
      await session.reset();

      // After reset, exactly one full second produces exactly one second.
      final result = await session.process(_noisySine(48000));
      expect(result.audio.length, 48000 * 2);
      session.dispose();
    });

    test('wet=0.0 passes audio through (except warm-up frame)', () async {
      final session = await NoiselessSession.create(wet: 0.0);
      final input = _noisySine(48000);
      final result = await session.process(input);

      final inSamples = input.buffer.asInt16List();
      final outSamples = result.audio.buffer.asInt16List();
      // Skip the silenced warm-up frame (480 samples).
      for (var i = 480; i < 4800; i++) {
        expect((outSamples[i] - inSamples[i]).abs(), lessThanOrEqualTo(1));
      }
      session.dispose();
    });

    test('transformer denoises a stream and emits the flushed tail', () async {
      final session = await NoiselessSession.create();
      final input = _noisySine(48000);
      final chunks = <Uint8List>[
        for (var i = 0; i < input.length; i += 1000)
          Uint8List.sublistView(
              input, i, (i + 1000).clamp(0, input.length)),
      ];

      final output = await Stream.fromIterable(chunks)
          .transform(session.transformer)
          .toList();

      final total = output.fold<int>(0, (sum, c) => sum + c.length);
      expect(total, input.length);
      session.dispose();
    });
  }, skip: !dylib.existsSync() ? 'Rust dylib not built' : false);

  test('denoiseFile handles float32 WAV and preserves the sample rate',
      () async {
    final dir = await Directory.systemTemp.createTemp('nnnoiseless_test');
    final inputPath = '${dir.path}/input_f32.wav';
    final outputPath = '${dir.path}/output_f32.wav';

    final pcm = _noisySine(24000).buffer.asInt16List();
    final channel = Float64List.fromList(
      pcm.map((s) => s / 32767.0).toList(),
    );
    await Wav([channel], 24000, WavFormat.float32).writeFile(inputPath);

    await Noiseless.instance.denoiseFile(
      inputPathStr: inputPath,
      outputPathStr: outputPath,
    );

    final output = await Wav.readFile(outputPath);
    expect(output.samplesPerSecond, 24000, reason: 'rate must be preserved');
    expect(output.channels.single.length,
        closeTo(24000, 24000 * 0.05));

    await dir.delete(recursive: true);
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
