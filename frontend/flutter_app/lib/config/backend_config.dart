import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class BackendConfig {
  static bool get _isRunningOnLocalWebHost {
    if (!kIsWeb) return false;
    final host = Uri.base.host.trim().toLowerCase();
    return host == 'localhost' || host == '127.0.0.1';
  }

  static String get apiBaseUrl {
    final env = dotenv.isInitialized ? dotenv.env : const <String, String>{};

    final mode = (env['BACKEND_ENV'] ?? 'local').trim().toLowerCase();
    final override = (env['BACKEND_URL_OVERRIDE'] ?? '').trim();
    final localWeb = (env['BACKEND_URL_LOCAL'] ?? 'http://localhost:5000').trim();
    final localEmulator =
        (env['BACKEND_URL_ANDROID_EMULATOR'] ?? 'http://10.0.2.2:5000').trim();
    final prod = (env['BACKEND_URL_PROD'] ?? '').trim();

    if (override.isNotEmpty) {
      return override;
    }

    if (mode == 'prod' && prod.isNotEmpty) {
      return prod;
    }

    if (kIsWeb) {
      if (_isRunningOnLocalWebHost) {
        return localWeb;
      }
      if (prod.isNotEmpty) {
        return prod;
      }
      return localWeb;
    }

    return localEmulator;
  }
}
