import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_nnnoiseless/src/rust/api/nnnoiseless.dart' as rust;
import 'package:flutter_nnnoiseless/src/rust/api/session.dart' as rust;
import 'package:flutter_nnnoiseless/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException, loadExternalLibrary;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibraryLoaderConfig;
import 'package:wav/wav_file.dart';

/// Initializes the underlying Rust library if it hasn't been already.
///
/// On web the Rust library is WebAssembly, bundled with this package and
/// served from the app's assets; everywhere else the platform build systems
/// provide the native library and the default loader finds it.
Future<void> _ensureInitialized() async {
  if (RustLib.instance.initialized) return;
  if (kIsWeb) {
    await RustLib.init(
      externalLibrary: await loadExternalLibrary(
        const ExternalLibraryLoaderConfig(
          stem: 'rust_lib_flutter_nnnoiseless',
          ioDirectory: 'rust/target/release/',
          webPrefix: 'assets/packages/flutter_nnnoiseless/web/pkg/',
        ),
      ),
    );
  } else {
    await RustLib.init();
  }
}

/// The result of processing one chunk of audio through a [NoiselessSession].
class DenoiseResult {
  const DenoiseResult._(this.audio, this.voiceProbabilities);

  /// Denoised 16-bit PCM audio at the session's sample rate, interleaved
  /// with the session's channel count.
  ///
  /// May be empty (or a different length than the input) on any single call
  /// while the session buffers samples towards full 10ms frames; timing evens
  /// out across consecutive calls.
  final Uint8List audio;

  /// Voice activity probability (0.0-1.0) for each 10ms frame processed
  /// during this call, in order. For multi-channel sessions each value is
  /// the maximum across channels for that frame.
  final Float32List voiceProbabilities;

  /// The highest voice activity probability observed in this chunk, or 0.0
  /// if no full frame was processed.
  double get voiceProbability =>
      voiceProbabilities.isEmpty ? 0.0 : voiceProbabilities.reduce(math.max);

  /// Whether this chunk likely contains speech.
  bool isVoice({double threshold = 0.5}) => voiceProbability >= threshold;
}

/// A stateful denoiser for a single audio stream.
///
/// Each session owns its own RNNoise state and resamplers, so multiple
/// sessions can run concurrently (e.g. one per microphone) and no state
/// leaks between recordings. Create with [NoiselessSession.create], feed
/// consecutive chunks to [process] (or pipe a stream through [transformer]),
/// and [dispose] when done.
///
/// ```dart
/// final session = await NoiselessSession.create(sampleRate: 16000);
/// micStream.transform(session.transformer).listen(play);
/// ```
class NoiselessSession {
  NoiselessSession._(this._session, this.sampleRate, this.channels);

  final rust.DenoiseSession _session;

  /// Sample rate of the PCM audio this session consumes and produces.
  final int sampleRate;

  /// Number of interleaved channels this session consumes and produces.
  final int channels;

  /// Creates a new denoising session.
  ///
  /// * [sampleRate] - sample rate of the raw 16-bit PCM audio passed to
  ///   [process]. Output is returned at the same rate. Rates other than
  ///   48000Hz are resampled internally (adding a small latency).
  /// * [wet] - dry/wet mix: 1.0 (default) is fully denoised, 0.0 passes the
  ///   audio through untouched. Lower it for less aggressive suppression.
  /// * [channels] - number of interleaved channels in the PCM data (1 to 8).
  ///   Each channel is denoised independently.
  /// * [model] - optional custom RNNoise model in the nnnoiseless training
  ///   format. By default the built-in general-purpose model is used.
  static Future<NoiselessSession> create({
    int sampleRate = 48000,
    double wet = 1.0,
    int channels = 1,
    Uint8List? model,
  }) async {
    await _ensureInitialized();
    return NoiselessSession._(
      await rust.DenoiseSession.create(
        sampleRate: sampleRate,
        wet: wet,
        channels: channels,
        model: model,
      ),
      sampleRate,
      channels,
    );
  }

  /// Denoises the next chunk of raw 16-bit PCM audio (interleaved if the
  /// session has more than one channel). Chunks may be split at any byte
  /// boundary; the session re-aligns samples and channels internally.
  Future<DenoiseResult> process(Uint8List input) async {
    final output = await _session.process(input: input);
    return DenoiseResult._(output.audio, output.voiceProbabilities);
  }

  /// Drains any internally buffered audio, padding with silence as needed.
  ///
  /// Call once at the end of a stream to receive the tail of the audio.
  Future<Uint8List> flush() => _session.flush();

  /// Clears all internal state so the session can be reused for a new
  /// stream without artifacts from the previous one.
  Future<void> reset() => _session.reset();

  /// Releases the native resources held by this session.
  void dispose() => _session.dispose();

  /// Whether [dispose] has been called.
  bool get isDisposed => _session.isDisposed;

  /// Denoises a raw PCM stream, yielding denoised PCM chunks.
  ///
  /// The tail of the audio (from [flush]) is emitted when [source] closes.
  Stream<Uint8List> bind(Stream<Uint8List> source) async* {
    await for (final chunk in source) {
      final result = await process(chunk);
      if (result.audio.isNotEmpty) yield result.audio;
    }
    final tail = await flush();
    if (tail.isNotEmpty) yield tail;
  }

  /// A transformer for piping a microphone stream through this session:
  /// `micStream.transform(session.transformer)`.
  StreamTransformer<Uint8List, Uint8List> get transformer =>
      StreamTransformer.fromBind(bind);
}

/// A handle for cancelling a running [Noiseless.denoiseFile] call.
///
/// Tokens are one-shot: once cancelled, a token stays cancelled forever, and
/// passing it to a new [Noiseless.denoiseFile] call fails immediately with a
/// [DenoiseCancelledException]. Create a fresh token per operation.
class NoiselessCancelToken {
  // The native token is created lazily inside denoiseFile, after the Rust
  // library is initialized, so constructing a token is always safe even as
  // the very first use of the plugin.
  rust.CancelToken? _inner;
  bool _cancelled = false;

  /// Requests cancellation. The running [Noiseless.denoiseFile] call throws
  /// a [DenoiseCancelledException] shortly after.
  void cancel() {
    _cancelled = true;
    _inner?.cancel();
  }

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// Creates or returns the native token. Only valid after RustLib init.
  rust.CancelToken _materialize() {
    final inner = _inner ??= rust.CancelToken.create();
    if (_cancelled) {
      inner.cancel();
    }
    return inner;
  }
}

/// Thrown by [Noiseless.denoiseFile] when the operation was cancelled via a
/// [NoiselessCancelToken].
class DenoiseCancelledException implements Exception {
  @override
  String toString() => 'DenoiseCancelledException: file denoising cancelled';
}

/// A Dart interface for the nnnoiseless Rust library.
///
/// Provides high-level methods for denoising audio files and real-time
/// audio chunks using a recurrent neural network.
abstract class Noiseless {
  /// The singleton instance of the [Noiseless] interface.
  static final Noiseless instance = _NoiselessImpl();

  /// Denoises an entire audio file.
  ///
  /// This function reads an audio file from [inputPathStr], processes it,
  /// and saves the cleaned audio to [outputPathStr]. Input can be WAV (any
  /// bit depth), FLAC, MP3, OGG/Vorbis, or M4A/AAC at any sample rate; the
  /// output is written as 16-bit WAV at the input's sample rate and channel
  /// count.
  ///
  /// [onProgress] is invoked with a fraction from 0.0 to 1.0 as the file is
  /// processed. Pass a [NoiselessCancelToken] as [cancelToken] to be able to
  /// abort the operation; cancellation throws a [DenoiseCancelledException].
  /// [wet] (0.0-1.0) controls suppression strength, and [model] accepts a
  /// custom RNNoise model in the nnnoiseless training format, matching the
  /// equivalent [NoiselessSession] options.
  Future<void> denoiseFile({
    required String inputPathStr,
    required String outputPathStr,
    void Function(double progress)? onProgress,
    NoiselessCancelToken? cancelToken,
    double wet = 1.0,
    Uint8List? model,
  });

  /// Denoises a single chunk of raw audio data.
  ///
  /// The [input] is expected to be raw 16-bit PCM audio.
  /// The [inputSampleRate] defaults to 48000Hz, which is what the model is
  /// optimized for. Note: output is always returned at 48000Hz.
  @Deprecated(
    'Use NoiselessSession instead: it supports multiple concurrent streams, '
    'exposes voice activity probabilities, returns audio at the input sample '
    'rate, and can be reset between recordings.',
  )
  Future<Uint8List> denoiseChunk({
    required Uint8List input,
    int inputSampleRate = 48000,
  });

  /// Converts a raw 16-bit PCM audio buffer into a WAV file.
  ///
  /// Useful for saving the output of a [NoiselessSession] to a playable
  /// format.
  Future<void> pcmToWav({
    required Uint8List pcmData,
    required String outputPath,
    int sampleRate = 48000,
    int numChannels = 1,
  });
}

/// The concrete implementation of the [Noiseless] interface.
class _NoiselessImpl extends Noiseless {
  @override
  Future<void> denoiseFile({
    required String inputPathStr,
    required String outputPathStr,
    void Function(double progress)? onProgress,
    NoiselessCancelToken? cancelToken,
    double wet = 1.0,
    Uint8List? model,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError(
        'denoiseFile is not supported on web (browsers have no file paths); '
        'use NoiselessSession to denoise audio buffers instead.',
      );
    }
    await _ensureInitialized();
    if (onProgress == null && cancelToken == null && wet == 1.0 && model == null) {
      return rust.denoise(
        inputPathStr: inputPathStr,
        outputPathStr: outputPathStr,
      );
    }
    final token = cancelToken ?? NoiselessCancelToken();
    if (token.isCancelled) {
      // Tokens are one-shot; fail deterministically instead of starting
      // native work that would abort on its first cancellation check.
      throw DenoiseCancelledException();
    }
    final progress = rust.denoiseFileWithProgress(
      inputPathStr: inputPathStr,
      outputPathStr: outputPathStr,
      wet: wet,
      model: model,
      cancelToken: token._materialize(),
    );
    try {
      await for (final fraction in progress) {
        onProgress?.call(fraction);
      }
    } on AnyhowException {
      // The token's own state decides whether this was a cancellation; the
      // message is not reliable (a file path may contain "cancelled").
      if (token.isCancelled) {
        throw DenoiseCancelledException();
      }
      rethrow;
    } catch (_) {
      // The error came from onProgress itself; stop the native work before
      // propagating so it doesn't keep running (and writing) unobserved.
      token.cancel();
      rethrow;
    }
  }

  @override
  Future<Uint8List> denoiseChunk({
    required Uint8List input,
    int inputSampleRate = 48000,
  }) async {
    await _ensureInitialized();
    return rust.denoiseChunk(input: input, inputSampleRate: inputSampleRate);
  }

  @override
  Future<void> pcmToWav({
    required Uint8List pcmData,
    required String outputPath,
    int sampleRate = 48000,
    int numChannels = 1,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError(
        'pcmToWav is not supported on web (browsers have no file paths); '
        'package:wav\'s Wav.write can produce WAV bytes for download.',
      );
    }
    // Convert the raw byte data (Uint8List) into a list of 16-bit integers.
    // ByteData.view provides a way to read multi-byte values from a byte buffer.
    final pcm16 = pcmData.buffer.asInt16List();

    // De-interleave the PCM data and normalize to the [-1.0, 1.0] range for the package.
    List<List<double>> tempChannels = List.generate(
      numChannels,
      (_) => <double>[],
    );
    for (int i = 0; i < pcm16.length; i++) {
      final channel = i % numChannels;
      double sample = pcm16[i] / 32767.0;

      // Sanitize the audio data to prevent errors with NaN or Infinity.
      if (sample.isNaN || sample.isInfinite) {
        sample = 0.0;
      }

      tempChannels[channel].add(sample);
    }

    final channels =
        tempChannels
            .map((channelData) => Float64List.fromList(channelData))
            .toList();

    // Create a Wav object with the audio data and specifications.
    final wav = Wav(channels, sampleRate);

    // Write the Wav object to a file.
    await wav.writeFile('$outputPath.wav');
  }
}
