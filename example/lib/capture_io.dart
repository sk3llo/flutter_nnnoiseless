import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Native implementation of the demo's storage helpers.

Future<String?> tempDirPath() async => (await getTemporaryDirectory()).path;

Future<void> writeBytes(String path, Uint8List bytes) =>
    File(path).writeAsBytes(bytes);

Future<Uint8List> readBytes(String path) => File(path).readAsBytes();

/// An append-only capture of raw audio bytes backed by a file.
class AudioCapture {
  AudioCapture(this.path) : _sink = File(path).openWrite();

  final String path;
  final IOSink _sink;

  void add(List<int> bytes) => _sink.add(bytes);

  Future<void> close() => _sink.close();
}
