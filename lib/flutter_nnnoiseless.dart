import 'package:flutter/foundation.dart';
import 'package:flutter_nnnoiseless/src/rust/api/nnnoiseless.dart' as rust;
import 'package:flutter_nnnoiseless/src/rust/frb_generated.dart';
import 'package:wav/wav_file.dart';

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
  /// and saves the cleaned audio to [outputPathStr]. It handles different
  /// audio formats and sample rates automatically.
  Future<void> denoiseFile({
    required String inputPathStr,
    required String outputPathStr,
  });

  /// Denoises a single chunk of raw audio data.
  ///
  /// This is suitable for real-time processing, such as from a microphone stream.
  /// The [input] is expected to be raw 16-bit PCM audio.
  /// The [inputSampleRate] defaults to 48000Hz, which is what the model is
  /// optimized for.
  Future<Uint8List> denoiseChunk({
    required Uint8List input,
    int inputSampleRate = 48000,
  });

  /// Converts a raw 16-bit PCM audio buffer into a WAV file.
  ///
  /// Useful for saving the output of [denoiseChunk] to a playable format.
  Future<void> pcmToWav({
    required Uint8List pcmData,
    required String outputPath,
    int sampleRate = 48000,
    int numChannels = 1,
  });
}

/// The concrete implementation of the [Noiseless] interface.
class _NoiselessImpl extends Noiseless {
  /// Initializes the underlying Rust library if it hasn't been already.
  Future<void> _ensureInitialized() async {
    if (!RustLib.instance.initialized) {
      await RustLib.init();
    }
  }

  @override
  Future<void> denoiseFile({
    required String inputPathStr,
    required String outputPathStr,
  }) async {
    await _ensureInitialized();
    return rust.denoise(
      inputPathStr: inputPathStr,
      outputPathStr: outputPathStr,
    );
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
