import 'dart:async';
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final _record = AudioRecorder();
  String _tempDir = '';

  // File denoising state.
  double? _fileProgress;
  String _fileStatus = 'Denoises the bundled sample.wav with live progress.';
  NoiselessCancelToken? _fileCancelToken;

  // Real-time denoising state.
  NoiselessSession? _session;
  StreamSubscription<Uint8List>? _micSubscription;
  double _voiceProbability = 0.0;
  String _micStatus = 'Streams the microphone through a NoiselessSession.';

  @override
  void initState() {
    super.initState();
    getTemporaryDirectory().then(
      (dir) => setState(() => _tempDir = dir.path),
    );
  }

  @override
  void dispose() {
    _micSubscription?.cancel();
    _session?.dispose();
    _record.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recording = _session != null;
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_nnnoiseless demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Denoise a file',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(_fileStatus),
                  const SizedBox(height: 12),
                  if (_fileProgress != null) ...[
                    LinearProgressIndicator(value: _fileProgress),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      FilledButton(
                        onPressed: _fileProgress == null && _tempDir.isNotEmpty
                            ? _denoiseFile
                            : null,
                        child: const Text('Denoise sample.wav'),
                      ),
                      const SizedBox(width: 12),
                      if (_fileProgress != null)
                        OutlinedButton(
                          onPressed: () => _fileCancelToken?.cancel(),
                          child: const Text('Cancel'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Real-time microphone denoising',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(_micStatus),
                  const SizedBox(height: 12),
                  if (recording) ...[
                    Row(
                      children: [
                        Icon(
                          _voiceProbability >= 0.5 ? Icons.mic : Icons.mic_none,
                          color: _voiceProbability >= 0.5
                              ? Colors.teal
                              : Colors.grey,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LinearProgressIndicator(
                            value: _voiceProbability,
                            minHeight: 8,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('${(_voiceProbability * 100).round()}%'),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _voiceProbability >= 0.5 ? 'Speech detected' : 'Silence',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    onPressed: _tempDir.isEmpty
                        ? null
                        : (recording ? _stopRecording : _startRecording),
                    child: Text(recording ? 'Stop' : 'Record and denoise'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _denoiseFile() async {
    if (_tempDir.isEmpty) return;
    final token = NoiselessCancelToken();
    setState(() {
      _fileCancelToken = token;
      _fileProgress = 0.0;
      _fileStatus = 'Denoising...';
    });
    try {
      final byteData = await rootBundle.load('assets/sample.wav');
      final inputPath = path.join(_tempDir, 'sample.wav');
      final outputPath = path.join(_tempDir, 'output.wav');
      await File(inputPath).writeAsBytes(byteData.buffer.asUint8List());
      await Noiseless.instance.denoiseFile(
        inputPathStr: inputPath,
        outputPathStr: outputPath,
        cancelToken: token,
        onProgress: (fraction) => setState(() => _fileProgress = fraction),
      );
      setState(() => _fileStatus = 'Done: $outputPath');
    } on DenoiseCancelledException {
      setState(() => _fileStatus = 'Cancelled.');
    } catch (e) {
      setState(() => _fileStatus = 'Failed: $e');
    } finally {
      setState(() {
        _fileProgress = null;
        _fileCancelToken = null;
      });
    }
  }

  Future<void> _startRecording() async {
    if (!await _record.hasPermission()) {
      setState(() => _micStatus = 'Microphone permission denied.');
      return;
    }

    // Unique names per recording so a new take never clobbers files that a
    // previous recording's onDone handler is still flushing or converting.
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final rawPath = path.join(_tempDir, 'mic_raw_$stamp');
    final denoisedPath = path.join(_tempDir, 'mic_denoised_$stamp');
    final rawSink = File(rawPath).openWrite();
    final denoisedSink = File(denoisedPath).openWrite();

    /// One session per recording: it owns the denoiser state and reports a
    /// voice activity probability for every processed chunk.
    final session = await NoiselessSession.create(sampleRate: 48000);
    final stream = await _record.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 48000,
        numChannels: 1,
      ),
    );

    setState(() {
      _session = session;
      _micStatus = 'Recording... raw and denoised WAVs are saved on stop.';
    });

    // Chunk processing is serialized through a future chain so that onDone
    // can wait for every in-flight chunk before flushing and closing the
    // sinks; otherwise a still-running callback could write after close.
    var pending = Future<void>.value();
    _micSubscription = stream.listen((chunk) {
      pending = pending.then((_) async {
        if (session.isDisposed) return;
        final result = await session.process(chunk);
        rawSink.add(chunk);
        if (result.audio.isNotEmpty) denoisedSink.add(result.audio);
        if (mounted && result.voiceProbabilities.isNotEmpty) {
          setState(() => _voiceProbability = result.voiceProbability);
        }
      });
    }, onDone: () async {
      _micSubscription = null;
      await pending;
      denoisedSink.add(await session.flush());
      session.dispose();

      await rawSink.close();
      await denoisedSink.close();

      /// Convert both raw PCM captures to playable WAV files.
      await Noiseless.instance.pcmToWav(
        pcmData: await File(rawPath).readAsBytes(),
        outputPath: rawPath,
      );
      await Noiseless.instance.pcmToWav(
        pcmData: await File(denoisedPath).readAsBytes(),
        outputPath: denoisedPath,
      );

      if (mounted) {
        setState(() => _micStatus = 'Saved $rawPath.wav and $denoisedPath.wav');
      }
    });
  }

  Future<void> _stopRecording() async {
    // Stopping the recorder closes the stream; onDone then flushes the
    // session and converts the captures, so don't cancel the subscription.
    await _record.stop();
    setState(() {
      _session = null;
      _voiceProbability = 0.0;
    });
  }
}
