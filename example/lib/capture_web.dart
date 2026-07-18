import 'dart:typed_data';

/// Web stub of the demo's storage helpers: browsers have no file paths, so
/// captures are discarded and the demos that need files are hidden.

Future<String?> tempDirPath() async => null;

Future<void> writeBytes(String path, Uint8List bytes) async {}

Future<Uint8List> readBytes(String path) async => Uint8List(0);

/// A no-op capture; the web demo shows live VAD without saving audio.
class AudioCapture {
  AudioCapture(this.path);

  final String path;

  void add(List<int> bytes) {}

  Future<void> close() async {}
}
