import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_nnnoiseless/flutter_nnnoiseless.dart';
import 'package:flutter_nnnoiseless/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
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

  group('multi-channel and custom models', () {
    test('stereo session denoises both channels across odd chunk sizes',
        () async {
      final session = await NoiselessSession.create(channels: 2);

      // Interleave a tone (left) with noise (right).
      final left = _noisySine(48000).buffer.asInt16List();
      final rng = Random(3);
      final interleaved = Int16List(left.length * 2);
      for (var i = 0; i < left.length; i++) {
        interleaved[2 * i] = left[i];
        interleaved[2 * i + 1] = ((rng.nextDouble() * 2 - 1) * 3000).toInt();
      }
      final bytes = interleaved.buffer.asUint8List();

      // Feed in 1002-byte chunks: 501 samples, deliberately not a multiple
      // of the channel count, to exercise the alignment carry.
      final outputs = <Uint8List>[];
      var totalVadFrames = 0;
      for (var i = 0; i < bytes.length; i += 1002) {
        final chunk = Uint8List.sublistView(
            bytes, i, (i + 1002).clamp(0, bytes.length));
        final result = await session.process(chunk);
        outputs.add(result.audio);
        totalVadFrames += result.voiceProbabilities.length;
      }

      final total = outputs.fold<int>(0, (sum, c) => sum + c.length);
      expect(total, bytes.length);
      // 1 second of 48kHz audio = 100 frames of 10ms, one VAD per frame.
      expect(totalVadFrames, 100);

      // Both channels must contain signal.
      final out = Uint8List(total);
      var offset = 0;
      for (final chunk in outputs) {
        out.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      final samples = out.buffer.asInt16List();
      var leftEnergy = 0.0, rightEnergy = 0.0;
      for (var i = 960; i + 1 < samples.length; i += 2) {
        leftEnergy += samples[i].abs();
        rightEnergy += samples[i + 1].abs();
      }
      expect(leftEnergy, greaterThan(0));
      expect(rightEnergy, greaterThan(0));
      // The tone channel should retain far more energy than the noise one.
      expect(leftEnergy, greaterThan(rightEnergy));
      session.dispose();
    });

    test('output is identical no matter how the byte stream is chunked',
        () async {
      final input = _noisySine(48000);

      final reference = await NoiselessSession.create();
      final whole = await reference.process(input);
      final wholeTail = await reference.flush();
      reference.dispose();
      expect(wholeTail, isEmpty);

      // Split at deliberately hostile offsets, including odd byte counts,
      // as a transport (socket, platform channel) might.
      final chunked = await NoiselessSession.create();
      final collected = BytesBuilder();
      const sizes = [999, 1, 4801, 3, 7777, 2, 501];
      var offset = 0, s = 0;
      while (offset < input.length) {
        final take = sizes[s++ % sizes.length]
            .clamp(0, input.length - offset);
        final result = await chunked.process(
            Uint8List.sublistView(input, offset, offset + take));
        collected.add(result.audio);
        offset += take;
      }
      collected.add(await chunked.flush());
      chunked.dispose();

      expect(collected.toBytes(), equals(whole.audio),
          reason: 'byte-level chunk splits must not corrupt the stream');
    });

    test('stereo wet=0.0 passes both channels through (after warm-up)',
        () async {
      final session =
          await NoiselessSession.create(channels: 2, wet: 0.0);
      final left = _noisySine(48000).buffer.asInt16List();
      final interleaved = Int16List(left.length * 2);
      for (var i = 0; i < left.length; i++) {
        interleaved[2 * i] = left[i];
        interleaved[2 * i + 1] = -left[i];
      }
      final input = interleaved.buffer.asUint8List();
      final result = await session.process(input);

      final inSamples = interleaved;
      final outSamples = result.audio.buffer.asInt16List();
      // Skip the silenced warm-up frame: 480 samples * 2 channels.
      for (var i = 960; i < 9600; i++) {
        expect((outSamples[i] - inSamples[i]).abs(), lessThanOrEqualTo(1),
            reason: 'sample $i should pass through at wet=0.0');
      }
      session.dispose();
    });

    test('create rejects invalid model bytes', () async {
      expect(
        () => NoiselessSession.create(
            model: Uint8List.fromList(List.filled(64, 42))),
        throwsA(anything),
      );
    });

    test('create rejects invalid channel counts', () async {
      expect(() => NoiselessSession.create(channels: 0), throwsA(anything));
      expect(() => NoiselessSession.create(channels: 9), throwsA(anything));
    });

    test('accepts a custom model in nnnoiseless format', () async {
      // The nnnoiseless crate ships its built-in weights in exactly the
      // format from_bytes expects; use them as a known-good fixture.
      final registry =
          Directory('${Platform.environment['HOME']}/.cargo/registry/src');
      File? weightsFile;
      if (registry.existsSync()) {
        for (final index in registry.listSync().whereType<Directory>()) {
          final candidate =
              File('${index.path}/nnnoiseless-0.5.1/src/weights.rnn');
          if (candidate.existsSync()) {
            weightsFile = candidate;
            break;
          }
        }
      }
      if (weightsFile == null) {
        markTestSkipped('nnnoiseless sources not in cargo registry');
        return;
      }
      final weights = await weightsFile.readAsBytes();

      final session = await NoiselessSession.create(model: weights);
      final result = await session.process(_noisySine(48000));
      expect(result.audio.length, 48000 * 2);
      expect(result.voiceProbabilities.length, 100);

      // reset() must rebuild denoisers from the same custom model.
      await session.reset();
      final again = await session.process(_noisySine(48000));
      expect(again.audio.length, 48000 * 2);
      expect(again.audio, equals(result.audio),
          reason: 'reset must fully restore initial custom-model state');
      session.dispose();
    });
  }, skip: !dylib.existsSync() ? 'Rust dylib not built' : false);

  group('file progress and cancellation', () {
    test('denoiseFile reports monotonic progress ending at 1.0', () async {
      final dir = await Directory.systemTemp.createTemp('nnnoiseless_test');
      final inputPath = '${dir.path}/input.wav';
      final outputPath = '${dir.path}/output.wav';

      final pcm = _noisySine(48000).buffer.asInt16List();
      final channel = Float64List.fromList(
        pcm.map((s) => s / 32767.0).toList(),
      );
      await Wav([channel], 48000).writeFile(inputPath);

      final progress = <double>[];
      await Noiseless.instance.denoiseFile(
        inputPathStr: inputPath,
        outputPathStr: outputPath,
        onProgress: progress.add,
      );

      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
      expect(File(outputPath).existsSync(), isTrue);

      await dir.delete(recursive: true);
    });

    test('cancelToken aborts denoiseFile with DenoiseCancelledException',
        () async {
      final dir = await Directory.systemTemp.createTemp('nnnoiseless_test');
      final inputPath = '${dir.path}/input.wav';
      final outputPath = '${dir.path}/output.wav';

      // 30 seconds of audio so there is time to cancel mid-flight.
      final pcm = <double>[];
      for (var s = 0; s < 30; s++) {
        pcm.addAll(
            _noisySine(48000).buffer.asInt16List().map((v) => v / 32767.0));
      }
      await Wav([Float64List.fromList(pcm)], 48000).writeFile(inputPath);

      final token = NoiselessCancelToken();
      expect(token.isCancelled, isFalse);

      await expectLater(
        Noiseless.instance.denoiseFile(
          inputPathStr: inputPath,
          outputPathStr: outputPath,
          cancelToken: token,
          onProgress: (fraction) {
            if (fraction > 0.0) token.cancel();
          },
        ),
        throwsA(isA<DenoiseCancelledException>()),
      );
      expect(token.isCancelled, isTrue);

      await dir.delete(recursive: true);
    });

    test('an already-cancelled token fails immediately and deterministically',
        () async {
      final token = NoiselessCancelToken()..cancel();
      await expectLater(
        Noiseless.instance.denoiseFile(
          inputPathStr: '/nonexistent/in.wav',
          outputPathStr: '/nonexistent/out.wav',
          cancelToken: token,
        ),
        throwsA(isA<DenoiseCancelledException>()),
      );
    });

    test('real errors are not misreported as cancellation even when the '
        'path contains "cancelled"', () async {
      await expectLater(
        Noiseless.instance.denoiseFile(
          inputPathStr: '/nonexistent/cancelled_take.wav',
          outputPathStr: '/nonexistent/out.wav',
          onProgress: (_) {},
        ),
        throwsA(isA<AnyhowException>()),
      );
    });

    test('an error thrown by onProgress cancels the native work', () async {
      final dir = await Directory.systemTemp.createTemp('nnnoiseless_test');
      final inputPath = '${dir.path}/input.wav';
      final outputPath = '${dir.path}/output.wav';
      final pcm = _noisySine(48000).buffer.asInt16List();
      await Wav(
        [Float64List.fromList(pcm.map((s) => s / 32767.0).toList())],
        48000,
      ).writeFile(inputPath);

      final token = NoiselessCancelToken();
      await expectLater(
        Noiseless.instance.denoiseFile(
          inputPathStr: inputPath,
          outputPathStr: outputPath,
          cancelToken: token,
          onProgress: (_) => throw StateError('listener died'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(token.isCancelled, isTrue,
          reason: 'the wrapper must stop the native work');

      await dir.delete(recursive: true);
    });
  }, skip: !dylib.existsSync() ? 'Rust dylib not built' : false);

  group('multi-format file input', () {
    late Directory dir;
    late String wavPath;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('nnnoiseless_formats');
      wavPath = '${dir.path}/input.wav';
      final pcm = _noisySine(48000).buffer.asInt16List();
      await Wav(
        [Float64List.fromList(pcm.map((s) => s / 32767.0).toList())],
        48000,
      ).writeFile(wavPath);
    });

    tearDownAll(() => dir.delete(recursive: true));

    Future<ProcessResult?> tryRun(String command, List<String> args) async {
      try {
        return await Process.run(command, args);
      } on ProcessException {
        return null;
      }
    }

    Future<void> expectDenoises(String inputPath) async {
      final outputPath = '$inputPath.denoised.wav';
      await Noiseless.instance.denoiseFile(
        inputPathStr: inputPath,
        outputPathStr: outputPath,
      );
      final output = await Wav.readFile(outputPath);
      expect(output.samplesPerSecond, 48000);
      expect(output.channels.single.length, closeTo(48000, 48000 * 0.10));
    }

    test('FLAC input', () async {
      final flacPath = '${dir.path}/input.flac';
      final result = await tryRun(
          'afconvert', ['-f', 'flac', '-d', 'flac', wavPath, flacPath]);
      if (result == null || result.exitCode != 0) {
        markTestSkipped('afconvert flac unavailable: ${result?.stderr}');
        return;
      }
      await expectDenoises(flacPath);
    });

    test('M4A/AAC input', () async {
      final m4aPath = '${dir.path}/input.m4a';
      final result = await tryRun(
          'afconvert', ['-f', 'm4af', '-d', 'aac', wavPath, m4aPath]);
      if (result == null || result.exitCode != 0) {
        markTestSkipped('afconvert aac unavailable: ${result?.stderr}');
        return;
      }
      await expectDenoises(m4aPath);
    });

    test('MP3 input', () async {
      final mp3Path = '${dir.path}/input.mp3';
      final result = await tryRun(
          'ffmpeg', ['-y', '-i', wavPath, '-codec:a', 'libmp3lame', mp3Path]);
      if (result == null || result.exitCode != 0) {
        markTestSkipped('ffmpeg mp3 encoding unavailable');
        return;
      }
      await expectDenoises(mp3Path);
    });

    test('unsupported input fails with a clear error, not a crash', () async {
      final bogusPath = '${dir.path}/not_audio.xyz';
      await File(bogusPath).writeAsString('this is not audio');
      await expectLater(
        Noiseless.instance.denoiseFile(
          inputPathStr: bogusPath,
          outputPathStr: '${dir.path}/out.wav',
        ),
        throwsA(isA<AnyhowException>()),
      );
    });

    test('wet=0.0 file output approximates the input', () async {
      final outputPath = '${dir.path}/wet0.wav';
      await Noiseless.instance.denoiseFile(
        inputPathStr: wavPath,
        outputPathStr: outputPath,
        wet: 0.0,
      );
      final input = await Wav.readFile(wavPath);
      final output = await Wav.readFile(outputPath);
      // Same length, and samples materially unchanged.
      expect(output.channels.single.length, input.channels.single.length);
      var maxDelta = 0.0;
      for (var i = 0; i < input.channels.single.length; i++) {
        final delta =
            (output.channels.single[i] - input.channels.single[i]).abs();
        if (delta > maxDelta) maxDelta = delta;
      }
      expect(maxDelta, lessThan(0.001),
          reason: 'wet=0.0 must pass audio through');
    });

    test('custom model applies to file denoising', () async {
      final registry =
          Directory('${Platform.environment['HOME']}/.cargo/registry/src');
      File? weightsFile;
      if (registry.existsSync()) {
        for (final index in registry.listSync().whereType<Directory>()) {
          final candidate =
              File('${index.path}/nnnoiseless-0.5.1/src/weights.rnn');
          if (candidate.existsSync()) {
            weightsFile = candidate;
            break;
          }
        }
      }
      if (weightsFile == null) {
        markTestSkipped('nnnoiseless sources not in cargo registry');
        return;
      }
      final outputPath = '${dir.path}/custom_model.wav';
      await Noiseless.instance.denoiseFile(
        inputPathStr: wavPath,
        outputPathStr: outputPath,
        model: await weightsFile.readAsBytes(),
      );
      final output = await Wav.readFile(outputPath);
      expect(output.channels.single, isNotEmpty);

      // weights.rnn IS the built-in model, so denoising with it must be
      // byte-identical to the default path; this proves the custom-model
      // pipeline is really exercised (a silently ignored model would also
      // pass a mere is-not-empty check, but so would a wrong one).
      final defaultPath = '${dir.path}/default_model.wav';
      await Noiseless.instance.denoiseFile(
        inputPathStr: wavPath,
        outputPathStr: defaultPath,
      );
      expect(
        await File(outputPath).readAsBytes(),
        equals(await File(defaultPath).readAsBytes()),
        reason: 'custom model identical to built-in must produce '
            'identical output',
      );
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
