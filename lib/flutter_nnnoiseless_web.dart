import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Web plugin registration for flutter_nnnoiseless.
///
/// The plugin has no method channels: on web the Rust library runs as
/// WebAssembly loaded from the package's bundled assets. This class exists
/// only so Flutter recognizes web as a supported platform.
class FlutterNnnoiselessWeb {
  static void registerWith(Registrar registrar) {}
}
