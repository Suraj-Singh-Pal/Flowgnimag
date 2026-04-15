import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/backend_config.dart';
import '../services/auth_service.dart';
import '../services/pulseiq_service.dart';
import 'auth_screen.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback toggleTheme;

  const SettingsScreen({super.key, required this.toggleTheme});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _legacyChatKey = 'flowgnimag_chat';
  static const String _chatSessionsKey = 'flowgnimag_chat_sessions_v2';
  static const String _activeChatIdKey = 'flowgnimag_active_chat_id_v2';
  static const String _notesKey = 'flowgnimag_notes';
  static const String _tasksKey = 'flowgnimag_tasks';
  static const String _voiceKey = 'flowgnimag_voice_enabled';
  static const String _autoSpeakKey = 'flowgnimag_auto_speak';
  static const String _smartReplyKey = 'flowgnimag_smart_reply';
  static const String _showWelcomeKey = 'flowgnimag_show_welcome';
  bool isLoading = true;
  bool isSyncing = false;
  bool voiceEnabled = true;
  bool autoSpeak = true;
  bool smartReply = true;
  bool showWelcome = true;
  String cloudName = '';
  String cloudToken = '';
  String cloudRefreshToken = '';
  String cloudEmail = '';
  bool googleConfigured = false;
  bool googleConnected = false;
  bool isGoogleLoading = false;
  bool isPushLoading = false;
  bool fcmConfigured = false;
  bool firebaseAdminReady = false;
  bool androidGoogleServicesPresent = false;
  bool iosGoogleServiceInfoPresent = false;
  int pushDeviceCount = 0;
  String localPushTokenPreview = '';
  String pushDoctorSummary = '';
  List<String> pushDoctorMissing = [];
  List<String> pushDoctorActions = [];
  String pushSelfTestResult = '';
  String googleExpiryAt = '';
  String googleScope = '';
  String googleProfileEmail = '';
  String googleProfileName = '';
  List<Map<String, dynamic>> googleUpcomingEvents = [];
  List<Map<String, dynamic>> googleRecentEmails = [];
  List<Map<String, dynamic>> googleContacts = [];

  String get apiBaseUrl {
    return BackendConfig.apiBaseUrl;
  }

  bool get isCloudConnected => cloudToken.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    loadSettings();
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) return;

    setState(() {
      voiceEnabled = prefs.getBool(_voiceKey) ?? true;
      autoSpeak = prefs.getBool(_autoSpeakKey) ?? true;
      smartReply = prefs.getBool(_smartReplyKey) ?? true;
      showWelcome = prefs.getBool(_showWelcomeKey) ?? true;
      cloudName = prefs.getString(AuthService.cloudNameKey) ?? '';
      cloudToken = prefs.getString(AuthService.cloudTokenKey) ?? '';
      cloudRefreshToken =
          prefs.getString(AuthService.cloudRefreshTokenKey) ?? '';
      cloudEmail = prefs.getString(AuthService.cloudEmailKey) ?? '';
      isLoading = false;
    });

    if (cloudToken.trim().isNotEmpty) {
      await refreshGoogleCalendarStatus();
      await refreshPushStatus();
    }
  }

  Future<void> saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> saveCloudSession(
    String token,
    String email, {
    String name = '',
    String refreshToken = '',
  }) async {
    final existing = await AuthService.getStoredSession();
    final resolvedName = name.trim().isNotEmpty
        ? name.trim()
        : existing?.name ?? '';
    await AuthService.saveSession(
      AuthSession(
        token: token,
        refreshToken: refreshToken.trim().isNotEmpty
            ? refreshToken.trim()
            : existing?.refreshToken ?? '',
        email: email,
        name: resolvedName,
      ),
    );
    if (!mounted) return;
    setState(() {
      cloudName = resolvedName;
      cloudToken = token;
      if (refreshToken.trim().isNotEmpty) {
        cloudRefreshToken = refreshToken.trim();
      }
      cloudEmail = email;
    });

    await PulseIQService.identify(email);
    await PulseIQService.track('login_success', {
      'channel': 'cloud_email_password',
      'email_domain': email.contains('@') ? email.split('@').last : 'unknown',
    });

    if (!kIsWeb) {
      try {
        final pushToken = await FirebaseMessaging.instance.getToken();
        if (pushToken != null && pushToken.trim().isNotEmpty) {
          await registerPushTokenForCloudSession(
            token: pushToken,
            authToken: token,
          );
        }
      } catch (_) {}
    }

    await refreshGoogleCalendarStatus();
    await refreshPushStatus();
    await runPushDoctor(showToast: false);
  }

  Future<void> clearCloudSession() async {
    final existingToken = cloudToken.trim();
    final existingRefresh = cloudRefreshToken.trim();
    if (existingToken.isNotEmpty && !kIsWeb) {
      try {
        final pushToken = await FirebaseMessaging.instance.getToken();
        if (pushToken != null && pushToken.trim().isNotEmpty) {
          await http.post(
            Uri.parse("$apiBaseUrl/notifications/unregister"),
            headers: {
              "Authorization": "Bearer $existingToken",
              "Content-Type": "application/json",
            },
            body: jsonEncode({"token": pushToken.trim()}),
          );
        }
      } catch (_) {}
    }

    if (existingToken.isNotEmpty && existingRefresh.isNotEmpty) {
      try {
        await http.post(
          Uri.parse("$apiBaseUrl/auth/logout"),
          headers: {
            "Authorization": "Bearer $existingToken",
            "Content-Type": "application/json",
          },
          body: jsonEncode({"refreshToken": existingRefresh}),
        );
      } catch (_) {}
    }

    await AuthService.clearStoredSession();
    await PulseIQService.clearIdentity();
    if (!mounted) return;
    setState(() {
      cloudName = '';
      cloudToken = '';
      cloudRefreshToken = '';
      cloudEmail = '';
      googleConfigured = false;
      googleConnected = false;
      isPushLoading = false;
      fcmConfigured = false;
      firebaseAdminReady = false;
      androidGoogleServicesPresent = false;
      iosGoogleServiceInfoPresent = false;
      pushDeviceCount = 0;
      localPushTokenPreview = '';
      pushDoctorSummary = '';
      pushDoctorMissing = [];
      pushDoctorActions = [];
      pushSelfTestResult = '';
      googleExpiryAt = '';
      googleScope = '';
      googleProfileEmail = '';
      googleProfileName = '';
      googleUpcomingEvents = [];
      googleRecentEmails = [];
      googleContacts = [];
    });

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'AuthScreen'),
        builder: (_) => AuthScreen(toggleTheme: widget.toggleTheme),
      ),
      (route) => false,
    );
  }

  Map<String, String> get _authHeaders => {
    "Authorization": "Bearer $cloudToken",
    "Content-Type": "application/json",
  };

  Future<bool> _refreshCloudAccessToken() async {
    final refresh = cloudRefreshToken.trim();
    if (refresh.isEmpty) {
      return false;
    }

    try {
      final response = await http.post(
        Uri.parse("$apiBaseUrl/auth/refresh"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"refreshToken": refresh}),
      );
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }

      final token = (data["token"] ?? "").toString().trim();
      final nextRefresh = (data["refreshToken"] ?? "").toString().trim();
      final user = data["user"] as Map<String, dynamic>? ?? const {};
      final email = (user["email"] ?? cloudEmail).toString().trim();
      final name = (user["name"] ?? cloudName).toString().trim();
      if (token.isEmpty || email.isEmpty) {
        return false;
      }

      await saveCloudSession(
        token,
        email,
        name: name,
        refreshToken: nextRefresh.isNotEmpty ? nextRefresh : refresh,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<http.Response> _authedGet(String path, {bool retried = false}) async {
    final response = await http.get(
      Uri.parse("$apiBaseUrl$path"),
      headers: _authHeaders,
    );
    if (response.statusCode == 401 && !retried) {
      final ok = await _refreshCloudAccessToken();
      if (ok) {
        return _authedGet(path, retried: true);
      }
    }
    return response;
  }

  Future<http.Response> _authedPost(
    String path, {
    Map<String, dynamic>? body,
    bool retried = false,
  }) async {
    final response = await http.post(
      Uri.parse("$apiBaseUrl$path"),
      headers: _authHeaders,
      body: body == null ? null : jsonEncode(body),
    );
    if (response.statusCode == 401 && !retried) {
      final ok = await _refreshCloudAccessToken();
      if (ok) {
        return _authedPost(path, body: body, retried: true);
      }
    }
    return response;
  }

  Future<http.Response> _authedPatch(
    String path, {
    Map<String, dynamic>? body,
    bool retried = false,
  }) async {
    final response = await http.patch(
      Uri.parse("$apiBaseUrl$path"),
      headers: _authHeaders,
      body: body == null ? null : jsonEncode(body),
    );
    if (response.statusCode == 401 && !retried) {
      final ok = await _refreshCloudAccessToken();
      if (ok) {
        return _authedPatch(path, body: body, retried: true);
      }
    }
    return response;
  }

  Future<http.Response> _authedDelete(
    String path, {
    bool retried = false,
  }) async {
    final response = await http.delete(
      Uri.parse("$apiBaseUrl$path"),
      headers: _authHeaders,
    );
    if (response.statusCode == 401 && !retried) {
      final ok = await _refreshCloudAccessToken();
      if (ok) {
        return _authedDelete(path, retried: true);
      }
    }
    return response;
  }

  String _devicePlatformLabel() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  Future<void> registerPushTokenForCloudSession({
    required String token,
    required String authToken,
  }) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty || authToken.trim().isEmpty) {
      return;
    }

    try {
      await http.post(
        Uri.parse("$apiBaseUrl/notifications/register"),
        headers: {
          "Authorization": "Bearer $authToken",
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "token": cleanToken,
          "platform": _devicePlatformLabel(),
        }),
      );
    } catch (_) {}
  }

  void showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> refreshGoogleCalendarStatus({bool showToast = false}) async {
    if (!isCloudConnected) {
      if (!mounted) return;
      setState(() {
        googleConfigured = false;
        googleConnected = false;
        googleExpiryAt = '';
        googleScope = '';
      });
      return;
    }

    if (mounted) {
      setState(() => isGoogleLoading = true);
    }

    try {
      final response = await _authedGet("/integrations/google/status");
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          googleConfigured = data["configured"] == true;
          googleConnected = data["connected"] == true;
          googleExpiryAt = (data["expiresAt"] ?? "").toString();
          googleScope = (data["scope"] ?? "").toString();
        });
        if (showToast) {
          showSnack(
            googleConnected
                ? "Google Calendar connected."
                : "Google Calendar not connected.",
          );
        }
      } else if (showToast) {
        showSnack((data["error"] ?? "Google status fetch failed").toString());
      }
    } catch (_) {
      if (showToast) {
        showSnack("Could not fetch Google Calendar status.");
      }
    } finally {
      if (mounted) {
        setState(() => isGoogleLoading = false);
      }
    }
  }

  Future<void> connectGoogleCalendar() async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    setState(() => isGoogleLoading = true);
    try {
      final response = await _authedGet("/integrations/google/url");
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final authUrl = (data["url"] ?? "").toString();
        if (authUrl.isEmpty) {
          showSnack("Google auth URL missing.");
        } else {
          final ok = await launchUrl(
            Uri.parse(authUrl),
            mode: LaunchMode.externalApplication,
          );
          if (!ok) {
            showSnack("Could not open Google auth link.");
          } else {
            showSnack("Complete login in browser, then tap Refresh Status.");
          }
        }
      } else {
        showSnack((data["error"] ?? "Google connect failed").toString());
      }
    } catch (_) {
      showSnack("Google connect failed.");
    } finally {
      if (mounted) {
        setState(() => isGoogleLoading = false);
      }
    }
  }

  Future<void> refreshPushStatus({bool showToast = false}) async {
    if (!isCloudConnected) {
      if (!mounted) return;
      setState(() {
        fcmConfigured = false;
        firebaseAdminReady = false;
        androidGoogleServicesPresent = false;
        iosGoogleServiceInfoPresent = false;
        pushDeviceCount = 0;
        localPushTokenPreview = '';
        pushDoctorSummary = '';
        pushDoctorMissing = [];
        pushDoctorActions = [];
        pushSelfTestResult = '';
      });
      return;
    }

    if (mounted) {
      setState(() => isPushLoading = true);
    }

    try {
      String tokenPreview = '';
      if (!kIsWeb) {
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null && token.trim().isNotEmpty) {
          final clean = token.trim();
          tokenPreview = clean.length <= 22
              ? clean
              : '${clean.substring(0, 10)}...${clean.substring(clean.length - 8)}';
        }
      }

      final response = await _authedGet("/notifications/status");
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final files =
            (data["firebaseFiles"] as Map<String, dynamic>?) ??
            <String, dynamic>{};
        setState(() {
          fcmConfigured = data["fcmConfigured"] == true;
          firebaseAdminReady = data["firebaseAdminReady"] == true;
          androidGoogleServicesPresent =
              files["androidGoogleServicesPresent"] == true;
          iosGoogleServiceInfoPresent =
              files["iosGoogleServiceInfoPresent"] == true;
          pushDeviceCount = (data["deviceCount"] as num?)?.toInt() ?? 0;
          localPushTokenPreview = tokenPreview;
        });
        if (showToast) {
          showSnack(
            "Push status: devices=$pushDeviceCount, backend ${fcmConfigured ? "configured" : "not configured"}.",
          );
        }
      } else if (showToast) {
        showSnack((data["error"] ?? "Push status fetch failed").toString());
      }
    } catch (_) {
      if (showToast) {
        showSnack("Could not fetch push notification status.");
      }
    } finally {
      if (mounted) {
        setState(() => isPushLoading = false);
      }
    }
  }

  Future<void> sendPushTestFromSettings() async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    setState(() => isPushLoading = true);
    try {
      final response = await _authedPost(
        "/notifications/test",
        body: {
          "title": "FLOWGNIMAG Push Test",
          "body": "Push pipeline is active on this device.",
        },
      );

      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final sent = (data["sent"] as num?)?.toInt() ?? 0;
        final invalid = (data["invalid"] as num?)?.toInt() ?? 0;
        showSnack("Push test sent=$sent invalid=$invalid");
        await refreshPushStatus();
      } else {
        showSnack((data["error"] ?? "Push test failed").toString());
      }
    } catch (_) {
      showSnack("Push test failed.");
    } finally {
      if (mounted) {
        setState(() => isPushLoading = false);
      }
    }
  }

  Future<void> runPushDoctor({bool showToast = true}) async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    setState(() => isPushLoading = true);
    try {
      final response = await _authedGet("/notifications/doctor");

      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final summary = (data["summary"] ?? "").toString();
        final missingRaw = (data["missing"] as List<dynamic>? ?? const []);
        final actionsRaw =
            (data["recommendedActions"] as List<dynamic>? ?? const []);
        final missing = missingRaw
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList();
        final actions = actionsRaw
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList();
        if (!mounted) return;
        setState(() {
          pushDoctorSummary = summary;
          pushDoctorMissing = missing;
          pushDoctorActions = actions;
        });
        if (showToast) {
          showSnack(summary.isEmpty ? "Push doctor complete." : summary);
        }
      } else {
        final errorText = (data["error"] ?? "Push doctor failed").toString();
        if (showToast) {
          showSnack(errorText);
        }
      }
    } catch (_) {
      if (showToast) {
        showSnack("Push doctor failed.");
      }
    } finally {
      if (mounted) {
        setState(() => isPushLoading = false);
      }
    }
  }

  Future<void> runFullPushSelfTest() async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    setState(() => isPushLoading = true);
    try {
      final response = await _authedPost(
        "/notifications/self-test",
        body: {
          "title": "FLOWGNIMAG Full Self-Test",
          "body": "Diagnostics passed and push test was dispatched.",
        },
      );
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      final summary = (data["summary"] ?? "").toString();
      final missingRaw = (data["missing"] as List<dynamic>? ?? const []);
      final actionsRaw =
          (data["recommendedActions"] as List<dynamic>? ?? const []);
      final missing = missingRaw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList();
      final actions = actionsRaw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList();

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final sent = (data["sent"] as num?)?.toInt() ?? 0;
        final invalid = (data["invalid"] as num?)?.toInt() ?? 0;
        setState(() {
          pushDoctorSummary = summary;
          pushDoctorMissing = missing;
          pushDoctorActions = actions;
          pushSelfTestResult = "Self-test sent=$sent invalid=$invalid";
        });
        showSnack(pushSelfTestResult);
        await refreshPushStatus();
      } else {
        final errorText = (data["error"] ?? "Push self-test failed").toString();
        setState(() {
          pushDoctorSummary = summary;
          pushDoctorMissing = missing;
          pushDoctorActions = actions;
          pushSelfTestResult = errorText;
        });
        showSnack(errorText);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        pushSelfTestResult = "Push self-test failed.";
      });
      showSnack("Push self-test failed.");
    } finally {
      if (mounted) {
        setState(() => isPushLoading = false);
      }
    }
  }

  Future<void> copyFcmEnvTemplate() async {
    const template = '''
FIREBASE_PROJECT_ID=your-project-id
FIREBASE_CLIENT_EMAIL=firebase-adminsdk-xxx@your-project-id.iam.gserviceaccount.com
FIREBASE_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----\\nYOUR_KEY_LINE_1\\nYOUR_KEY_LINE_2\\n-----END PRIVATE KEY-----\\n
''';
    await Clipboard.setData(const ClipboardData(text: template));
    showSnack(
      "FCM env template copied. Paste into backend/.env and fill values.",
    );
  }

  Future<void> disconnectGoogleCalendar() async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    setState(() => isGoogleLoading = true);
    try {
      final response = await _authedPost("/integrations/google/disconnect");
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        showSnack("Google Calendar disconnected.");
        await refreshGoogleCalendarStatus();
      } else {
        showSnack((data["error"] ?? "Google disconnect failed").toString());
      }
    } catch (_) {
      showSnack("Google disconnect failed.");
    } finally {
      if (mounted) {
        setState(() => isGoogleLoading = false);
      }
    }
  }

  String _twoDigits(int value) => value.toString().padLeft(2, "0");

  Future<Map<String, String>?> _openGoogleEventFormDialog({
    Map<String, dynamic>? existing,
  }) async {
    final existingStart = DateTime.tryParse(
      (existing?["start"] ?? "").toString(),
    )?.toLocal();
    final existingEnd = DateTime.tryParse(
      (existing?["end"] ?? "").toString(),
    )?.toLocal();
    final defaultDate = existingStart != null
        ? "${existingStart.year}-${_twoDigits(existingStart.month)}-${_twoDigits(existingStart.day)}"
        : "${DateTime.now().year}-${_twoDigits(DateTime.now().month)}-${_twoDigits(DateTime.now().day)}";
    final defaultTime = existingStart != null
        ? "${_twoDigits(existingStart.hour)}:${_twoDigits(existingStart.minute)}"
        : "${_twoDigits(DateTime.now().hour)}:${_twoDigits(DateTime.now().minute)}";
    final defaultDuration = existingStart != null && existingEnd != null
        ? "${existingEnd.difference(existingStart).inMinutes.clamp(15, 480)}"
        : "60";

    final titleController = TextEditingController(
      text: (existing?["summary"] ?? "").toString(),
    );
    final dateController = TextEditingController(text: defaultDate);
    final timeController = TextEditingController(text: defaultTime);
    final durationController = TextEditingController(text: defaultDuration);

    return showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            existing == null ? "Create Google Event" : "Edit Google Event",
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: "Title"),
                ),
                TextField(
                  controller: dateController,
                  decoration: const InputDecoration(
                    labelText: "Date (YYYY-MM-DD)",
                  ),
                ),
                TextField(
                  controller: timeController,
                  decoration: const InputDecoration(
                    labelText: "Time (HH:MM, 24h)",
                  ),
                ),
                TextField(
                  controller: durationController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: "Duration (minutes)",
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, {
                "title": titleController.text.trim(),
                "date": dateController.text.trim(),
                "time": timeController.text.trim(),
                "duration": durationController.text.trim(),
              }),
              child: Text(existing == null ? "Create" : "Update"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveGoogleEvent({
    String? eventId,
    required String title,
    required String date,
    required String time,
    required int durationMinutes,
  }) async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    if (title.isEmpty ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        !RegExp(r'^\d{1,2}:\d{2}$').hasMatch(time) ||
        durationMinutes <= 0) {
      showSnack("Invalid event details.");
      return;
    }

    final start = DateTime.tryParse("${date}T$time:00");
    if (start == null) {
      showSnack("Invalid event date/time.");
      return;
    }
    final end = start.add(Duration(minutes: durationMinutes));

    setState(() => isGoogleLoading = true);
    try {
      final isUpdate = eventId != null && eventId.trim().isNotEmpty;
      final response = isUpdate
          ? await _authedPatch(
              "/integrations/google/events/${Uri.encodeComponent(eventId)}",
              body: {
                "title": title,
                "startIso": start.toIso8601String(),
                "endIso": end.toIso8601String(),
              },
            )
          : await _authedPost(
              "/integrations/google/events",
              body: {
                "title": title,
                "startIso": start.toIso8601String(),
                "endIso": end.toIso8601String(),
              },
            );

      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        showSnack(isUpdate ? "Google event updated." : "Google event created.");
        await loadGoogleEvents(openDialog: true);
      } else {
        showSnack((data["error"] ?? "Google event save failed").toString());
      }
    } catch (_) {
      showSnack("Google event save failed.");
    } finally {
      if (mounted) {
        setState(() => isGoogleLoading = false);
      }
    }
  }

  Future<void> createGoogleEventFromSettings() async {
    final payload = await _openGoogleEventFormDialog();
    if (payload == null) return;
    final duration = int.tryParse((payload["duration"] ?? "").trim()) ?? 60;
    await _saveGoogleEvent(
      title: (payload["title"] ?? "").trim(),
      date: (payload["date"] ?? "").trim(),
      time: (payload["time"] ?? "").trim(),
      durationMinutes: duration,
    );
  }

  Future<void> editGoogleEventFromSettings(Map<String, dynamic> event) async {
    final payload = await _openGoogleEventFormDialog(existing: event);
    if (payload == null) return;
    final duration = int.tryParse((payload["duration"] ?? "").trim()) ?? 60;
    await _saveGoogleEvent(
      eventId: (event["id"] ?? "").toString(),
      title: (payload["title"] ?? "").trim(),
      date: (payload["date"] ?? "").trim(),
      time: (payload["time"] ?? "").trim(),
      durationMinutes: duration,
    );
  }

  Future<void> deleteGoogleEventFromSettings(Map<String, dynamic> event) async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }
    final eventId = (event["id"] ?? "").toString().trim();
    if (eventId.isEmpty) {
      showSnack("Invalid event id.");
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Event"),
        content: Text(
          "Delete '${(event["summary"] ?? "this event").toString()}' from Google Calendar?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => isGoogleLoading = true);
    try {
      final response = await _authedDelete(
        "/integrations/google/events/${Uri.encodeComponent(eventId)}",
      );
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        showSnack("Google event deleted.");
        await loadGoogleEvents(openDialog: true);
      } else {
        showSnack((data["error"] ?? "Google delete failed").toString());
      }
    } catch (_) {
      showSnack("Google delete failed.");
    } finally {
      if (mounted) {
        setState(() => isGoogleLoading = false);
      }
    }
  }

  Future<void> loadGoogleEvents({bool openDialog = true}) async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    setState(() => isGoogleLoading = true);
    try {
      final response = await _authedGet(
        "/integrations/google/events?maxResults=12",
      );
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final events = (data["events"] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        setState(() {
          googleUpcomingEvents = events;
        });
        if (openDialog) {
          await showGoogleEventsDialog();
        }
      } else {
        showSnack((data["error"] ?? "Google events fetch failed").toString());
      }
    } catch (_) {
      showSnack("Google events fetch failed.");
    } finally {
      if (mounted) {
        setState(() => isGoogleLoading = false);
      }
    }
  }

  Future<void> showGoogleEventsDialog() async {
    final items = List<Map<String, dynamic>>.from(googleUpcomingEvents);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Google Calendar Events"),
          content: SizedBox(
            width: 420,
            child: items.isEmpty
                ? const Text("No upcoming events.")
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 14),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final summary = (item["summary"] ?? "Untitled event")
                          .toString();
                      final start = (item["start"] ?? "").toString();
                      final link = (item["htmlLink"] ?? "").toString();
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(summary),
                        subtitle: Text(start.isEmpty ? "No start time" : start),
                        trailing: Wrap(
                          spacing: 2,
                          children: [
                            IconButton(
                              tooltip: "Open",
                              icon: const Icon(Icons.open_in_new_rounded),
                              onPressed: link.trim().isEmpty
                                  ? null
                                  : () async {
                                      await launchUrl(
                                        Uri.parse(link),
                                        mode: LaunchMode.externalApplication,
                                      );
                                    },
                            ),
                            IconButton(
                              tooltip: "Edit",
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () async {
                                Navigator.pop(context);
                                await editGoogleEventFromSettings(item);
                              },
                            ),
                            IconButton(
                              tooltip: "Delete",
                              icon: const Icon(Icons.delete_outline_rounded),
                              onPressed: () async {
                                Navigator.pop(context);
                                await deleteGoogleEventFromSettings(item);
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await createGoogleEventFromSettings();
              },
              child: const Text("Add Event"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Close"),
            ),
          ],
        );
      },
    );
  }

  Future<void> loadGoogleProfile({bool showToast = false}) async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    setState(() => isGoogleLoading = true);
    try {
      final response = await _authedGet("/integrations/google/profile");
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final profile = data["profile"] as Map<String, dynamic>? ?? {};
        setState(() {
          googleProfileEmail = (profile["email"] ?? "").toString();
          googleProfileName = (profile["name"] ?? "").toString();
        });
        if (showToast) {
          showSnack(
            googleProfileEmail.isEmpty
                ? "Google profile fetched."
                : "Google profile: $googleProfileEmail",
          );
        }
      } else {
        showSnack((data["error"] ?? "Google profile fetch failed").toString());
      }
    } catch (_) {
      showSnack("Google profile fetch failed.");
    } finally {
      if (mounted) {
        setState(() => isGoogleLoading = false);
      }
    }
  }

  Future<void> loadGmailMessages({bool openDialog = true}) async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    setState(() => isGoogleLoading = true);
    try {
      final response = await _authedGet(
        "/integrations/google/gmail/messages?maxResults=10",
      );
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};
      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final items = (data["messages"] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        setState(() {
          googleRecentEmails = items;
        });
        if (openDialog) {
          await showGmailMessagesDialog();
        }
      } else {
        showSnack((data["error"] ?? "Gmail fetch failed").toString());
      }
    } catch (_) {
      showSnack("Gmail fetch failed.");
    } finally {
      if (mounted) {
        setState(() => isGoogleLoading = false);
      }
    }
  }

  Future<void> showGmailMessagesDialog() async {
    final items = List<Map<String, dynamic>>.from(googleRecentEmails);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Recent Gmail Messages"),
        content: SizedBox(
          width: 460,
          child: items.isEmpty
              ? const Text("No recent messages.")
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 14),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final subject = (item["subject"] ?? "(No subject)")
                        .toString();
                    final from = (item["from"] ?? "").toString();
                    final snippet = (item["snippet"] ?? "").toString();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(subject),
                      subtitle: Text(
                        "${from.isEmpty ? "Unknown sender" : from}\n$snippet",
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  Future<void> sendGmailFromDialog() async {
    final toController = TextEditingController();
    final subjectController = TextEditingController();
    final bodyController = TextEditingController();

    final payload = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Send Gmail Message"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: toController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: "To"),
              ),
              TextField(
                controller: subjectController,
                decoration: const InputDecoration(labelText: "Subject"),
              ),
              TextField(
                controller: bodyController,
                maxLines: 6,
                decoration: const InputDecoration(labelText: "Body"),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, {
              "to": toController.text.trim(),
              "subject": subjectController.text.trim(),
              "body": bodyController.text.trim(),
            }),
            child: const Text("Send"),
          ),
        ],
      ),
    );

    if (payload == null) return;
    final to = (payload["to"] ?? "").trim();
    final subject = (payload["subject"] ?? "").trim();
    final body = (payload["body"] ?? "").trim();
    if (to.isEmpty || subject.isEmpty || body.isEmpty) {
      showSnack("To, subject, and body are required.");
      return;
    }

    setState(() => isGoogleLoading = true);
    try {
      final response = await _authedPost(
        "/integrations/google/gmail/send",
        body: {"to": to, "subject": subject, "body": body},
      );
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        showSnack("Gmail message sent.");
      } else {
        showSnack((data["error"] ?? "Gmail send failed").toString());
      }
    } catch (_) {
      showSnack("Gmail send failed.");
    } finally {
      if (mounted) {
        setState(() => isGoogleLoading = false);
      }
    }
  }

  Future<void> loadGoogleContacts({bool openDialog = true}) async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    setState(() => isGoogleLoading = true);
    try {
      final response = await _authedGet(
        "/integrations/google/contacts?maxResults=40",
      );
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final items = (data["contacts"] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        setState(() {
          googleContacts = items;
        });
        if (openDialog) {
          await showGoogleContactsDialog();
        }
      } else {
        showSnack((data["error"] ?? "Contacts fetch failed").toString());
      }
    } catch (_) {
      showSnack("Contacts fetch failed.");
    } finally {
      if (mounted) {
        setState(() => isGoogleLoading = false);
      }
    }
  }

  Future<void> showGoogleContactsDialog() async {
    final items = List<Map<String, dynamic>>.from(googleContacts);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Google Contacts"),
        content: SizedBox(
          width: 460,
          child: items.isEmpty
              ? const Text("No contacts found.")
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 14),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final name = (item["displayName"] ?? "").toString();
                    final email = (item["email"] ?? "").toString();
                    final phone = (item["phone"] ?? "").toString();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_outline_rounded),
                      title: Text(name.isEmpty ? "(No name)" : name),
                      subtitle: Text(
                        [
                          if (email.isNotEmpty) email,
                          if (phone.isNotEmpty) phone,
                        ].join('\n'),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  Future<void> openCloudAuthDialog({required bool isSignup}) async {
    final nameController = TextEditingController();
    final emailController = TextEditingController(text: cloudEmail);
    final passwordController = TextEditingController();

    final payload = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(isSignup ? "Create Cloud Account" : "Cloud Login"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isSignup)
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: "Name"),
                  ),
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: "Email"),
                ),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: "Password"),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, {
                "name": nameController.text.trim(),
                "email": emailController.text.trim(),
                "password": passwordController.text.trim(),
              }),
              child: Text(isSignup ? "Sign Up" : "Login"),
            ),
          ],
        );
      },
    );

    if (payload == null) return;

    if (isSignup && (payload["name"] ?? "").isEmpty) {
      showSnack("Name is required.");
      return;
    }
    if ((payload["email"] ?? "").isEmpty ||
        (payload["password"] ?? "").isEmpty) {
      showSnack("Email and password are required.");
      return;
    }

    setState(() => isSyncing = true);
    try {
      final path = isSignup ? "/auth/signup" : "/auth/login";
      final body = isSignup
          ? {
              "name": payload["name"],
              "email": payload["email"],
              "password": payload["password"],
            }
          : {"email": payload["email"], "password": payload["password"]};
      final response = await http.post(
        Uri.parse("$apiBaseUrl$path"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      );

      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final token = (data["token"] ?? "").toString();
        final refreshToken = (data["refreshToken"] ?? "").toString();
        final user = data["user"] as Map<String, dynamic>? ?? {};
        final email = (user["email"] ?? payload["email"] ?? "").toString();
        final name = (user["name"] ?? payload["name"] ?? "").toString();
        if (token.isEmpty || email.isEmpty) {
          showSnack("Invalid auth response from server.");
        } else {
          await saveCloudSession(
            token,
            email,
            name: name,
            refreshToken: refreshToken,
          );
          showSnack(
            isSignup ? "Cloud account created." : "Cloud login successful.",
          );
        }
      } else {
        showSnack((data["error"] ?? "Authentication failed").toString());
      }
    } catch (_) {
      showSnack("Could not reach cloud backend.");
    } finally {
      if (mounted) {
        setState(() => isSyncing = false);
      }
    }
  }

  Future<void> pullCloudToLocal() async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    setState(() => isSyncing = true);
    try {
      final response = await _authedGet("/sync/bootstrap");

      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final prefs = await SharedPreferences.getInstance();
        final sessions = (data["sessions"] as List<dynamic>? ?? const []);
        final messages = (data["messages"] as List<dynamic>? ?? const []);
        final notes = (data["notes"] as List<dynamic>? ?? const []);
        final tasks = (data["tasks"] as List<dynamic>? ?? const []);

        final msgBySession = <String, List<Map<String, dynamic>>>{};
        for (final raw in messages.whereType<Map<String, dynamic>>()) {
          final sid = (raw["sessionId"] ?? "").toString();
          msgBySession.putIfAbsent(sid, () => []);
          msgBySession[sid]!.add({
            "role": (raw["role"] ?? "").toString(),
            "text": (raw["text"] ?? "").toString(),
            "time": (raw["time"] ?? "").toString(),
            "type": (raw["type"] ?? "chat").toString(),
            "code": (raw["code"] ?? "").toString(),
            "imagePrompt": (raw["imagePrompt"] ?? "").toString(),
            "videoPrompt": (raw["videoPrompt"] ?? "").toString(),
            "action": (raw["action"] ?? "").toString(),
            "url": (raw["url"] ?? "").toString(),
            "info": (raw["info"] ?? "").toString(),
            "starred": raw["starred"] == true,
          });
        }

        final localSessions = sessions.whereType<Map<String, dynamic>>().map((
          s,
        ) {
          final sid = (s["id"] ?? "").toString();
          return {
            "id": sid,
            "title": (s["title"] ?? "New Chat").toString(),
            "createdAt": (s["createdAt"] ?? DateTime.now().toIso8601String())
                .toString(),
            "updatedAt": (s["updatedAt"] ?? DateTime.now().toIso8601String())
                .toString(),
            "isPinned": s["isPinned"] == true,
            "items": msgBySession[sid] ?? <Map<String, dynamic>>[],
          };
        }).toList();

        final localNotes = notes.whereType<Map<String, dynamic>>().map((n) {
          return {
            "text": (n["text"] ?? "").toString(),
            "createdAt": (n["createdAt"] ?? DateTime.now().toIso8601String())
                .toString(),
          };
        }).toList();

        final localTasks = tasks.whereType<Map<String, dynamic>>().map((t) {
          return {
            "title": (t["title"] ?? "").toString(),
            "done": t["done"] == true,
            "priority": (t["priority"] ?? "Medium").toString(),
            "createdAt": (t["createdAt"] ?? DateTime.now().toIso8601String())
                .toString(),
          };
        }).toList();

        await prefs.setString(_chatSessionsKey, jsonEncode(localSessions));
        await prefs.setString(_notesKey, jsonEncode(localNotes));
        await prefs.setString(_tasksKey, jsonEncode(localTasks));
        if (localSessions.isNotEmpty) {
          await prefs.setString(
            _activeChatIdKey,
            localSessions.first["id"].toString(),
          );
        }

        showSnack("Cloud data downloaded to local.");
      } else {
        showSnack((data["error"] ?? "Cloud pull failed").toString());
      }
    } catch (_) {
      showSnack("Cloud pull failed.");
    } finally {
      if (mounted) setState(() => isSyncing = false);
    }
  }

  Future<void> pushLocalToCloud() async {
    if (!isCloudConnected) {
      showSnack("Login to cloud first.");
      return;
    }

    setState(() => isSyncing = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionsRaw = prefs.getString(_chatSessionsKey);
      final notesRaw = prefs.getString(_notesKey);
      final tasksRaw = prefs.getString(_tasksKey);

      final sessions = sessionsRaw != null && sessionsRaw.isNotEmpty
          ? (jsonDecode(sessionsRaw) as List<dynamic>)
          : <dynamic>[];
      final notes = notesRaw != null && notesRaw.isNotEmpty
          ? (jsonDecode(notesRaw) as List<dynamic>)
          : <dynamic>[];
      final tasks = tasksRaw != null && tasksRaw.isNotEmpty
          ? (jsonDecode(tasksRaw) as List<dynamic>)
          : <dynamic>[];

      final messages = <Map<String, dynamic>>[];
      for (final s in sessions.whereType<Map<String, dynamic>>()) {
        final sid = (s["id"] ?? "").toString();
        final items = (s["items"] as List<dynamic>? ?? const []);
        for (final m in items.whereType<Map<String, dynamic>>()) {
          messages.add({
            "sessionId": sid,
            "role": (m["role"] ?? "").toString(),
            "text": (m["text"] ?? "").toString(),
            "time": (m["time"] ?? "").toString(),
            "type": (m["type"] ?? "chat").toString(),
            "code": (m["code"] ?? "").toString(),
            "imagePrompt": (m["imagePrompt"] ?? "").toString(),
            "videoPrompt": (m["videoPrompt"] ?? "").toString(),
            "action": (m["action"] ?? "").toString(),
            "url": (m["url"] ?? "").toString(),
            "info": (m["info"] ?? "").toString(),
            "starred": m["starred"] == true,
          });
        }
      }

      final response = await _authedPost(
        "/sync/import",
        body: {
          "sessions": sessions,
          "messages": messages,
          "notes": notes,
          "tasks": tasks,
        },
      );

      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        showSnack("Local data uploaded to cloud.");
      } else {
        showSnack((data["error"] ?? "Cloud push failed").toString());
      }
    } catch (_) {
      showSnack("Cloud push failed.");
    } finally {
      if (mounted) setState(() => isSyncing = false);
    }
  }

  Future<void> clearNotes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_notesKey);
    showSnack("All notes cleared.");
  }

  Future<void> clearTasks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tasksKey);
    showSnack("All tasks cleared.");
  }

  Future<void> clearChat() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyChatKey);
    await prefs.remove(_chatSessionsKey);
    await prefs.remove(_activeChatIdKey);
    showSnack("Chat history cleared.");
  }

  Future<void> clearAllLocalData() async {
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Clear All Local Data"),
          content: const Text(
            "This will delete local chat, notes, and tasks. Do you want to continue?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Clear"),
            ),
          ],
        );
      },
    );

    if (shouldClear != true) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyChatKey);
    await prefs.remove(_chatSessionsKey);
    await prefs.remove(_activeChatIdKey);
    await prefs.remove(_notesKey);
    await prefs.remove(_tasksKey);

    showSnack("All local data cleared.");
  }

  bool get _hasPushSelfTestSuccess =>
      pushSelfTestResult.toLowerCase().contains('sent=');

  List<Map<String, dynamic>> _buildPushReleaseChecklistItems() {
    return [
      {'label': 'Cloud account connected', 'done': isCloudConnected},
      {'label': 'Backend FCM env configured', 'done': fcmConfigured},
      {'label': 'Firebase admin initialized', 'done': firebaseAdminReady},
      {
        'label': 'Android Firebase file added',
        'done': androidGoogleServicesPresent,
      },
      {'label': 'iOS Firebase file added', 'done': iosGoogleServiceInfoPresent},
      {
        'label': 'At least one device token registered',
        'done': pushDeviceCount > 0,
      },
      {'label': 'Full push self-test passed', 'done': _hasPushSelfTestSuccess},
    ];
  }

  Future<void> openPushReleaseChecklistDialog() async {
    final items = _buildPushReleaseChecklistItems();
    final completed = items.where((item) => item['done'] == true).length;
    final total = items.length;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Push Release Checklist ($completed/$total)'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...items.map((item) {
                  final done = item['done'] == true;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          done
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 18,
                          color: done
                              ? Colors.greenAccent
                              : Colors.orangeAccent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item['label'].toString(),
                            style: TextStyle(
                              color: done ? Colors.white : Colors.white70,
                              fontWeight: done
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 10),
                const Text(
                  'iOS manual step: enable Push Notifications and Background Modes > Remote notifications in Xcode.',
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await refreshPushStatus(showToast: true);
                await runPushDoctor(showToast: true);
              },
              child: const Text('Refresh Checks'),
            ),
          ],
        );
      },
    );
  }

  Widget buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget buildSettingsCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: child,
    );
  }

  Widget buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(icon),
      value: value,
      onChanged: onChanged,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    );
  }

  Widget buildActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
      onTap: onTap,
    );
  }

  Widget buildTopInfoCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [
            Colors.blue.withValues(alpha: 0.18),
            Colors.black.withValues(alpha: 0.18),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.20)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "FLOWGNIMAG Settings",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text(
            "Control your assistant behavior, voice preferences, smart reply mode, and local app data from here.",
            style: TextStyle(fontSize: 14, height: 1.5, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          buildTopInfoCard(),
          const SizedBox(height: 18),

          buildSectionTitle("Appearance"),
          buildSettingsCard(
            child: Column(
              children: [
                buildActionTile(
                  icon: Icons.dark_mode_outlined,
                  title: "Toggle Theme",
                  subtitle: "Switch between light and dark appearance.",
                  onTap: widget.toggleTheme,
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          buildSectionTitle("Voice"),
          buildSettingsCard(
            child: Column(
              children: [
                buildSwitchTile(
                  icon: Icons.mic_none,
                  title: "Voice Input",
                  subtitle: "Allow speech-to-text input from the mic.",
                  value: voiceEnabled,
                  onChanged: (value) async {
                    setState(() => voiceEnabled = value);
                    await saveBool(_voiceKey, value);
                  },
                ),
                buildSwitchTile(
                  icon: Icons.volume_up_outlined,
                  title: "Auto Speak",
                  subtitle: "Assistant will speak replies automatically.",
                  value: autoSpeak,
                  onChanged: (value) async {
                    setState(() => autoSpeak = value);
                    await saveBool(_autoSpeakKey, value);
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          buildSectionTitle("Assistant"),
          buildSettingsCard(
            child: Column(
              children: [
                buildSwitchTile(
                  icon: Icons.auto_awesome_outlined,
                  title: "Smart Reply",
                  subtitle: "Use clearer and more detailed AI responses.",
                  value: smartReply,
                  onChanged: (value) async {
                    setState(() => smartReply = value);
                    await saveBool(_smartReplyKey, value);
                  },
                ),
                buildSwitchTile(
                  icon: Icons.waving_hand_outlined,
                  title: "Show Welcome Screen",
                  subtitle: "Show the welcome panel when chat is empty.",
                  value: showWelcome,
                  onChanged: (value) async {
                    setState(() => showWelcome = value);
                    await saveBool(_showWelcomeKey, value);
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          buildSectionTitle("Cloud Sync"),
          buildSettingsCard(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    isCloudConnected ? Icons.cloud_done : Icons.cloud_off,
                    color: isCloudConnected
                        ? Colors.greenAccent
                        : Colors.orangeAccent,
                  ),
                  title: Text(
                    isCloudConnected
                        ? "Connected to Cloud"
                        : "Cloud Not Connected",
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    isCloudConnected
                        ? "Logged in as ${cloudName.trim().isEmpty ? "Cloud User" : cloudName} • $cloudEmail"
                        : "Sign up or login to sync chats, notes, and tasks.",
                  ),
                ),
                if (!isCloudConnected)
                  buildActionTile(
                    icon: Icons.person_add_alt_1_outlined,
                    title: "Create Cloud Account",
                    subtitle: "Register and start syncing your workspace.",
                    onTap: isSyncing
                        ? () {}
                        : () => openCloudAuthDialog(isSignup: true),
                    iconColor: Colors.blueAccent,
                  ),
                if (!isCloudConnected)
                  buildActionTile(
                    icon: Icons.login_rounded,
                    title: "Cloud Login",
                    subtitle: "Login with email and password.",
                    onTap: isSyncing
                        ? () {}
                        : () => openCloudAuthDialog(isSignup: false),
                    iconColor: Colors.lightBlueAccent,
                  ),
                if (isCloudConnected)
                  buildActionTile(
                    icon: Icons.cloud_download_outlined,
                    title: "Download Cloud To Local",
                    subtitle: "Replace local data with cloud snapshot.",
                    onTap: isSyncing ? () {} : pullCloudToLocal,
                    iconColor: Colors.greenAccent,
                  ),
                if (isCloudConnected)
                  buildActionTile(
                    icon: Icons.cloud_upload_outlined,
                    title: "Upload Local To Cloud",
                    subtitle: "Replace cloud data with local snapshot.",
                    onTap: isSyncing ? () {} : pushLocalToCloud,
                    iconColor: Colors.orangeAccent,
                  ),
                if (isCloudConnected)
                  buildActionTile(
                    icon: Icons.logout_rounded,
                    title: "Cloud Logout",
                    subtitle: "Disconnect this device from cloud account.",
                    onTap: isSyncing ? () {} : clearCloudSession,
                    iconColor: Colors.redAccent,
                  ),
                if (isSyncing)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          buildSectionTitle("Push Notifications"),
          buildSettingsCard(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    pushDeviceCount > 0
                        ? Icons.notifications_active
                        : Icons.notifications_off,
                    color: pushDeviceCount > 0
                        ? Colors.greenAccent
                        : Colors.orangeAccent,
                  ),
                  title: const Text(
                    "FCM Push Status",
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    !isCloudConnected
                        ? "Login to cloud to register push device."
                        : "Backend: ${fcmConfigured ? "configured" : "not configured"}  |  Admin: ${firebaseAdminReady ? "ready" : "not ready"}  |  Devices: $pushDeviceCount",
                  ),
                ),
                if (isCloudConnected)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Android config: ${androidGoogleServicesPresent ? "present" : "missing"}  |  iOS config: ${iosGoogleServiceInfoPresent ? "present" : "missing"}",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                if (localPushTokenPreview.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Local token: $localPushTokenPreview",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                if (isCloudConnected)
                  buildActionTile(
                    icon: Icons.task_alt_outlined,
                    title: "Open Release Checklist",
                    subtitle:
                        "See all push go-live tasks and completion status.",
                    onTap: isPushLoading
                        ? () {}
                        : openPushReleaseChecklistDialog,
                    iconColor: Colors.lightBlueAccent,
                  ),
                if (isCloudConnected)
                  buildActionTile(
                    icon: Icons.sync_rounded,
                    title: "Refresh Push Status",
                    subtitle: "Check backend/device registration state.",
                    onTap: isPushLoading
                        ? () {}
                        : () => refreshPushStatus(showToast: true),
                    iconColor: Colors.lightBlueAccent,
                  ),
                if (isCloudConnected)
                  buildActionTile(
                    icon: Icons.notification_add_outlined,
                    title: "Send Push Test",
                    subtitle:
                        "Send a test notification to this account devices.",
                    onTap: isPushLoading ? () {} : sendPushTestFromSettings,
                    iconColor: Colors.greenAccent,
                  ),
                if (isCloudConnected)
                  buildActionTile(
                    icon: Icons.medical_services_outlined,
                    title: "Run Push Doctor",
                    subtitle: "Diagnose what is still missing for live push.",
                    onTap: isPushLoading ? () {} : runPushDoctor,
                    iconColor: Colors.cyanAccent,
                  ),
                if (isCloudConnected)
                  buildActionTile(
                    icon: Icons.fact_check_outlined,
                    title: "Run Full Push Self-Test",
                    subtitle: "Run diagnostics and send test push in one tap.",
                    onTap: isPushLoading ? () {} : runFullPushSelfTest,
                    iconColor: Colors.lightGreenAccent,
                  ),
                if (isCloudConnected)
                  buildActionTile(
                    icon: Icons.content_copy_outlined,
                    title: "Copy FCM .env Keys",
                    subtitle:
                        "Copy backend Firebase env template to clipboard.",
                    onTap: isPushLoading ? () {} : copyFcmEnvTemplate,
                    iconColor: Colors.tealAccent,
                  ),
                if (pushSelfTestResult.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        pushSelfTestResult,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.lightGreenAccent,
                        ),
                      ),
                    ),
                  ),
                if (pushDoctorSummary.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Doctor: $pushDoctorSummary",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                if (pushDoctorMissing.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Missing: ${pushDoctorMissing.join(" | ")}",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.orangeAccent,
                        ),
                      ),
                    ),
                  ),
                if (pushDoctorActions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Actions: ${pushDoctorActions.join(" | ")}",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.cyanAccent,
                        ),
                      ),
                    ),
                  ),
                if (isPushLoading)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          buildSectionTitle("Google Calendar"),
          buildSettingsCard(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    googleConnected
                        ? Icons.event_available_rounded
                        : Icons.event_busy_rounded,
                    color: googleConnected
                        ? Colors.greenAccent
                        : Colors.orangeAccent,
                  ),
                  title: Text(
                    googleConnected
                        ? "Google Calendar Connected"
                        : googleConfigured
                        ? "Google Calendar Not Connected"
                        : "Google Calendar Not Configured",
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    !isCloudConnected
                        ? "Login to cloud to use calendar integration."
                        : !googleConfigured
                        ? "Set GOOGLE_CLIENT_ID/SECRET/REDIRECT in backend .env."
                        : googleConnected
                        ? "Token expiry: ${googleExpiryAt.isEmpty ? "unknown" : googleExpiryAt}"
                        : "Connect your Google account to sync events.",
                  ),
                ),
                if (isCloudConnected && googleConfigured && !googleConnected)
                  buildActionTile(
                    icon: Icons.link_rounded,
                    title: "Connect Google Calendar",
                    subtitle: "Open OAuth consent in browser.",
                    onTap: isGoogleLoading ? () {} : connectGoogleCalendar,
                    iconColor: Colors.lightBlueAccent,
                  ),
                if (isCloudConnected && googleConfigured)
                  buildActionTile(
                    icon: Icons.refresh_rounded,
                    title: "Refresh Google Status",
                    subtitle: "Check current connection/token state.",
                    onTap: isGoogleLoading
                        ? () {}
                        : () => refreshGoogleCalendarStatus(showToast: true),
                    iconColor: Colors.blueAccent,
                  ),
                if (isCloudConnected && googleConnected)
                  buildActionTile(
                    icon: Icons.account_circle_outlined,
                    title: "Load Google Profile",
                    subtitle: "Fetch connected Google account profile.",
                    onTap: isGoogleLoading
                        ? () {}
                        : () => loadGoogleProfile(showToast: true),
                    iconColor: Colors.cyanAccent,
                  ),
                if (isCloudConnected && googleConnected)
                  buildActionTile(
                    icon: Icons.add_task_outlined,
                    title: "Create Google Event",
                    subtitle: "Create a new event with date/time.",
                    onTap: isGoogleLoading
                        ? () {}
                        : createGoogleEventFromSettings,
                    iconColor: Colors.lightGreenAccent,
                  ),
                if (isCloudConnected && googleConnected)
                  buildActionTile(
                    icon: Icons.event_note_outlined,
                    title: "View Upcoming Google Events",
                    subtitle: "Fetch and preview upcoming events.",
                    onTap: isGoogleLoading ? () {} : loadGoogleEvents,
                    iconColor: Colors.greenAccent,
                  ),
                if (isCloudConnected && googleConnected)
                  buildActionTile(
                    icon: Icons.mail_outline_rounded,
                    title: "View Recent Gmail",
                    subtitle: "Preview latest Gmail messages.",
                    onTap: isGoogleLoading ? () {} : loadGmailMessages,
                    iconColor: Colors.orangeAccent,
                  ),
                if (isCloudConnected && googleConnected)
                  buildActionTile(
                    icon: Icons.send_outlined,
                    title: "Send Gmail Message",
                    subtitle: "Compose and send from connected account.",
                    onTap: isGoogleLoading ? () {} : sendGmailFromDialog,
                    iconColor: Colors.deepOrangeAccent,
                  ),
                if (isCloudConnected && googleConnected)
                  buildActionTile(
                    icon: Icons.contacts_outlined,
                    title: "View Google Contacts",
                    subtitle: "List people from Google contacts.",
                    onTap: isGoogleLoading ? () {} : loadGoogleContacts,
                    iconColor: Colors.lightBlueAccent,
                  ),
                if (isCloudConnected && googleConnected)
                  buildActionTile(
                    icon: Icons.link_off_rounded,
                    title: "Disconnect Google Calendar",
                    subtitle: "Remove stored Google token from backend.",
                    onTap: isGoogleLoading ? () {} : disconnectGoogleCalendar,
                    iconColor: Colors.redAccent,
                  ),
                if (googleProfileEmail.trim().isNotEmpty ||
                    googleProfileName.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Profile: ${googleProfileName.isEmpty ? "-" : googleProfileName}  |  ${googleProfileEmail.isEmpty ? "-" : googleProfileEmail}",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                if (googleScope.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Scope: $googleScope",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                if (isGoogleLoading)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          buildSectionTitle("Data Management"),
          buildSettingsCard(
            child: Column(
              children: [
                buildActionTile(
                  icon: Icons.chat_bubble_outline,
                  title: "Clear Chat History",
                  subtitle: "Delete all locally saved chat messages.",
                  onTap: clearChat,
                  iconColor: Colors.orangeAccent,
                ),
                buildActionTile(
                  icon: Icons.note_alt_outlined,
                  title: "Clear Notes",
                  subtitle: "Delete all saved notes from local storage.",
                  onTap: clearNotes,
                  iconColor: Colors.orangeAccent,
                ),
                buildActionTile(
                  icon: Icons.task_alt_outlined,
                  title: "Clear Tasks",
                  subtitle: "Delete all saved tasks from local storage.",
                  onTap: clearTasks,
                  iconColor: Colors.orangeAccent,
                ),
                buildActionTile(
                  icon: Icons.delete_forever_outlined,
                  title: "Clear All Local Data",
                  subtitle: "Delete chat, notes, and tasks together.",
                  onTap: clearAllLocalData,
                  iconColor: Colors.redAccent,
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.blue.withValues(alpha: 0.20)),
            ),
            child: const Text(
              "These settings directly affect Chat, Assistant, and local data behavior. After changing them, your assistant will use the new values automatically.",
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: Colors.white70,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
