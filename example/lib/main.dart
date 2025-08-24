import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_nnnoiseless/flutter_nnnoiseless.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

Future<void> main() async {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final record = AudioRecorder();
  final noiseless = Noiseless.instance;
  bool _isRecording = false;
  String _tempDir = '';

  @override
  void initState() {
    getTemporaryDirectory().then(
      (value) => setState(() {
        _tempDir = value.path;
      }),
    );
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
                child: Text('Denoise audio file'),
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
      final byteData = await rootBundle.load('assets/sample.wav');
      final noiseWavPath = path.join(_tempDir, path.basename('sample.wav'));
      final outputPath = path.join(_tempDir, path.basename('output.wav'));
      if (!(await File(noiseWavPath).exists())) {
        await File(noiseWavPath).writeAsBytes(byteData.buffer.asUint8List());
      }
      await noiseless.denoiseFile(
        inputPathStr: noiseWavPath,
        outputPathStr: outputPath,
      );
      debugPrint('Successfully denoised to: $outputPath');
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  Future<void> _denoiseRealtime() async {
    try {
      if (await record.hasPermission()) {
        setState(() {
          _isRecording = true;
        });

        /// Start recording
        final stream = await record.startStream(
          RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 48000,
            numChannels: 1,
          ),
        );
        final outputPath = path.join(_tempDir, path.basename('output'));
        final outputRawPath = path.join(_tempDir, path.basename('output_raw'));

        /// Manage output files
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
          /// Realtime chunk denoising
          final result = await noiseless.denoiseChunk(input: event);

          try {
            /// Save raw audio for comparison
            rawFile.add(event);

            /// Save denoised audio
            file.add(result);
          } catch (_) {}
        });

        sub.onDone(() async {
          await sub.cancel();
          final finishedRawFile = await rawFile.close();
          final finishedFile = await file.close();

          /// Convert to wav
          await noiseless.pcmToWav(
            pcmData: finishedRawFile.readAsBytesSync(),
            outputPath: outputRawPath,
          );
          await noiseless.pcmToWav(
            pcmData: finishedFile.readAsBytesSync(),
            outputPath: outputPath,
          );

          debugPrint('Successfully saved audio to:\n$_tempDir');
        });
      }
    } catch (e) {
      debugPrint(e.toString());
    }
  }
}
