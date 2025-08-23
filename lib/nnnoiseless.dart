import 'package:flutter/foundation.dart';
import 'package:flutter_nnnoiseless/src/rust/api/nnnoiseless.dart';
import 'package:flutter_nnnoiseless/src/rust/frb_generated.dart';
import 'package:wav/wav_file.dart';

abstract class Noiseless {

  static final Noiseless instance = _NoiselessImpl();

  Future<Uint8List> denoiseFile({
    required String inputPathStr,
    required String outputPathStr,
  });

  Future<Uint8List> denoiseInRealtime({
    required Uint8List input,
    int inputSampleRate = 48000,
  });

  Future<void> pcmToWav({
    required Uint8List pcmData,
    required String outputPath,
    int sampleRate = 48000,
    int numChannels = 1,
  });
}

class _NoiselessImpl extends Noiseless {
  bool _initialized = false;

  Future<void> init() async {
    if (!RustLib.instance.initialized) {
      _initialized = true;
      await RustLib.init();
    }
  }

  @override
  Future<Uint8List> denoiseFile({required String inputPathStr, required String outputPathStr}) async {
    if (!_initialized) await init();
    /// TODO: finish file denoising
    // return await denoise(inputPathStr: inputPathStr, outputPathStr: outputPathStr);
    return Uint8List(0);
  }

  @override
  Future<Uint8List> denoiseInRealtime({
    required Uint8List input,
    int inputSampleRate = 48000,
  }) async {
    if (!_initialized) await init();
    return await denoiseRealtime(input: input, inputSampleRate: inputSampleRate);
  }

  /// Converts a raw 16-bit PCM audio buffer to a WAV file.
  ///
  /// @param pcmData The raw audio data from your Rust function.
  /// @param sampleRate The sample rate of the audio (e.g., 48000).
  /// @param numChannels The number of audio channels (e.g., 1 for mono, 2 for stereo).
  /// @param outputPath The desired path to save the .wav file.
  @override
  Future<void> pcmToWav({
    required Uint8List pcmData,
    required String outputPath,
    int sampleRate = 48000,
    int numChannels = 1,
  }) async {
    // 1. Convert the raw byte data (Uint8List) into a list of 16-bit integers.
    // ByteData.view provides a way to read multi-byte values from a byte buffer.
    final pcm16 = pcmData.buffer.asInt16List();

    // 2. De-interleave the PCM data and normalize to the [-1.0, 1.0] range for the package.
    List<List<double>> tempChannels = List.generate(numChannels, (_) => <double>[]);
    for (int i = 0; i < pcm16.length; i++) {
      final channel = i % numChannels;
      // Normalize by dividing by the max value of an i16.
      tempChannels[channel].add(pcm16[i] / 32767.0);
    }

    final channels = tempChannels.map((channelData) => Float64List.fromList(channelData)).toList();

    // 3. Create a Wav object with the audio data and specifications.
    final wav = Wav(channels, sampleRate);

    // 4. Write the Wav object to a file.
    await wav.writeFile('$outputPath.wav');
  }
}
