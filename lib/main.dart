import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_nnnoiseless/src/rust/api/simple.dart';
import 'package:flutter_nnnoiseless/src/rust/frb_generated.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:record/record.dart';
import 'package:wav/wav_file.dart'; // For path manipulation

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final record = AudioRecorder();
  bool _isRecording = false;
  String _tempDir = '';

  @override
  void initState() {
    getTemporaryDirectory().then((value) => setState(() {
          _tempDir = value.path;
        }));
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('flutter_rust_bridge quickstart')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              MaterialButton(
                onPressed: _denoise,
                child: Text(
                  'Denoise audio file',
                ),
              ),
              MaterialButton(
                onPressed: _denoiseRealtime,
                child: Text('Denoise from mic'),
              ),
              if (_isRecording)
                MaterialButton(
                  onPressed: () async {
                    await record.stop();
                    setState(() {
                      _isRecording = false;
                    });
                  },
                  child: Text('Stop'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _denoise() async {
    try {
      // final tempPath = path.join(_tempDir, path.basename('assets/noise.wav'));
      final byteData = await rootBundle.load('assets/noise1.wav');

      final noiseWavPath = path.join(_tempDir, path.basename('noise1.wav'));
      final outputPath = path.join(_tempDir, path.basename('output.wav'));
      debugPrint('GGG');
      debugPrint(_tempDir);
      if (!(await File(noiseWavPath).exists())) {
        await File(noiseWavPath).writeAsBytes(byteData.buffer.asUint8List());
      }
      await denoise(inputPathStr: noiseWavPath, outputPathStr: outputPath);
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  Future<void> _denoiseRealtime() async {
    // try {
    if (await record.hasPermission()) {
      setState(() {
        _isRecording = true;
      });
      final stream = await record.startStream(
          RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 48000,
            numChannels: 1,
          ),
      );
      final outputPath = path.join(_tempDir, path.basename('output'));
      final outputRawPath = path.join(_tempDir, path.basename('output_raw'));

      if (File(outputRawPath).existsSync() || File(outputPath).existsSync()) {
        await File(outputRawPath).delete();
        await File(outputPath).delete();
      } else {
        await File(outputRawPath).create();
        await File(outputPath).create();
      }

      final rawFile = File(outputRawPath).openWrite();
      final file = File(outputPath).openWrite();

      final sub = stream.listen((event) async {
        /// REALTIME DENOISING
        final result = await denoiseRealtime(input: event);

        print('Raw: ${event.length}');
        print('Denoised: ${result.length}');

        try {
          // Save raw audio to file
          rawFile.add(event);
          // Save denoised audio
          file.add(result);
        } catch (_) {}
      });

      sub.onDone(() async {
        await sub.cancel();
        final finishedRawFile = await rawFile.close();
        final finishedFile = await file.close();

        await pcmToWav(pcmData: finishedRawFile.readAsBytesSync(), outputPath: outputRawPath);
        await pcmToWav(pcmData: finishedFile.readAsBytesSync(), outputPath: outputPath);

        debugPrint('Successfully saved audio to:\n$_tempDir');
      });

      // await stream.forEach((event) async {
      //   print(event.length);
      //   /// REALTIME DENOISING
      //   final result = await denoiseRealtime(input: event);
      //
      //   print('Result: ${result.length}');
      //
      //   // Save raw audio to file
      //   rawFile.add(event);
      //   // Save denoised audio
      //   file.add(result);
      // });
      //
      // stream.
      // await rawFile.flush();
      // await file.flush();
      //
      // final finishedRawFile = await rawFile.close();
      // final finishedFile = await file.close();

      // print(finishedRawFile.runtimeType);
      //
      // await pcmToWav(pcmData: finishedRawFile!.readAsBytesSync(), outputPath: outputRawPath);
      // await pcmToWav(pcmData: finishedFile!.readAsBytesSync(), outputPath: outputPath);
      //
      // debugPrint('Successfully saved audio to:\n$_tempDir');
    }
    // } catch (e) {
    //   debugPrint(e.toString());
    // }
  }

  /// Converts a raw 16-bit PCM audio buffer to a WAV file.
  ///
  /// @param pcmData The raw audio data from your Rust function.
  /// @param sampleRate The sample rate of the audio (e.g., 48000).
  /// @param numChannels The number of audio channels (e.g., 1 for mono, 2 for stereo).
  /// @param outputPath The desired path to save the .wav file.
  Future<void> pcmToWav({
    required Uint8List pcmData,
    required String outputPath,
    int sampleRate = 48000,
    int numChannels = 1,
  }) async {
    // 1. Convert the raw byte data (Uint8List) into a list of 16-bit integers.
    // ByteData.view provides a way to read multi-byte values from a byte buffer.
    final pcm16 = record.convertBytesToInt16(pcmData);

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

    print(outputPath);

    // 4. Write the Wav object to a file.
    await wav.writeFile('$outputPath.wav');

    print('WAV file saved to: $outputPath.wav');
  }
}
