import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/backend_config.dart';

class AuthSession {
  final String token;
  final String refreshToken;
  final String email;
  final String name;

  const AuthSession({
    required this.token,
    required this.refreshToken,
    required this.email,
    this.name = '',
  });

  bool get isValid => token.trim().isNotEmpty && email.trim().isNotEmpty;
}

class AuthService {
  static const String cloudTokenKey = 'flowgnimag_cloud_token';
  static const String cloudRefreshTokenKey = 'flowgnimag_cloud_refresh_token';
  static const String cloudEmailKey = 'flowgnimag_cloud_email';
  static const String cloudNameKey = 'flowgnimag_cloud_name';

  static String get _apiBaseUrl => BackendConfig.apiBaseUrl;

  static Future<AuthSession?> getStoredSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = (prefs.getString(cloudTokenKey) ?? '').trim();
    final refreshToken = (prefs.getString(cloudRefreshTokenKey) ?? '').trim();
    final email = (prefs.getString(cloudEmailKey) ?? '').trim();
    final name = (prefs.getString(cloudNameKey) ?? '').trim();

    if (token.isEmpty || email.isEmpty) {
      return null;
    }

    return AuthSession(
      token: token,
      refreshToken: refreshToken,
      email: email,
      name: name,
    );
  }

  static Future<void> saveSession(AuthSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cloudTokenKey, session.token.trim());
    await prefs.setString(cloudEmailKey, session.email.trim());
    await prefs.setString(cloudNameKey, session.name.trim());
    if (session.refreshToken.trim().isNotEmpty) {
      await prefs.setString(cloudRefreshTokenKey, session.refreshToken.trim());
    }
  }

  static Future<void> clearStoredSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(cloudTokenKey);
    await prefs.remove(cloudRefreshTokenKey);
    await prefs.remove(cloudEmailKey);
    await prefs.remove(cloudNameKey);
  }

  static Future<AuthSession> signIn({
    required String email,
    required String password,
  }) {
    return _authenticate(
      path: '/auth/login',
      body: {'email': email.trim(), 'password': password},
    );
  }

  static Future<AuthSession> signUp({
    required String name,
    required String email,
    required String password,
  }) {
    return _authenticate(
      path: '/auth/signup',
      body: {'name': name.trim(), 'email': email.trim(), 'password': password},
    );
  }

  static Future<AuthSession?> restoreSession() async {
    final existing = await getStoredSession();
    if (existing == null) {
      return null;
    }

    if (existing.refreshToken.trim().isEmpty) {
      return existing;
    }

    try {
      return await refreshSession(existing.refreshToken);
    } catch (_) {
      return existing;
    }
  }

  static Future<AuthSession> refreshSession(String refreshToken) async {
    final response = await http.post(
      Uri.parse('$_apiBaseUrl/auth/refresh'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refreshToken': refreshToken.trim()}),
    );

    final data = response.body.isNotEmpty
        ? jsonDecode(response.body) as Map<String, dynamic>
        : <String, dynamic>{};

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception((data['error'] ?? 'Session refresh failed').toString());
    }

    final session = _sessionFromResponse(data);
    await saveSession(session);
    return session;
  }

  static Future<void> logout(AuthSession? session) async {
    final token = session?.token.trim() ?? '';
    final refreshToken = session?.refreshToken.trim() ?? '';

    if (token.isNotEmpty && refreshToken.isNotEmpty) {
      try {
        await http.post(
          Uri.parse('$_apiBaseUrl/auth/logout'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'refreshToken': refreshToken}),
        );
      } catch (_) {}
    }

    await clearStoredSession();
  }

  static Future<AuthSession> _authenticate({
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final response = await http.post(
      Uri.parse('$_apiBaseUrl$path'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    final data = response.body.isNotEmpty
        ? jsonDecode(response.body) as Map<String, dynamic>
        : <String, dynamic>{};

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception((data['error'] ?? 'Authentication failed').toString());
    }

    final session = _sessionFromResponse(data);
    await saveSession(session);
    return session;
  }

  static AuthSession _sessionFromResponse(Map<String, dynamic> data) {
    final token = (data['token'] ?? '').toString().trim();
    final refreshToken = (data['refreshToken'] ?? '').toString().trim();
    final user = data['user'] as Map<String, dynamic>? ?? const {};
    final email = (user['email'] ?? '').toString().trim();
    final name = (user['name'] ?? '').toString().trim();

    if (token.isEmpty || email.isEmpty) {
      throw Exception('Invalid auth response from server.');
    }

    return AuthSession(
      token: token,
      refreshToken: refreshToken,
      email: email,
      name: name,
    );
  }
}
