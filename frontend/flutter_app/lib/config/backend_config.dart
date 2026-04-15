import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class BackendConfig {
  static const String _hardcodedProdUrl = 'https://flowgnimag.onrender.com';
  static const String _hardcodedLocalWebUrl = 'http://localhost:5000';
  static const String _hardcodedLocalMobileUrl = 'http://10.0.2.2:5000';

  static String _normalizeUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.endsWith('/')) {
      return trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  static bool get _isRunningOnLocalWebHost {
    if (!kIsWeb) return false;
    final host = Uri.base.host.trim().toLowerCase();
    return host == 'localhost' || host == '127.0.0.1';
  }

  static String get apiBaseUrl {
    final env = dotenv.isInitialized ? dotenv.env : const <String, String>{};

    final viteBackendUrl = _normalizeUrl(
      env['VITE_BACKEND_URL'] ?? const String.fromEnvironment('VITE_BACKEND_URL'),
    );
    if (viteBackendUrl.isNotEmpty) {
      return viteBackendUrl;
    }

    final mode = (env['BACKEND_ENV'] ?? 'local').trim().toLowerCase();
    final override = _normalizeUrl(env['BACKEND_URL_OVERRIDE'] ?? '');
    final backendBaseUrl = _normalizeUrl(
      env['BACKEND_BASE_URL'] ?? const String.fromEnvironment('BACKEND_BASE_URL'),
    );
    final localWeb = _normalizeUrl(
      env['BACKEND_URL_LOCAL'] ?? _hardcodedLocalWebUrl,
    );
    final localEmulator =
        _normalizeUrl(env['BACKEND_URL_ANDROID_EMULATOR'] ?? _hardcodedLocalMobileUrl);
    final prod = _normalizeUrl(env['BACKEND_URL_PROD'] ?? _hardcodedProdUrl);

    if (override.isNotEmpty) {
      return override;
    }

    if (backendBaseUrl.isNotEmpty) {
      return backendBaseUrl;
    }

    if (mode == 'prod') {
      return prod;
    }

    if (kIsWeb) {
      if (_isRunningOnLocalWebHost) {
        return localWeb;
      }
      return prod;
    }

    if (mode == 'local') {
      return localEmulator;
    }

    return prod;
  }
}
