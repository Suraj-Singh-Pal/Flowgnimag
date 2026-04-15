import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

import '../config/backend_config.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';

class ChatScreen extends StatefulWidget {
  final bool isOnlineMode;
  final bool autoStartListening;
  final int openHistorySignal;
  final ValueChanged<bool>? onListeningChanged;
  final ValueChanged<bool>? onSpeakingChanged;

  const ChatScreen({
    super.key,
    required this.isOnlineMode,
    this.autoStartListening = false,
    this.openHistorySignal = 0,
    this.onListeningChanged,
    this.onSpeakingChanged,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController controller = TextEditingController();
  final TextEditingController historySearchController = TextEditingController();
  final ScrollController scrollController = ScrollController();

  final List<Map<String, dynamic>> messages = [];
  final List<Map<String, dynamic>> chatSessions = [];

  bool isLoading = false;
  bool isListening = false;
  bool isSpeaking = false;
  bool isGeneratingImage = false;
  bool isGeneratingVideo = false;
  bool voiceEnabled = true;
  bool wakeModeEnabled = false;
  bool autoSpeak = true;
  bool smartReply = true;
  bool showWelcome = true;
  bool _wakeWordDetected = false;
  String assistantMode = 'jarvis';
  bool googleAlertsEnabled = true;

  String historySearchText = '';
  String _lastRecognizedWords = '';
  String _currentlySpeakingText = '';
  String currentSessionId = '';
  String _cloudToken = '';
  String _cloudRefreshToken = '';

  late stt.SpeechToText speech;
  late FlutterTts flutterTts;
  Timer? _activeTimer;
  Timer? _googleAlertsTimer;
  StreamSubscription<RemoteMessage>? _fcmOnMessageSub;
  StreamSubscription<String>? _fcmTokenRefreshSub;
  String _registeredPushToken = '';

  static const String _legacyStorageChatKey = 'flowgnimag_chat';
  static const String _storageChatSessionsKey = 'flowgnimag_chat_sessions_v2';
  static const String _storageActiveChatIdKey = 'flowgnimag_active_chat_id_v2';
  static const String _storageNotesKey = 'flowgnimag_notes';
  static const String _storageTasksKey = 'flowgnimag_tasks';
  static const String _storageRemindersKey = 'flowgnimag_reminders_v1';
  static const String _storageRoutinesKey = 'flowgnimag_routines_v1';
  static const String _storageEventsKey = 'flowgnimag_events_v1';
  static const String _storageActionLogKey = 'flowgnimag_action_log_v1';
  static const String _voiceKey = 'flowgnimag_voice_enabled';
  static const String _wakeModeKey = 'flowgnimag_wake_mode';
  static const String _autoSpeakKey = 'flowgnimag_auto_speak';
  static const String _smartReplyKey = 'flowgnimag_smart_reply';
  static const String _assistantModeKey = 'flowgnimag_assistant_mode';
  static const String _showWelcomeKey = 'flowgnimag_show_welcome';
  static const String _cloudTokenKey = 'flowgnimag_cloud_token';
  static const String _cloudRefreshTokenKey = 'flowgnimag_cloud_refresh_token';
  static const String _googleAlertsEnabledKey = 'flowgnimag_google_alerts_enabled';
  static const String _seenGoogleGmailIdsKey = 'flowgnimag_seen_google_gmail_ids';
  static const String _seenGoogleEventIdsKey = 'flowgnimag_seen_google_event_ids';

  final List<Map<String, String>> _imageTools = const [
    {'name': 'Bing Image Creator', 'url': 'https://www.bing.com/images/create'},
    {'name': 'Leonardo AI', 'url': 'https://app.leonardo.ai/'},
    {'name': 'Playground AI', 'url': 'https://playground.com/'},
  ];

  static const List<String> _wakeWords = [
    'hey flow',
    'ok flow',
    'hey jarvis',
    'ok jarvis',
    'flowgnimag',
    'jarvis',
  ];

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  bool _notificationsReady = false;
  static bool _tzInitialized = false;

  bool get hasActiveHistorySearch => historySearchText.trim().isNotEmpty;
  bool get hasMessages => messages.isNotEmpty;
  bool get isCloudConnected => _cloudToken.trim().isNotEmpty;
  bool get hasStarredMessages =>
      messages.any((msg) => (msg['starred'] ?? false) == true);

  String get assistantModeLabel {
    if (assistantMode == 'creative') {
      return 'Creative';
    }
    if (assistantMode == 'precise') {
      return 'Precise';
    }
    return 'Jarvis';
  }
  String get lastUserPrompt {
    for (final item in messages.reversed) {
      if ((item['role'] ?? '') == 'user') {
        final text = (item['text'] ?? '').toString().trim();
        if (text.isNotEmpty) {
          return text;
        }
      }
    }
    return '';
  }

  @override
  void initState() {
    super.initState();
    speech = stt.SpeechToText();
    flutterTts = FlutterTts();
    initTts();
    initData();
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.openHistorySignal != oldWidget.openHistorySignal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showHistorySheet();
        }
      });
    }
  }

  String get apiBaseUrl {
    return BackendConfig.apiBaseUrl;
  }

  Future<void> initData() async {
    await loadSettings();
    await _ensureNotificationsReady();
    await _setupFirebasePushIfPossible();
    _startGoogleAlertsMonitorIfNeeded();
    if (isCloudConnected) {
      await loadCloudBootstrapData();
    } else {
      await loadChatSessions();
    }

    if (widget.autoStartListening && voiceEnabled) {
      Future.delayed(const Duration(milliseconds: 450), () async {
        if (mounted) {
          if (wakeModeEnabled) {
            await _startWakeListening();
          } else {
            await toggleListening();
          }
        }
      });
    } else if (wakeModeEnabled && voiceEnabled) {
      Future.delayed(const Duration(milliseconds: 450), () async {
        if (mounted) {
          await _startWakeListening();
        }
      });
    }
  }

  Future<void> _ensureNotificationsReady() async {
    if (_notificationsReady || kIsWeb) {
      return;
    }

    if (!_tzInitialized) {
      tzdata.initializeTimeZones();
      _tzInitialized = true;
    }

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
    );

    await _notificationsPlugin.initialize(settings);

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    _notificationsReady = true;
  }

  String _devicePlatformLabel() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  Future<void> _registerPushToken(String token) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty || !isCloudConnected || _cloudToken.trim().isEmpty) {
      return;
    }

    try {
      await http.post(
        Uri.parse("$apiBaseUrl/notifications/register"),
        headers: {
          "Authorization": "Bearer $_cloudToken",
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "token": cleanToken,
          "platform": _devicePlatformLabel(),
        }),
      );
      _registeredPushToken = cleanToken;
    } catch (_) {}
  }

  Future<void> _unregisterPushToken() async {
    final token = _registeredPushToken.trim();
    if (token.isEmpty || !isCloudConnected || _cloudToken.trim().isEmpty) {
      return;
    }
    try {
      await http.post(
        Uri.parse("$apiBaseUrl/notifications/unregister"),
        headers: {
          "Authorization": "Bearer $_cloudToken",
          "Content-Type": "application/json",
        },
        body: jsonEncode({"token": token}),
      );
    } catch (_) {}
  }

  Future<void> _setupFirebasePushIfPossible() async {
    if (kIsWeb || !isCloudConnected || _cloudToken.trim().isEmpty) {
      return;
    }

    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      final token = await messaging.getToken();
      if (token != null && token.trim().isNotEmpty) {
        await _registerPushToken(token);
      }

      _fcmOnMessageSub ??= FirebaseMessaging.onMessage.listen((message) async {
        final title =
            (message.notification?.title ?? '').trim().isNotEmpty
            ? message.notification!.title!.trim()
            : 'FLOWGNIMAG Alert';
        final body =
            (message.notification?.body ?? '').trim().isNotEmpty
            ? message.notification!.body!.trim()
            : 'You have a new update.';
        await _notifyGoogleAlert(
          idSeed: DateTime.now().millisecondsSinceEpoch,
          title: title,
          body: body,
        );
      });

      _fcmTokenRefreshSub ??= messaging.onTokenRefresh.listen((newToken) async {
        await _registerPushToken(newToken);
      });
    } catch (_) {}
  }

  void _stopGoogleAlertsMonitor() {
    _googleAlertsTimer?.cancel();
    _googleAlertsTimer = null;
  }

  void _startGoogleAlertsMonitorIfNeeded({bool forceRestart = false}) {
    if (!googleAlertsEnabled || !isCloudConnected || _cloudToken.trim().isEmpty) {
      _stopGoogleAlertsMonitor();
      return;
    }

    if (!forceRestart && _googleAlertsTimer != null) {
      return;
    }

    _stopGoogleAlertsMonitor();
    _googleAlertsTimer = Timer.periodic(const Duration(minutes: 2), (_) async {
      await _checkGoogleAlertsOnce();
    });

    Future.delayed(const Duration(seconds: 4), () async {
      if (mounted) {
        await _checkGoogleAlertsOnce();
      }
    });
  }

  Future<List<String>> _getSeenIds(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) {
      return [];
    }
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _setSeenIds(String key, List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = ids.where((e) => e.trim().isNotEmpty).take(100).toList();
    await prefs.setString(key, jsonEncode(clean));
  }

  Future<void> _notifyGoogleAlert({
    required int idSeed,
    required String title,
    required String body,
  }) async {
    await _ensureNotificationsReady();
    if (!_notificationsReady) return;

    const androidDetails = AndroidNotificationDetails(
      'flowgnimag_google_alerts',
      'FLOWGNIMAG Google Alerts',
      channelDescription: 'Background alerts for Gmail and Google Calendar',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );

    await _notificationsPlugin.show(
      idSeed.remainder(2147483000),
      title,
      body,
      details,
      payload: jsonEncode({
        'title': title,
        'body': body,
        'time': DateTime.now().toIso8601String(),
      }),
    );
  }

  String _buildEmailAlertSummary(Map<String, dynamic> item) {
    final from = (item['from'] ?? '').toString().trim();
    final subject = (item['subject'] ?? '').toString().trim();
    if (from.isEmpty && subject.isEmpty) {
      return 'New Gmail message received.';
    }
    if (from.isEmpty) {
      return subject;
    }
    if (subject.isEmpty) {
      return 'From $from';
    }
    return '$subject • $from';
  }

  String _buildEventAlertSummary(Map<String, dynamic> item) {
    final summary = (item['summary'] ?? 'Upcoming event').toString().trim();
    final start = (item['start'] ?? '').toString().replaceAll('T', ' ');
    if (start.isEmpty) {
      return summary;
    }
    final shortStart = start.length > 16 ? start.substring(0, 16) : start;
    return '$summary at $shortStart';
  }

  Future<void> _checkGoogleAlertsOnce() async {
    if (!googleAlertsEnabled || !isCloudConnected || _cloudToken.trim().isEmpty) {
      return;
    }

    try {
      final statusResponse = await _getWithAuthRetry(
        '/integrations/google/status',
        headers: {'Authorization': 'Bearer $_cloudToken'},
      );
      final statusData = statusResponse.body.isNotEmpty
          ? jsonDecode(statusResponse.body) as Map<String, dynamic>
          : <String, dynamic>{};
      if (statusResponse.statusCode < 200 ||
          statusResponse.statusCode >= 300 ||
          statusData['connected'] != true) {
        return;
      }

      final gmailResponse = await _getWithAuthRetry(
        '/integrations/google/gmail/messages?maxResults=8',
        headers: {'Authorization': 'Bearer $_cloudToken'},
      );
      final gmailData = gmailResponse.body.isNotEmpty
          ? jsonDecode(gmailResponse.body) as Map<String, dynamic>
          : <String, dynamic>{};
      final gmailItems = (gmailData['messages'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

      final eventResponse = await _getWithAuthRetry(
        '/integrations/google/events?maxResults=8',
        headers: {'Authorization': 'Bearer $_cloudToken'},
      );
      final eventData = eventResponse.body.isNotEmpty
          ? jsonDecode(eventResponse.body) as Map<String, dynamic>
          : <String, dynamic>{};
      final eventItems = (eventData['events'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

      final seenGmail = await _getSeenIds(_seenGoogleGmailIdsKey);
      final seenEvents = await _getSeenIds(_seenGoogleEventIdsKey);

      final currentGmailIds = gmailItems
          .map((e) => (e['id'] ?? '').toString())
          .where((e) => e.isNotEmpty)
          .toList();
      final currentEventIds = eventItems
          .map((e) => (e['id'] ?? '').toString())
          .where((e) => e.isNotEmpty)
          .toList();

      final isFirstGmailBaseline = seenGmail.isEmpty;
      final isFirstEventBaseline = seenEvents.isEmpty;

      if (!isFirstGmailBaseline) {
        final newMails = gmailItems.where((item) {
          final id = (item['id'] ?? '').toString();
          return id.isNotEmpty && !seenGmail.contains(id);
        }).take(3);

        for (final mail in newMails) {
          final id = (mail['id'] ?? '').toString();
          await _notifyGoogleAlert(
            idSeed: id.hashCode ^ DateTime.now().millisecondsSinceEpoch,
            title: 'New Gmail',
            body: _buildEmailAlertSummary(mail),
          );
        }
      }

      if (!isFirstEventBaseline) {
        final newEvents = eventItems.where((item) {
          final id = (item['id'] ?? '').toString();
          return id.isNotEmpty && !seenEvents.contains(id);
        }).take(3);

        for (final event in newEvents) {
          final id = (event['id'] ?? '').toString();
          await _notifyGoogleAlert(
            idSeed: id.hashCode ^ DateTime.now().millisecondsSinceEpoch,
            title: 'Upcoming Calendar Event',
            body: _buildEventAlertSummary(event),
          );
        }
      }

      await _setSeenIds(_seenGoogleGmailIdsKey, currentGmailIds);
      await _setSeenIds(_seenGoogleEventIdsKey, currentEventIds);
    } catch (_) {}
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) {
      return;
    }

    setState(() {
      voiceEnabled = prefs.getBool(_voiceKey) ?? true;
      wakeModeEnabled = prefs.getBool(_wakeModeKey) ?? false;
      autoSpeak = prefs.getBool(_autoSpeakKey) ?? true;
      smartReply = prefs.getBool(_smartReplyKey) ?? true;
      assistantMode =
          (prefs.getString(_assistantModeKey) ?? 'jarvis').toLowerCase();
      if (assistantMode != 'jarvis' &&
          assistantMode != 'creative' &&
          assistantMode != 'precise') {
        assistantMode = 'jarvis';
      }
      showWelcome = prefs.getBool(_showWelcomeKey) ?? true;
      _cloudToken = prefs.getString(_cloudTokenKey) ?? '';
      _cloudRefreshToken = prefs.getString(_cloudRefreshTokenKey) ?? '';
      googleAlertsEnabled = prefs.getBool(_googleAlertsEnabledKey) ?? true;
    });

    _startGoogleAlertsMonitorIfNeeded(forceRestart: true);
  }

  Future<void> toggleGoogleAlerts() async {
    final next = !googleAlertsEnabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_googleAlertsEnabledKey, next);

    if (!mounted) return;

    setState(() {
      googleAlertsEnabled = next;
    });

    if (next) {
      _startGoogleAlertsMonitorIfNeeded(forceRestart: true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google alerts enabled')),
      );
    } else {
      _stopGoogleAlertsMonitor();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google alerts disabled')),
      );
    }
  }

  Future<void> cycleAssistantMode() async {
    const order = ['jarvis', 'creative', 'precise'];
    final index = order.indexOf(assistantMode);
    final next = order[(index + 1) % order.length];

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_assistantModeKey, next);

    if (!mounted) {
      return;
    }

    setState(() {
      assistantMode = next;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Assistant mode: $assistantModeLabel')),
    );
  }

  Future<void> initTts() async {
    await flutterTts.setSpeechRate(0.45);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);

    flutterTts.setStartHandler(() {
      if (!mounted) {
        return;
      }
      setState(() => isSpeaking = true);
      widget.onSpeakingChanged?.call(true);
    });

    flutterTts.setCompletionHandler(() {
      if (!mounted) {
        return;
      }
      setState(() {
        isSpeaking = false;
        _currentlySpeakingText = '';
      });
      widget.onSpeakingChanged?.call(false);
      _resumeWakeModeIfNeeded();
    });

    flutterTts.setCancelHandler(() {
      if (!mounted) {
        return;
      }
      setState(() {
        isSpeaking = false;
        _currentlySpeakingText = '';
      });
      widget.onSpeakingChanged?.call(false);
      _resumeWakeModeIfNeeded();
    });

    flutterTts.setErrorHandler((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        isSpeaking = false;
        _currentlySpeakingText = '';
      });
      widget.onSpeakingChanged?.call(false);
      _resumeWakeModeIfNeeded();
    });
  }

  Future<void> loadChatSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final savedSessions = prefs.getString(_storageChatSessionsKey);
    final savedActiveId = prefs.getString(_storageActiveChatIdKey);
    final legacyChat = prefs.getString(_legacyStorageChatKey);

    List<Map<String, dynamic>> parsedSessions = [];

    if (savedSessions != null && savedSessions.isNotEmpty) {
      try {
        final decoded = jsonDecode(savedSessions) as List<dynamic>;
        parsedSessions = decoded
            .map((item) => _normalizeSession(item as Map<String, dynamic>))
            .toList();
      } catch (_) {
        parsedSessions = [];
      }
    } else if (legacyChat != null && legacyChat.isNotEmpty) {
      try {
        final decoded = jsonDecode(legacyChat) as List<dynamic>;
        final legacyMessages = decoded
            .map((item) => _normalizeMessage(item as Map<String, dynamic>))
            .toList();
        parsedSessions = [
          _buildSession(
            id: _createSessionId(),
            title: _deriveSessionTitle(legacyMessages),
            createdAt: DateTime.now().toIso8601String(),
            updatedAt: DateTime.now().toIso8601String(),
            isPinned: false,
            items: legacyMessages,
          ),
        ];
      } catch (_) {
        parsedSessions = [];
      }
    }

    if (parsedSessions.isEmpty) {
      parsedSessions = [_buildBlankSession()];
    }

    final activeId =
        parsedSessions.any((session) => session['id'] == savedActiveId)
        ? savedActiveId ?? parsedSessions.first['id'].toString()
        : parsedSessions.first['id'].toString();

    if (!mounted) {
      return;
    }

    setState(() {
      chatSessions
        ..clear()
        ..addAll(parsedSessions);
      currentSessionId = activeId;
      messages
        ..clear()
        ..addAll(_messagesForSession(activeId));
    });

    await persistSessions();
    scrollToBottom();
  }

  Future<void> loadCloudBootstrapData() async {
    try {
      final response = await _getWithAuthRetry(
        '/sync/bootstrap',
        headers: {'Authorization': 'Bearer $_cloudToken'},
      );

      final Map<String, dynamic> data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : {};

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await loadChatSessions();
        return;
      }

      final sessionsRaw = (data['sessions'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final messagesRaw = (data['messages'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final row in messagesRaw) {
        final sid = (row['sessionId'] ?? '').toString();
        grouped.putIfAbsent(sid, () => []);
        grouped[sid]!.add({
          'id': (row['id'] ?? '').toString(),
          'role': (row['role'] ?? '').toString(),
          'text': (row['text'] ?? '').toString(),
          'time': (row['time'] ?? DateTime.now().toIso8601String()).toString(),
          'type': (row['type'] ?? 'chat').toString(),
          'code': (row['code'] ?? '').toString(),
          'imagePrompt': (row['imagePrompt'] ?? '').toString(),
          'videoPrompt': (row['videoPrompt'] ?? '').toString(),
          'action': (row['action'] ?? '').toString(),
          'url': (row['url'] ?? '').toString(),
          'info': (row['info'] ?? '').toString(),
          'suggestions': (row['suggestions'] as List<dynamic>? ?? const [])
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList(),
          'starred': row['starred'] == true,
        });
      }

      List<Map<String, dynamic>> parsedSessions = sessionsRaw.map((row) {
        final sid = (row['id'] ?? '').toString();
        return _buildSession(
          id: sid.isNotEmpty ? sid : _createSessionId(),
          title: (row['title'] ?? 'New Chat').toString(),
          createdAt: (row['createdAt'] ?? DateTime.now().toIso8601String())
              .toString(),
          updatedAt: (row['updatedAt'] ?? DateTime.now().toIso8601String())
              .toString(),
          isPinned: row['isPinned'] == true,
          items: grouped[sid] ?? const [],
        );
      }).toList();

      if (parsedSessions.isEmpty) {
        parsedSessions = [_buildBlankSession()];
      }

      final activeId = parsedSessions.first['id'].toString();

      if (!mounted) {
        return;
      }

      setState(() {
        chatSessions
          ..clear()
          ..addAll(parsedSessions);
        currentSessionId = activeId;
        messages
          ..clear()
          ..addAll(_messagesForSession(activeId));
      });

      await persistSessions();
      scrollToBottom();
    } catch (_) {
      await loadChatSessions();
    }
  }

  Map<String, dynamic> _buildBlankSession() {
    final now = DateTime.now().toIso8601String();
    return _buildSession(
      id: _createSessionId(),
      title: 'New Chat',
      createdAt: now,
      updatedAt: now,
      isPinned: false,
      items: [],
    );
  }

  Map<String, dynamic> _buildSession({
    required String id,
    required String title,
    required String createdAt,
    required String updatedAt,
    bool isPinned = false,
    required List<Map<String, dynamic>> items,
  }) {
    return {
      'id': id,
      'title': title,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'isPinned': isPinned,
      'items': items,
    };
  }

  Map<String, dynamic> _normalizeSession(Map<String, dynamic> raw) {
    final items = (raw['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(_normalizeMessage)
        .toList();

    return _buildSession(
      id: raw['id']?.toString().trim().isNotEmpty == true
          ? raw['id'].toString()
          : _createSessionId(),
      title: raw['title']?.toString().trim().isNotEmpty == true
          ? raw['title'].toString()
          : _deriveSessionTitle(items),
      createdAt:
          raw['createdAt']?.toString() ?? DateTime.now().toIso8601String(),
      updatedAt:
          raw['updatedAt']?.toString() ?? DateTime.now().toIso8601String(),
      isPinned: raw['isPinned'] == true,
      items: items,
    );
  }

  Map<String, dynamic> _normalizeMessage(Map<String, dynamic> item) {
    final suggestionsRaw =
        (item['suggestions'] as List<dynamic>? ?? const [])
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();

    return {
      'id': item['id']?.toString() ?? '',
      'role': item['role']?.toString() ?? '',
      'text': item['text']?.toString() ?? '',
      'time': item['time']?.toString() ?? '',
      'type': item['type']?.toString() ?? 'chat',
      'code': item['code']?.toString() ?? '',
      'imagePrompt': item['imagePrompt']?.toString() ?? '',
      'videoPrompt': item['videoPrompt']?.toString() ?? '',
      'action': item['action']?.toString() ?? '',
      'url': item['url']?.toString() ?? '',
      'info': item['info']?.toString() ?? '',
      'suggestions': suggestionsRaw,
      'starred': item['starred'] == true,
    };
  }

  String _createSessionId() => DateTime.now().microsecondsSinceEpoch.toString();

  List<Map<String, dynamic>> _messagesForSession(String sessionId) {
    final session = chatSessions.cast<Map<String, dynamic>?>().firstWhere(
      (item) => item?['id'] == sessionId,
      orElse: () => null,
    );

    if (session == null) {
      return [];
    }

    final items = (session['items'] as List<dynamic>? ?? const []);
    return items
        .whereType<Map<String, dynamic>>()
        .map(_normalizeMessage)
        .toList();
  }

  String _deriveSessionTitle(List<Map<String, dynamic>> items) {
    for (final item in items) {
      if ((item['role'] ?? '') == 'user') {
        final text = (item['text'] ?? '').toString().trim();
        if (text.isNotEmpty) {
          return text.length > 28 ? '${text.substring(0, 28)}...' : text;
        }
      }
    }
    return 'New Chat';
  }

  Future<void> persistSessions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageChatSessionsKey, jsonEncode(chatSessions));
    await prefs.setString(_storageActiveChatIdKey, currentSessionId);
  }

  Future<void> saveMessages() async {
    final index = chatSessions.indexWhere(
      (session) => session['id'] == currentSessionId,
    );

    final now = DateTime.now().toIso8601String();
    final title = _deriveSessionTitle(messages);

    if (index == -1) {
      chatSessions.insert(
        0,
        _buildSession(
          id: currentSessionId.isEmpty ? _createSessionId() : currentSessionId,
          title: title,
          createdAt: now,
          updatedAt: now,
          isPinned: false,
          items: List<Map<String, dynamic>>.from(messages),
        ),
      );
      currentSessionId = chatSessions.first['id'].toString();
    } else {
      final existing = chatSessions[index];
      chatSessions[index] = _buildSession(
        id: existing['id'].toString(),
        title: title,
        createdAt: existing['createdAt']?.toString() ?? now,
        updatedAt: now,
        isPinned: existing['isPinned'] == true,
        items: List<Map<String, dynamic>>.from(messages),
      );
      final session = chatSessions.removeAt(index);
      final insertAt = session['isPinned'] == true
          ? 0
          : chatSessions.where((item) => item['isPinned'] == true).length;
      chatSessions.insert(insertAt, session);
    }

    await persistSessions();
    await pushSnapshotToCloud();
  }

  Future<void> pushSnapshotToCloud() async {
    if (!isCloudConnected) {
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final notesRaw = prefs.getString(_storageNotesKey);
      final tasksRaw = prefs.getString(_storageTasksKey);
      final notes = notesRaw != null && notesRaw.isNotEmpty
          ? (jsonDecode(notesRaw) as List<dynamic>)
          : <dynamic>[];
      final tasks = tasksRaw != null && tasksRaw.isNotEmpty
          ? (jsonDecode(tasksRaw) as List<dynamic>)
          : <dynamic>[];

      final sessions = chatSessions.map((s) {
        return {
          'id': s['id'],
          'title': s['title'],
          'createdAt': s['createdAt'],
          'updatedAt': s['updatedAt'],
          'isPinned': s['isPinned'] == true,
        };
      }).toList();

      final messagesPayload = <Map<String, dynamic>>[];
      for (final session in chatSessions) {
        final sid = session['id']?.toString() ?? '';
        final items = (session['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>();
        for (final m in items) {
          messagesPayload.add({
            'sessionId': sid,
            'role': (m['role'] ?? '').toString(),
            'text': (m['text'] ?? '').toString(),
            'time': (m['time'] ?? '').toString(),
            'type': (m['type'] ?? 'chat').toString(),
            'code': (m['code'] ?? '').toString(),
            'imagePrompt': (m['imagePrompt'] ?? '').toString(),
            'videoPrompt': (m['videoPrompt'] ?? '').toString(),
            'action': (m['action'] ?? '').toString(),
            'url': (m['url'] ?? '').toString(),
            'info': (m['info'] ?? '').toString(),
            'suggestions': (m['suggestions'] as List<dynamic>? ?? const [])
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList(),
            'starred': m['starred'] == true,
          });
        }
      }

      await _postJsonWithRetry(
        '/sync/import',
        {
          'sessions': sessions,
          'messages': messagesPayload,
          'notes': notes,
          'tasks': tasks,
        },
        retries: 1,
        headers: {'Authorization': 'Bearer $_cloudToken'},
      );
    } catch (_) {}
  }

  Future<void> createNewChat() async {
    await stopSpeaking();

    final fresh = _buildBlankSession();

    setState(() {
      controller.clear();
      historySearchController.clear();
      historySearchText = '';
      messages.clear();
      currentSessionId = fresh['id'].toString();
      final insertAt = chatSessions
          .where((item) => item['isPinned'] == true)
          .length;
      chatSessions.insert(insertAt, fresh);
    });

    await persistSessions();
  }

  Future<void> openSession(String sessionId) async {
    await stopSpeaking();

    final nextMessages = _messagesForSession(sessionId);

    if (!mounted) {
      return;
    }

    setState(() {
      currentSessionId = sessionId;
      messages
        ..clear()
        ..addAll(nextMessages);
    });

    await persistSessions();
    scrollToBottom();
  }

  Future<void> reuseLastPrompt() async {
    final prompt = lastUserPrompt;
    if (prompt.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No previous prompt found.')),
      );
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      controller.value = TextEditingValue(
        text: prompt,
        selection: TextSelection.collapsed(offset: prompt.length),
      );
    });
  }

  int _lastUserMessageIndex() {
    for (int i = messages.length - 1; i >= 0; i--) {
      if ((messages[i]['role'] ?? '') == 'user') {
        return i;
      }
    }
    return -1;
  }

  Future<void> regenerateFromLastPrompt() async {
    if (isLoading) {
      return;
    }

    final lastUserIndex = _lastUserMessageIndex();
    if (lastUserIndex == -1) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No previous prompt to regenerate.')),
      );
      return;
    }

    final prompt = (messages[lastUserIndex]['text'] ?? '').toString().trim();
    if (prompt.isEmpty) {
      return;
    }

    // Remove old assistant response(s) after the latest user prompt,
    // then fetch a fresh one for the same prompt.
    setState(() {
      if (lastUserIndex + 1 < messages.length) {
        messages.removeRange(lastUserIndex + 1, messages.length);
      }
      controller.value = TextEditingValue(
        text: prompt,
        selection: TextSelection.collapsed(offset: prompt.length),
      );
    });

    await saveMessages();
    await _submitPrompt(prompt, addUserBubble: false, clearComposer: false);
  }

  Future<void> editAndResendMessage(Map<String, dynamic> target) async {
    final index = messages.indexOf(target);
    if (index == -1) {
      return;
    }

    if ((messages[index]['role'] ?? '') != 'user') {
      return;
    }

    final existingText = (messages[index]['text'] ?? '').toString();
    final input = TextEditingController(text: existingText);

    final updatedText = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit And Resend'),
          content: TextField(
            controller: input,
            autofocus: true,
            maxLines: 6,
            decoration: const InputDecoration(hintText: 'Update your message'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, input.text.trim()),
              child: const Text('Resend'),
            ),
          ],
        );
      },
    );

    final nextText = (updatedText ?? '').trim();
    if (nextText.isEmpty) {
      return;
    }

    setState(() {
      messages.removeRange(index, messages.length);
      controller.value = TextEditingValue(
        text: nextText,
        selection: TextSelection.collapsed(offset: nextText.length),
      );
    });

    await saveMessages();
    await _submitPrompt(nextText, addUserBubble: true, clearComposer: true);
  }

  Future<void> deleteSession(String sessionId) async {
    if (chatSessions.length <= 1) {
      await clearChat();
      return;
    }

    final index = chatSessions.indexWhere((item) => item['id'] == sessionId);
    if (index == -1) {
      return;
    }

    chatSessions.removeAt(index);

    if (currentSessionId == sessionId) {
      currentSessionId = chatSessions.first['id'].toString();
      messages
        ..clear()
        ..addAll(_messagesForSession(currentSessionId));
    }

    if (mounted) {
      setState(() {});
    }

    await persistSessions();
  }

  Future<void> togglePinSession(String sessionId) async {
    final index = chatSessions.indexWhere((item) => item['id'] == sessionId);
    if (index == -1) {
      return;
    }

    final updated = Map<String, dynamic>.from(chatSessions[index]);
    updated['isPinned'] = !(updated['isPinned'] == true);
    chatSessions[index] = updated;
    chatSessions.sort((a, b) {
      final aPinned = a['isPinned'] == true ? 1 : 0;
      final bPinned = b['isPinned'] == true ? 1 : 0;
      if (aPinned != bPinned) {
        return bPinned.compareTo(aPinned);
      }
      return (b['updatedAt'] ?? '').toString().compareTo(
        (a['updatedAt'] ?? '').toString(),
      );
    });

    if (mounted) {
      setState(() {});
    }

    await persistSessions();
  }

  Future<void> renameSessionDialog(String sessionId) async {
    final index = chatSessions.indexWhere((item) => item['id'] == sessionId);
    if (index == -1) {
      return;
    }

    final input = TextEditingController(
      text: chatSessions[index]['title']?.toString() ?? '',
    );

    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename Chat'),
          content: TextField(
            controller: input,
            autofocus: true,
            maxLength: 40,
            decoration: const InputDecoration(hintText: 'Enter chat title'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, input.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (newTitle == null || newTitle.isEmpty) {
      return;
    }

    final updated = Map<String, dynamic>.from(chatSessions[index]);
    updated['title'] = newTitle;
    updated['updatedAt'] = DateTime.now().toIso8601String();
    chatSessions[index] = updated;

    if (mounted) {
      setState(() {});
    }

    await persistSessions();
  }

  Future<void> exportCurrentChat() async {
    final session = chatSessions.cast<Map<String, dynamic>?>().firstWhere(
      (item) => item?['id'] == currentSessionId,
      orElse: () => null,
    );

    if (session == null) {
      return;
    }

    final transcript = (session['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) {
          final role = (item['role'] ?? 'ai').toString().toUpperCase();
          final text = (item['text'] ?? '').toString();
          return '[$role] $text';
        })
        .join('\n\n');

    final exportJson = const JsonEncoder.withIndent('  ').convert(session);
    final title = session['title']?.toString() ?? 'chat-session';

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Export Chat'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                const Text('Choose export format:'),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                await copyToClipboard(transcript, 'Chat text export');
              },
              icon: const Icon(Icons.text_snippet_outlined),
              label: const Text('Copy TXT'),
            ),
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                await copyToClipboard(exportJson, 'Chat JSON export');
              },
              icon: const Icon(Icons.data_object_rounded),
              label: const Text('Copy JSON'),
            ),
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                await exportToLocalFile(
                  title: title,
                  extension: 'txt',
                  content: transcript,
                );
              },
              icon: const Icon(Icons.save_alt_rounded),
              label: const Text('Save TXT'),
            ),
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                await exportToLocalFile(
                  title: title,
                  extension: 'json',
                  content: exportJson,
                );
              },
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('Save JSON'),
            ),
          ],
        );
      },
    );
  }

  String _safeFileSegment(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    if (cleaned.isEmpty) {
      return 'chat';
    }
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }

  String _buildExportFileName(String title, String extension) {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return '${_safeFileSegment(title)}_$stamp.$extension';
  }

  Future<void> exportToLocalFile({
    required String title,
    required String extension,
    required String content,
  }) async {
    if (content.trim().isEmpty) {
      return;
    }

    if (kIsWeb) {
      await copyToClipboard(content, 'Export content');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Web export fallback: copied to clipboard.'),
        ),
      );
      return;
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final fileName = _buildExportFileName(title, extension);
      final file = File('${directory.path}/$fileName');
      await file.writeAsString(content, flush: true);

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved: ${file.path}')));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save export file.')),
      );
    }
  }

  String detectLanguage(String text) {
    final lower = text.toLowerCase().trim();
    final hindiRegex = RegExp(r'[\u0900-\u097F]');
    if (hindiRegex.hasMatch(text)) {
      return 'hi';
    }

    const hinglishWords = [
      'kya',
      'kaise',
      'mujhe',
      'mera',
      'meri',
      'hai',
      'kar',
      'karo',
      'batao',
      'dikhao',
      'note',
      'task',
      'banao',
      'show',
      'add',
    ];

    for (final word in hinglishWords) {
      if (lower.contains(word)) {
        return 'hinglish';
      }
    }

    return 'en';
  }

  Future<void> addOfflineNote(String text) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageNotesKey);

    List<dynamic> notes = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        notes = jsonDecode(raw) as List<dynamic>;
      } catch (_) {}
    }

    notes.insert(0, {
      'text': text,
      'createdAt': DateTime.now().toIso8601String(),
    });

    await prefs.setString(_storageNotesKey, jsonEncode(notes));
  }

  Future<void> addOfflineTask(String text) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageTasksKey);

    List<dynamic> tasks = [];
    if (raw != null && raw.isNotEmpty) {
      tasks = jsonDecode(raw) as List<dynamic>;
    }

    tasks.insert(0, {
      'title': text,
      'done': false,
      'priority': 'Medium',
      'createdAt': DateTime.now().toIso8601String(),
    });

    await prefs.setString(_storageTasksKey, jsonEncode(tasks));
  }

  Future<List<Map<String, dynamic>>> _loadActionLog() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageActionLogKey);
    if (raw == null || raw.trim().isEmpty) {
      return [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveActionLog(List<Map<String, dynamic>> actions) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageActionLogKey, jsonEncode(actions));
  }

  Future<void> _logAction({
    required String type,
    required Map<String, dynamic> payload,
  }) async {
    final actions = await _loadActionLog();
    actions.insert(0, {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'type': type,
      'payload': payload,
      'time': DateTime.now().toIso8601String(),
    });
    if (actions.length > 150) {
      actions.removeRange(150, actions.length);
    }
    await _saveActionLog(actions);
  }

  Future<void> _listActionHistoryInChat() async {
    final actions = await _loadActionLog();
    if (actions.isEmpty) {
      await _appendRoutineStatusMessage('No action history yet.');
      return;
    }

    final lines = actions.take(15).map((item) {
      final type = (item['type'] ?? '').toString();
      final payload = (item['payload'] as Map<String, dynamic>? ?? const {});
      final label = (payload['title'] ??
              payload['text'] ??
              payload['name'] ??
              payload['target'] ??
              '')
          .toString();
      final time = (item['time'] ?? '').toString();
      final shortTime = time.length >= 16 ? time.substring(0, 16) : time;
      return '- [$shortTime] $type ${label.isNotEmpty ? "| $label" : ""}';
    }).toList();

    await _appendRoutineStatusMessage('Action history:\n${lines.join('\n')}');
  }

  Future<void> _sendGoogleEmailWithConfirmation(
    String info, {
    bool auto = false,
  }) async {
    final parsed = _decodeActionInfo(info);
    final to = (parsed['to'] ?? '').toString().trim();
    final subject = (parsed['subject'] ?? '').toString().trim();
    final body = (parsed['body'] ?? '').toString().trim();

    if (to.isEmpty || subject.isEmpty || body.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Email draft is incomplete.')),
        );
      }
      return;
    }

    if (!isCloudConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cloud login required to send Gmail.')),
        );
      }
      return;
    }

    final shouldSend = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Email Send'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('To: $to'),
              const SizedBox(height: 8),
              Text('Subject: $subject'),
              const SizedBox(height: 12),
              const Text(
                'Body',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(body),
              const SizedBox(height: 10),
              Text(
                auto
                    ? 'Voice command requested this email. Please confirm send.'
                    : 'Please confirm to send this email.',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );

    if (shouldSend != true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Email sending cancelled.')),
        );
      }
      return;
    }

    try {
      final response = await _postJsonWithRetry(
        '/integrations/google/gmail/send',
        {
          'to': to,
          'subject': subject,
          'body': body,
        },
        headers: {'Authorization': 'Bearer $_cloudToken'},
      );

      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _logAction(
          type: 'gmail_send',
          payload: {
            'to': to,
            'subject': subject,
          },
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Gmail sent successfully.')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                (data['error'] ?? 'Gmail send failed').toString(),
              ),
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send Gmail right now.')),
        );
      }
    }
  }

  Future<void> _runPushDoctorAction({bool auto = false}) async {
    if (!isCloudConnected || _cloudToken.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cloud login required for Push Doctor.')),
        );
      }
      return;
    }

    try {
      final response = await http
          .get(
            Uri.parse('$apiBaseUrl/notifications/doctor'),
            headers: {'Authorization': 'Bearer $_cloudToken'},
          )
          .timeout(const Duration(seconds: 25));

      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final summary = (data['summary'] ?? 'Push doctor complete').toString();
        final missing = (data['missing'] as List<dynamic>? ?? const [])
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
        final statusText = missing.isEmpty
            ? summary
            : '$summary\nMissing: ${missing.join(' | ')}';
        await _appendRoutineStatusMessage('Push Doctor:\n$statusText');
        await _logAction(
          type: 'push_doctor',
          payload: {'summary': summary, 'missingCount': missing.length},
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                auto ? 'Push Doctor auto-complete' : 'Push Doctor complete',
              ),
            ),
          );
        }
      } else {
        final errorText = (data['error'] ?? 'Push doctor failed').toString();
        await _appendRoutineStatusMessage('Push Doctor failed: $errorText');
      }
    } catch (_) {
      await _appendRoutineStatusMessage('Push Doctor failed: network/server issue.');
    }
  }

  Future<void> _runPushSelfTestAction({bool auto = false}) async {
    if (!isCloudConnected || _cloudToken.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cloud login required for push self-test.')),
        );
      }
      return;
    }

    try {
      final response = await _postJsonWithRetry(
        '/notifications/self-test',
        {
          'title': 'FLOWGNIMAG Chat Self-Test',
          'body': 'Triggered from chat command action.',
        },
        headers: {'Authorization': 'Bearer $_cloudToken'},
      );

      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final sent = (data['sent'] as num?)?.toInt() ?? 0;
        final invalid = (data['invalid'] as num?)?.toInt() ?? 0;
        final summary = (data['summary'] ?? 'Push self-test complete').toString();
        await _appendRoutineStatusMessage(
          'Push Self-Test:\n$summary\nsent=$sent invalid=$invalid',
        );
        await _logAction(
          type: 'push_self_test',
          payload: {'sent': sent, 'invalid': invalid},
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                auto ? 'Push self-test auto-complete' : 'Push self-test complete',
              ),
            ),
          );
        }
      } else {
        final summary = (data['summary'] ?? '').toString();
        final errorText = (data['error'] ?? 'Push self-test failed').toString();
        final missing = (data['missing'] as List<dynamic>? ?? const [])
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
        final body = summary.isNotEmpty ? '$errorText | $summary' : errorText;
        final withMissing = missing.isEmpty
            ? body
            : '$body\nMissing: ${missing.join(' | ')}';
        await _appendRoutineStatusMessage('Push Self-Test failed:\n$withMissing');
      }
    } catch (_) {
      await _appendRoutineStatusMessage(
        'Push Self-Test failed: network/server issue.',
      );
    }
  }

  Future<List<String>> getOfflineNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageNotesKey);

    if (raw == null || raw.isEmpty) {
      return [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (item) => (item as Map<String, dynamic>)['text']?.toString() ?? '',
          )
          .where((item) => item.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<dynamic>> getOfflineTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageTasksKey);

    if (raw == null || raw.isEmpty) {
      return [];
    }
    return jsonDecode(raw) as List<dynamic>;
  }

  Future<String> processOfflineCommand(String text) async {
    final lower = text.toLowerCase().trim();
    final language = detectLanguage(text);

    final isAddNote =
        lower.startsWith('add note ') ||
        lower.startsWith('note add ') ||
        lower.startsWith('नोट जोड़ो ');

    final isCreateTask =
        lower.startsWith('create task ') ||
        lower.startsWith('task create ') ||
        lower.startsWith('टास्क बनाओ ') ||
        lower.startsWith('task banao ');

    final isShowNotes =
        lower == 'show notes' ||
        lower == 'notes show' ||
        lower == 'नोट्स दिखाओ' ||
        lower == 'notes dikhao';

    final isShowTasks =
        lower == 'show tasks' ||
        lower == 'tasks show' ||
        lower == 'टास्क दिखाओ' ||
        lower == 'tasks dikhao';

    final isShowPendingTasks =
        lower == 'show pending tasks' ||
        lower == 'pending tasks dikhao' ||
        lower == 'पेंडिंग टास्क दिखाओ';

    if (isAddNote) {
      final noteText = text
          .replaceFirst(
            RegExp(r'^(add note|note add|नोट जोड़ो)\s*', caseSensitive: false),
            '',
          )
          .trim();

      if (noteText.isEmpty) {
        if (language == 'hi') {
          return 'Kripya note ka text likhein.';
        }
        if (language == 'hinglish') {
          return 'Please note ka text likho.';
        }
        return 'Please provide note text.';
      }

      await addOfflineNote(noteText);

      if (language == 'hi') {
        return 'Note add ho gaya: "$noteText"';
      }
      if (language == 'hinglish') {
        return 'Note add ho gaya: "$noteText"';
      }
      return 'Note added: "$noteText"';
    }

    if (isCreateTask) {
      final taskText = text
          .replaceFirst(
            RegExp(
              r'^(create task|task create|टास्क बनाओ|task banao)\s*',
              caseSensitive: false,
            ),
            '',
          )
          .trim();

      if (taskText.isEmpty) {
        if (language == 'hi') {
          return 'Kripya task ka text likhein.';
        }
        if (language == 'hinglish') {
          return 'Please task ka text likho.';
        }
        return 'Please provide task text.';
      }

      await addOfflineTask(taskText);

      if (language == 'hi') {
        return 'Task create ho gaya: "$taskText"';
      }
      if (language == 'hinglish') {
        return 'Task create ho gaya: "$taskText"';
      }
      return 'Task created: "$taskText"';
    }

    if (isShowNotes) {
      final notes = await getOfflineNotes();

      if (notes.isEmpty) {
        if (language == 'hi') {
          return 'Aapke paas koi saved note nahi hai.';
        }
        if (language == 'hinglish') {
          return 'Aapke paas koi saved note nahi hai.';
        }
        return 'You have no saved notes.';
      }

      final preview = notes.take(5).toList();
      if (language == 'hi') {
        return 'Aapke notes:\n- ${preview.join('\n- ')}';
      }
      if (language == 'hinglish') {
        return 'Aapke notes:\n- ${preview.join('\n- ')}';
      }
      return 'Your notes:\n- ${preview.join('\n- ')}';
    }

    if (isShowTasks) {
      final tasks = await getOfflineTasks();

      if (tasks.isEmpty) {
        if (language == 'hi') {
          return 'Aapke paas koi saved task nahi hai.';
        }
        if (language == 'hinglish') {
          return 'Aapke paas koi saved task nahi hai.';
        }
        return 'You have no saved tasks.';
      }

      final preview = tasks.take(5).map((task) {
        final item = task as Map<String, dynamic>;
        final done = item['done'] == true ? 'DONE' : '-';
        return '$done ${item['title']}';
      }).toList();

      if (language == 'hi') {
        return 'Aapke tasks:\n${preview.join('\n')}';
      }
      if (language == 'hinglish') {
        return 'Aapke tasks:\n${preview.join('\n')}';
      }
      return 'Your tasks:\n${preview.join('\n')}';
    }

    if (isShowPendingTasks) {
      final tasks = await getOfflineTasks();
      final pending = tasks.where((task) {
        final item = task as Map<String, dynamic>;
        return item['done'] != true;
      }).toList();

      if (pending.isEmpty) {
        if (language == 'hi') {
          return 'Koi pending task nahi hai.';
        }
        if (language == 'hinglish') {
          return 'Koi pending task nahi hai.';
        }
        return 'You have no pending tasks.';
      }

      final preview = pending.take(5).map((task) {
        final item = task as Map<String, dynamic>;
        return '- ${item['title']}';
      }).toList();

      if (language == 'hi') {
        return 'Pending tasks:\n${preview.join('\n')}';
      }
      if (language == 'hinglish') {
        return 'Pending tasks:\n${preview.join('\n')}';
      }
      return 'Pending tasks:\n${preview.join('\n')}';
    }

    if (language == 'hi') {
      return 'Offline mode active hai.\nTry commands:\n- नोट जोड़ो दूध लाना है\n- टास्क बनाओ प्रोजेक्ट पूरा करना है\n- नोट्स दिखाओ\n- टास्क दिखाओ\n- पेंडिंग टास्क दिखाओ';
    }

    if (language == 'hinglish') {
      return 'Offline mode active hai.\nYe commands try karo:\n- add note buy milk\n- create task finish project\n- notes dikhao\n- tasks dikhao\n- pending tasks dikhao';
    }

    return 'Offline mode is active.\nTry commands like:\n- add note buy milk\n- create task finish project\n- show notes\n- show tasks\n- show pending tasks';
  }

  Future<void> stopSpeaking() async {
    await flutterTts.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      isSpeaking = false;
      _currentlySpeakingText = '';
    });
    widget.onSpeakingChanged?.call(false);
    _resumeWakeModeIfNeeded();
  }

  Future<void> stopListening() async {
    try {
      await speech.stop();
      await speech.cancel();
    } catch (_) {}

    _lastRecognizedWords = '';
    _wakeWordDetected = false;

    if (!mounted) {
      return;
    }

    setState(() => isListening = false);
    widget.onListeningChanged?.call(false);
  }

  bool _containsWakeWord(String value) {
    final text = value.toLowerCase().trim();
    if (text.isEmpty) {
      return false;
    }

    for (final wakeWord in _wakeWords) {
      final escaped = RegExp.escape(wakeWord);
      final regex = RegExp('\\b$escaped\\b', caseSensitive: false);
      if (regex.hasMatch(text)) {
        return true;
      }
    }
    return false;
  }

  String _extractWakeCommand(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      return '';
    }

    final lower = text.toLowerCase();
    var bestIndex = -1;
    var bestLength = 0;
    for (final wakeWord in _wakeWords) {
      final idx = lower.indexOf(wakeWord);
      if (idx >= 0 && (bestIndex == -1 || idx < bestIndex)) {
        bestIndex = idx;
        bestLength = wakeWord.length;
      }
    }

    if (bestIndex < 0) {
      return text;
    }

    final start = bestIndex + bestLength;
    if (start >= text.length) {
      return '';
    }

    return text
        .substring(start)
        .replaceFirst(RegExp(r'^[,\s.:;-]+'), '')
        .trim();
  }

  Future<void> _setWakeModeEnabled(
    bool enabled, {
    bool showToast = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_wakeModeKey, enabled);

    if (!mounted) {
      return;
    }

    setState(() {
      wakeModeEnabled = enabled;
      _wakeWordDetected = false;
    });

    if (!enabled) {
      if (isListening) {
        await stopListening();
      }
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wake mode turned off')),
        );
      }
      return;
    }

    if (!voiceEnabled) {
      await prefs.setBool(_wakeModeKey, false);
      if (!mounted) {
        return;
      }
      setState(() {
        wakeModeEnabled = false;
      });
      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enable voice input first.')),
        );
      }
      return;
    }

    if (showToast && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Wake mode active. Say: "Hey Flow" then your command.'),
        ),
      );
    }

    await _startWakeListening();
  }

  Future<void> _resumeWakeModeIfNeeded() async {
    if (!mounted ||
        !wakeModeEnabled ||
        !voiceEnabled ||
        isListening ||
        isLoading ||
        isSpeaking) {
      return;
    }
    await Future.delayed(const Duration(milliseconds: 250));
    if (mounted && wakeModeEnabled && !isListening && !isLoading && !isSpeaking) {
      await _startWakeListening();
    }
  }

  Future<void> _startWakeListening() async {
    if (!mounted || !wakeModeEnabled || !voiceEnabled || isListening || isLoading) {
      return;
    }

    if (isSpeaking) {
      return;
    }

    _wakeWordDetected = false;
    _lastRecognizedWords = '';

    final available = await speech.initialize(
      onStatus: (status) async {
        if (!mounted) {
          return;
        }
        if (status == 'done' || status == 'notListening') {
          setState(() => isListening = false);
          widget.onListeningChanged?.call(false);
          if (wakeModeEnabled) {
            await _resumeWakeModeIfNeeded();
          }
        }
      },
      onError: (_) async {
        if (!mounted) {
          return;
        }
        setState(() => isListening = false);
        widget.onListeningChanged?.call(false);
        if (wakeModeEnabled) {
          await _resumeWakeModeIfNeeded();
        }
      },
    );

    if (!available) {
      await _setWakeModeEnabled(false, showToast: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mic is not available right now.')),
        );
      }
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() => isListening = true);
    widget.onListeningChanged?.call(true);

    await speech.listen(
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: stt.ListenMode.dictation,
      ),
      onResult: (result) async {
        final words = result.recognizedWords.trim();
        if (!mounted || words.isEmpty) {
          return;
        }
        if (words == _lastRecognizedWords && !result.finalResult) {
          return;
        }
        _lastRecognizedWords = words;

        if (!_wakeWordDetected) {
          if (_containsWakeWord(words)) {
            _wakeWordDetected = true;
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Wake word detected. Listening...')),
              );
            }
          } else {
            return;
          }
        }

        final command = _extractWakeCommand(words);
        if (command.isNotEmpty) {
          setState(() {
            controller.value = TextEditingValue(
              text: command,
              selection: TextSelection.collapsed(offset: command.length),
            );
          });
        }

        if (result.finalResult) {
          final finalCommand = _extractWakeCommand(words).trim();
          await stopListening();
          if (finalCommand.isNotEmpty) {
            controller.value = TextEditingValue(
              text: finalCommand,
              selection: TextSelection.collapsed(offset: finalCommand.length),
            );
            await sendMessage();
          } else {
            await _resumeWakeModeIfNeeded();
          }
        }
      },
    );
  }

  Future<void> toggleListening() async {
    await loadSettings();

    if (!voiceEnabled) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Voice input is disabled in Settings.')),
      );
      return;
    }

    if (wakeModeEnabled) {
      await _setWakeModeEnabled(false, showToast: false);
    }

    if (isSpeaking) {
      await stopSpeaking();
    }

    if (isListening) {
      await stopListening();
      return;
    }

    await stopListening();
    controller.clear();
    _lastRecognizedWords = '';

    final available = await speech.initialize(
      onStatus: (status) async {
        if (status == 'done' || status == 'notListening') {
          await stopListening();
        }
      },
      onError: (_) async {
        await stopListening();
      },
    );

    if (!available) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mic is not available right now.')),
      );
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() => isListening = true);
    widget.onListeningChanged?.call(true);

    await speech.listen(
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: stt.ListenMode.confirmation,
      ),
      onResult: (result) async {
        final words = result.recognizedWords.trim();
        if (!mounted || words.isEmpty) {
          return;
        }
        if (words == _lastRecognizedWords && !result.finalResult) {
          return;
        }

        _lastRecognizedWords = words;

        setState(() {
          controller.value = TextEditingValue(
            text: words,
            selection: TextSelection.collapsed(offset: words.length),
          );
        });

        if (result.finalResult) {
          final finalText = words;
          await stopListening();

          if (finalText.trim().isNotEmpty) {
            controller.value = TextEditingValue(
              text: finalText,
              selection: TextSelection.collapsed(offset: finalText.length),
            );
            await sendMessage();
          }
        }
      },
    );
  }

  Future<void> speakReply(String text) async {
    if (!autoSpeak || text.trim().isEmpty) {
      return;
    }

    if (isListening) {
      await stopListening();
    }

    await stopSpeaking();
    _currentlySpeakingText = text;
    await flutterTts.speak(text);
  }

  Future<void> speakManually(String text) async {
    if (text.trim().isEmpty) {
      return;
    }

    if (isListening) {
      await stopListening();
    }

    await stopSpeaking();

    if (!mounted) {
      return;
    }

    setState(() {
      _currentlySpeakingText = text;
    });

    await flutterTts.speak(text);
  }

  Future<void> generateImageFromPrompt(String prompt) async {
    if (prompt.trim().isEmpty || isGeneratingImage) {
      return;
    }

    setState(() {
      isGeneratingImage = true;
    });

    try {
      final response = await _postJsonWithRetry('/generate-image', {
        'prompt': prompt,
      });

      final Map<String, dynamic> data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : {};

      if (!mounted) {
        return;
      }

      if (response.statusCode == 200) {
        final imageDataUrl = (data['imageDataUrl'] ?? '').toString();

        if (imageDataUrl.trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image data missing in response.')),
          );
        } else {
          setState(() {
            messages.add({
              'role': 'ai',
              'text': 'Image generated successfully.',
              'time': DateTime.now().toIso8601String(),
              'type': 'generated_image',
              'code': '',
              'imagePrompt': prompt,
              'action': '',
              'url': imageDataUrl,
              'info': '',
              'starred': false,
            });
          });

          await saveMessages();
          scrollToBottom();
        }
      } else {
        final errorText = _attachRequestId(
          '${data['error'] ?? 'Image generation failed'}\n${data['details'] ?? ''}'
              .trim(),
          data,
          response,
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorText)));
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not generate image.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          isGeneratingImage = false;
        });
      }
    }
  }

  Future<void> generateVideoFromPrompt(String prompt) async {
    if (prompt.trim().isEmpty || isGeneratingVideo) {
      return;
    }

    setState(() {
      isGeneratingVideo = true;
    });

    try {
      final response = await _postJsonWithRetry('/generate-video', {
        'prompt': prompt,
      });

      final Map<String, dynamic> data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : {};

      if (!mounted) {
        return;
      }

      if (response.statusCode == 200) {
        final videoDataUrl = (data['videoDataUrl'] ?? '').toString();

        if (videoDataUrl.trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video data missing in response.')),
          );
        } else {
          setState(() {
            messages.add({
              'role': 'ai',
              'text': 'Video generated successfully.',
              'time': DateTime.now().toIso8601String(),
              'type': 'generated_video',
              'code': '',
              'imagePrompt': '',
              'videoPrompt': prompt,
              'action': '',
              'url': videoDataUrl,
              'info': '',
              'starred': false,
            });
          });

          await saveMessages();
          scrollToBottom();
        }
      } else {
        final errorText = _attachRequestId(
          '${data['error'] ?? 'Video generation failed'}\n${data['details'] ?? ''}'
              .trim(),
          data,
          response,
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorText)));
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not generate video.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          isGeneratingVideo = false;
        });
      }
    }
  }

  Future<void> _submitPrompt(
    String text, {
    required bool addUserBubble,
    required bool clearComposer,
  }) async {
    await loadSettings();

    if (isListening) {
      await stopListening();
    }

    if (text.isEmpty || isLoading) {
      return;
    }

    if (currentSessionId.isEmpty) {
      await createNewChat();
    }

    if (addUserBubble) {
      setState(() {
        messages.add({
          'role': 'user',
          'text': text,
          'time': DateTime.now().toIso8601String(),
          'type': 'chat',
          'code': '',
          'imagePrompt': '',
          'videoPrompt': '',
          'action': '',
          'url': '',
          'info': '',
          'starred': false,
        });
        isLoading = true;
      });
    } else {
      setState(() {
        isLoading = true;
      });
    }

    if (clearComposer) {
      controller.clear();
    }
    scrollToBottom();
    if (addUserBubble) {
      await saveMessages();
    }

    final normalizedText = text.toLowerCase().trim();
    final isDailyBriefingPrompt =
        normalizedText == 'daily briefing' ||
        normalizedText == 'daily brief' ||
        normalizedText == 'briefing';
    if (isDailyBriefingPrompt) {
      await _runDailyBriefing(addUserBubble: addUserBubble);
      return;
    }

    if (!widget.isOnlineMode) {
      final offlineReply = await processOfflineCommand(text);

      if (!mounted) {
        return;
      }

      setState(() {
        messages.add({
          'role': 'ai',
          'text': offlineReply,
          'time': DateTime.now().toIso8601String(),
          'type': 'chat',
          'code': '',
          'imagePrompt': '',
          'videoPrompt': '',
          'action': '',
          'url': '',
          'info': '',
          'suggestions': const <String>[],
          'starred': false,
        });
        isLoading = false;
      });

      await saveMessages();
      await speakReply(offlineReply);
      scrollToBottom();
      return;
    }

    try {
      final response = await _postJsonWithRetry(
        '/chat',
        {
          'message': text,
          'isOnlineMode': widget.isOnlineMode,
          'smartReply': smartReply,
          'assistantMode': assistantMode,
          'chatHistory': _chatHistoryPayload(),
          'persistToSession': isCloudConnected,
          'sessionId': isCloudConnected ? currentSessionId : null,
        },
        headers: isCloudConnected
            ? {'Authorization': 'Bearer $_cloudToken'}
            : null,
      );

      final Map<String, dynamic> data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : {};

      if (!mounted) {
        return;
      }

      if (response.statusCode == 200) {
        final aiReply = (data['reply'] ?? 'No reply received').toString();
        final action = (data['action'] ?? '').toString();
        final url = (data['url'] ?? '').toString();
        final info = (data['info'] ?? '').toString();
        final requiresApproval = data['requiresApproval'] == true;

        setState(() {
          messages.add({
            'role': 'ai',
            'text': aiReply,
            'time': DateTime.now().toIso8601String(),
            'type': (data['type'] ?? 'chat').toString(),
            'code': (data['code'] ?? '').toString(),
            'imagePrompt': (data['imagePrompt'] ?? '').toString(),
            'videoPrompt': (data['videoPrompt'] ?? '').toString(),
            'action': action,
            'url': url,
            'info': info,
            'requiresApproval': requiresApproval,
            'suggestions': (data['suggestions'] as List<dynamic>? ?? const [])
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList(),
            'starred': false,
          });
        });

        await saveMessages();
        if (action == 'create_note' ||
            action == 'create_task' ||
            action == 'set_timer' ||
            action == 'create_reminder' ||
            action == 'create_routine' ||
            action == 'run_routine' ||
            action == 'list_routines' ||
            action == 'create_event' ||
            action == 'list_events' ||
            action == 'delete_event' ||
            action == 'undo_action' ||
            action == 'list_actions' ||
            action == 'run_push_doctor' ||
            action == 'run_push_self_test' ||
            action == 'google_gmail_send_confirm' ||
            action == 'execute_goal_plan' ||
            action == 'add_knowledge' ||
            action == 'search_knowledge' ||
            action == 'create_workflow_job' ||
            action == 'list_workflow_jobs') {
          if (requiresApproval) {
            await saveMessages();
            await speakReply(aiReply);
            return;
          }
          await executeCommandAction(
            action: action,
            url: url,
            info: info,
            auto: true,
          );
        }
        await speakReply(aiReply);
      } else {
        final errorText = _attachRequestId(
          '${data['error'] ?? 'Server error'}\n${data['details'] ?? ''}'.trim(),
          data,
          response,
        );

        setState(() {
          messages.add({
            'role': 'ai',
            'text': errorText,
            'time': DateTime.now().toIso8601String(),
            'type': 'chat',
            'code': '',
            'imagePrompt': '',
            'videoPrompt': '',
            'action': '',
            'url': '',
            'info': '',
            'suggestions': const <String>[],
            'starred': false,
          });
        });

        await saveMessages();
      }
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        messages.add({
          'role': 'ai',
          'text':
              'Connection error.\nMake sure backend is running on $apiBaseUrl',
          'time': DateTime.now().toIso8601String(),
          'type': 'chat',
          'code': '',
          'imagePrompt': '',
          'videoPrompt': '',
          'action': '',
          'url': '',
          'info': '',
          'suggestions': const <String>[],
          'starred': false,
        });
      });

      await saveMessages();
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
        scrollToBottom();
      }
      await _resumeWakeModeIfNeeded();
    }
  }

  Future<void> _runDailyBriefing({required bool addUserBubble}) async {
    try {
      String reply = '';
      if (isCloudConnected && _cloudToken.trim().isNotEmpty) {
        final response = await _getWithAuthRetry(
          '/assistant/briefing',
          headers: {'Authorization': 'Bearer $_cloudToken'},
        );
        final data = response.body.isNotEmpty
            ? jsonDecode(response.body) as Map<String, dynamic>
            : <String, dynamic>{};
        if (response.statusCode >= 200 && response.statusCode < 300) {
          reply = (data['summary'] ?? 'Daily briefing ready.').toString();
        } else {
          reply = (data['error'] ?? 'Could not load daily briefing.').toString();
        }
      } else {
        final notes = await getOfflineNotes();
        final tasks = await getOfflineTasks();
        final open = tasks
            .where((t) => (t as Map<String, dynamic>)['done'] != true)
            .length;
        final done = tasks.length - open;
        reply =
            'Daily briefing ready. You have $open open task(s), $done completed task(s), and ${notes.length} note(s).';
      }

      if (!mounted) return;

      setState(() {
        messages.add({
          'role': 'ai',
          'text': reply,
          'time': DateTime.now().toIso8601String(),
          'type': 'chat',
          'code': '',
          'imagePrompt': '',
          'videoPrompt': '',
          'action': '',
          'url': '',
          'info': '',
          'suggestions': const <String>[
            'What should I prioritize first?',
            'Show upcoming calendar events',
            'List pending tasks'
          ],
          'starred': false,
        });
        isLoading = false;
      });
      await saveMessages();
      await speakReply(reply);
      scrollToBottom();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        messages.add({
          'role': 'ai',
          'text': 'Daily briefing failed. Try again in a moment.',
          'time': DateTime.now().toIso8601String(),
          'type': 'chat',
          'code': '',
          'imagePrompt': '',
          'videoPrompt': '',
          'action': '',
          'url': '',
          'info': '',
          'suggestions': const <String>[],
          'starred': false,
        });
        isLoading = false;
      });
      if (addUserBubble) {
        await saveMessages();
      }
    }
  }

  int _timerSecondsFromInfo(String info) {
    final match = RegExp(r'(\d{1,6})').firstMatch(info);
    if (match == null) {
      return 0;
    }
    return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  Map<String, dynamic> _decodeActionInfo(String info) {
    final raw = info.trim();
    if (raw.isEmpty) {
      return {};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return {'text': raw, 'title': raw};
  }

  Future<void> _saveReminderRecord({
    required String title,
    required DateTime scheduledAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageRemindersKey);

    List<dynamic> reminders = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        reminders = jsonDecode(raw) as List<dynamic>;
      } catch (_) {}
    }

    reminders.insert(0, {
      'title': title,
      'scheduledAt': scheduledAt.toIso8601String(),
      'createdAt': DateTime.now().toIso8601String(),
    });

    if (reminders.length > 200) {
      reminders = reminders.take(200).toList();
    }
    await prefs.setString(_storageRemindersKey, jsonEncode(reminders));
  }

  Future<void> _scheduleReminderNotification({
    required String title,
    required DateTime scheduledAt,
  }) async {
    await _ensureNotificationsReady();
    if (!_notificationsReady) {
      return;
    }

    final now = DateTime.now();
    final target = scheduledAt.isAfter(now)
        ? scheduledAt
        : now.add(const Duration(seconds: 5));
    final id = target.millisecondsSinceEpoch.remainder(2147483000);

    const androidDetails = AndroidNotificationDetails(
      'flowgnimag_reminders',
      'FLOWGNIMAG Reminders',
      channelDescription: 'Reminder alarms from FLOWGNIMAG assistant',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );

    await _notificationsPlugin.zonedSchedule(
      id,
      'FLOWGNIMAG Reminder',
      title,
      tz.TZDateTime.from(target, tz.local),
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: jsonEncode({
        'title': title,
        'scheduledAt': target.toIso8601String(),
      }),
    );

    await _saveReminderRecord(title: title, scheduledAt: target);
  }

  Future<void> _scheduleAssistantReminderFromInfo(
    String info, {
    bool auto = false,
  }) async {
    final parsed = _decodeActionInfo(info);
    final title =
        (parsed['title'] ?? parsed['text'] ?? parsed['message'] ?? '')
            .toString()
            .trim();
    if (title.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reminder text is missing.')),
        );
      }
      return;
    }

    DateTime? scheduledAt;
    final seconds = int.tryParse('${parsed['secondsFromNow'] ?? ''}') ?? 0;
    if (seconds > 0) {
      scheduledAt = DateTime.now().add(Duration(seconds: seconds));
    } else {
      final iso = (parsed['triggerAtIso'] ?? '').toString().trim();
      if (iso.isNotEmpty) {
        scheduledAt = DateTime.tryParse(iso)?.toLocal();
      }
    }
    scheduledAt ??= DateTime.now().add(const Duration(minutes: 1));

    await _scheduleReminderNotification(title: title, scheduledAt: scheduledAt);

    if (mounted) {
      final modeText = auto ? 'auto-scheduled' : 'scheduled';
      final clock =
          '${scheduledAt.hour.toString().padLeft(2, '0')}:${scheduledAt.minute.toString().padLeft(2, '0')}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reminder $modeText for $clock')),
      );
    }
  }

  Future<void> _startAssistantTimer(int seconds) async {
    if (seconds <= 0 || seconds > 86400) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid timer value.')),
        );
      }
      return;
    }

    _activeTimer?.cancel();
    _activeTimer = Timer(Duration(seconds: seconds), () async {
      if (!mounted) {
        return;
      }
      final doneText = 'Timer finished (${seconds}s).';
      setState(() {
        messages.add({
          'role': 'ai',
          'text': doneText,
          'time': DateTime.now().toIso8601String(),
          'type': 'command',
          'code': '',
          'imagePrompt': '',
          'videoPrompt': '',
          'action': 'show_info',
          'url': '',
          'info': doneText,
          'starred': false,
        });
      });
      await saveMessages();
      await speakReply(doneText);
      scrollToBottom();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Timer started for ${seconds}s')),
      );
    }
  }

  String _normalizeRoutineName(String value) {
    return value.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<List<Map<String, dynamic>>> _loadRoutines() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageRoutinesKey);
    if (raw == null || raw.trim().isEmpty) {
      return [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((item) => {
                'name': (item['name'] ?? '').toString(),
                'key': (item['key'] ?? '').toString(),
                'steps': (item['steps'] as List<dynamic>? ?? const [])
                    .whereType<Map<String, dynamic>>()
                    .map((s) => Map<String, dynamic>.from(s))
                    .toList(),
                'updatedAt': (item['updatedAt'] ?? '').toString(),
              })
          .where((r) => (r['name'] as String).trim().isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveRoutines(List<Map<String, dynamic>> routines) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageRoutinesKey, jsonEncode(routines));
  }

  Future<void> _createRoutineFromInfo(
    String info, {
    bool auto = false,
  }) async {
    final parsed = _decodeActionInfo(info);
    final name = (parsed['name'] ?? '').toString().trim();
    final key = _normalizeRoutineName(name);
    final rawSteps = (parsed['steps'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((s) => Map<String, dynamic>.from(s))
        .toList();

    if (name.isEmpty || key.isEmpty || rawSteps.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Routine payload is invalid.')),
        );
      }
      return;
    }

    final cleanedSteps = rawSteps.where((s) {
      final kind = (s['kind'] ?? '').toString().trim();
      return kind.isNotEmpty;
    }).toList();

    if (cleanedSteps.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Routine has no valid steps.')),
        );
      }
      return;
    }

    final routines = await _loadRoutines();
    routines.removeWhere((r) => (r['key'] ?? '') == key);
    routines.insert(0, {
      'name': name,
      'key': key,
      'steps': cleanedSteps,
      'updatedAt': DateTime.now().toIso8601String(),
    });
    if (routines.length > 80) {
      routines.removeRange(80, routines.length);
    }
    await _saveRoutines(routines);
    await _logAction(
      type: 'create_routine',
      payload: {
        'name': name,
        'key': key,
      },
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            auto
                ? 'Routine "$name" auto-saved'
                : 'Routine "$name" saved',
          ),
        ),
      );
    }
  }

  Future<void> _appendRoutineStatusMessage(String text) async {
    if (!mounted) {
      return;
    }
    setState(() {
      messages.add({
        'role': 'ai',
        'text': text,
        'time': DateTime.now().toIso8601String(),
        'type': 'command',
        'code': '',
        'imagePrompt': '',
        'videoPrompt': '',
        'action': 'show_info',
        'url': '',
        'info': text,
        'starred': false,
      });
    });
    await saveMessages();
    scrollToBottom();
  }

  Future<void> _executeRoutineStep(Map<String, dynamic> step) async {
    final kind = (step['kind'] ?? '').toString();

    if (kind == 'open_url') {
      final target = (step['url'] ?? '').toString().trim();
      if (target.isNotEmpty) {
        await openUrlAction(target);
      }
      return;
    }

    if (kind == 'create_note') {
      final text = (step['text'] ?? '').toString().trim();
      if (text.isNotEmpty) {
        await addOfflineNote(text);
      }
      return;
    }

    if (kind == 'create_task') {
      final text = (step['text'] ?? '').toString().trim();
      if (text.isNotEmpty) {
        await addOfflineTask(text);
      }
      return;
    }

    if (kind == 'set_timer') {
      final seconds = int.tryParse('${step['seconds'] ?? ''}') ?? 0;
      if (seconds > 0) {
        await _startAssistantTimer(seconds);
      }
      return;
    }

    if (kind == 'create_reminder') {
      final reminderText = (step['reminderText'] ?? step['text'] ?? '')
          .toString()
          .trim();
      final seconds = int.tryParse('${step['secondsFromNow'] ?? ''}') ?? 0;
      if (reminderText.isNotEmpty && seconds > 0) {
        await _scheduleAssistantReminderFromInfo(
          jsonEncode({
            'title': reminderText,
            'secondsFromNow': seconds,
          }),
          auto: true,
        );
      }
      return;
    }
  }

  Future<void> _runRoutineFromInfo(
    String info, {
    bool auto = false,
  }) async {
    final parsed = _decodeActionInfo(info);
    final name = (parsed['name'] ?? '').toString().trim();
    final key = _normalizeRoutineName(name);
    if (key.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Routine name is missing.')),
        );
      }
      return;
    }

    final routines = await _loadRoutines();
    Map<String, dynamic>? routine;
    for (final item in routines) {
      if ((item['key'] ?? '') == key) {
        routine = item;
        break;
      }
    }

    if (routine == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Routine "$name" not found')),
        );
      }
      return;
    }

    final steps = (routine['steps'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();

    if (steps.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Routine "$name" has no steps')),
        );
      }
      return;
    }

    for (final step in steps) {
      await _executeRoutineStep(step);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            auto
                ? 'Routine "$name" auto-ran (${steps.length} steps)'
                : 'Routine "$name" ran (${steps.length} steps)',
          ),
        ),
      );
    }
  }

  Future<void> _listRoutinesInChat() async {
    final routines = await _loadRoutines();
    if (routines.isEmpty) {
      await _appendRoutineStatusMessage('No routines saved yet.');
      return;
    }

    final lines = routines
        .take(12)
        .map((r) {
          final name = (r['name'] ?? '').toString().trim();
          final count = (r['steps'] as List<dynamic>? ?? const []).length;
          return '- $name ($count steps)';
        })
        .where((line) => line.trim().isNotEmpty)
        .toList();

    await _appendRoutineStatusMessage('Saved routines:\n${lines.join('\n')}');
  }

  Future<List<Map<String, dynamic>>> _loadEvents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageEventsKey);
    if (raw == null || raw.trim().isEmpty) {
      return [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((item) => {
                'id': (item['id'] ?? '').toString(),
                'title': (item['title'] ?? '').toString(),
                'date': (item['date'] ?? '').toString(),
                'time': (item['time'] ?? '').toString(),
                'scheduledAt': (item['scheduledAt'] ?? '').toString(),
                'createdAt': (item['createdAt'] ?? '').toString(),
              })
          .where((e) => (e['title'] as String).trim().isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveEvents(List<Map<String, dynamic>> events) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageEventsKey, jsonEncode(events));
  }

  DateTime? _eventDateTimeFromParts(String dateText, String timeText) {
    final date = dateText.trim();
    final time = timeText.trim();
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        !RegExp(r'^\d{1,2}:\d{2}$').hasMatch(time)) {
      return null;
    }

    final parts = time.split(':');
    final hour = int.tryParse(parts[0]) ?? -1;
    final minute = int.tryParse(parts[1]) ?? -1;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return null;
    }

    return DateTime.tryParse('$date ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00');
  }

  Future<void> _scheduleEventNotification({
    required String title,
    required DateTime scheduledAt,
  }) async {
    await _ensureNotificationsReady();
    if (!_notificationsReady) {
      return;
    }

    final id = (scheduledAt.millisecondsSinceEpoch + 77).remainder(2147483000);
    const androidDetails = AndroidNotificationDetails(
      'flowgnimag_events',
      'FLOWGNIMAG Events',
      channelDescription: 'Event reminders from FLOWGNIMAG',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );

    await _notificationsPlugin.zonedSchedule(
      id,
      'FLOWGNIMAG Event',
      title,
      tz.TZDateTime.from(scheduledAt, tz.local),
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: jsonEncode({
        'type': 'event',
        'title': title,
        'scheduledAt': scheduledAt.toIso8601String(),
      }),
    );
  }

  Future<void> _createEventFromInfo(
    String info, {
    bool auto = false,
  }) async {
    final parsed = _decodeActionInfo(info);
    final title = (parsed['title'] ?? parsed['text'] ?? '')
        .toString()
        .trim();
    final date = (parsed['date'] ?? '').toString().trim();
    final time = (parsed['time'] ?? '').toString().trim();

    if (title.isEmpty || date.isEmpty || time.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Event payload is invalid.')),
        );
      }
      return;
    }

    final scheduledAt = _eventDateTimeFromParts(date, time);
    if (scheduledAt == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid event date/time format.')),
        );
      }
      return;
    }

    final events = await _loadEvents();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    events.insert(0, {
      'id': id,
      'title': title,
      'date': date,
      'time': time,
      'scheduledAt': scheduledAt.toIso8601String(),
      'createdAt': DateTime.now().toIso8601String(),
    });

    if (events.length > 300) {
      events.removeRange(300, events.length);
    }
    await _saveEvents(events);
    await _logAction(
      type: 'create_event',
      payload: {
        'title': title,
        'date': date,
        'time': time,
      },
    );

    if (scheduledAt.isAfter(DateTime.now())) {
      await _scheduleEventNotification(title: title, scheduledAt: scheduledAt);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            auto
                ? 'Event auto-saved: $title ($date $time)'
                : 'Event saved: $title ($date $time)',
          ),
        ),
      );
    }
  }

  Future<void> _listEventsInChat() async {
    final events = await _loadEvents();
    if (events.isEmpty) {
      await _appendRoutineStatusMessage('No events saved yet.');
      return;
    }

    events.sort((a, b) {
      final da = DateTime.tryParse((a['scheduledAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final db = DateTime.tryParse((b['scheduledAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return da.compareTo(db);
    });

    final lines = events.take(15).map((item) {
      final title = (item['title'] ?? '').toString();
      final date = (item['date'] ?? '').toString();
      final time = (item['time'] ?? '').toString();
      return '- $date $time  |  $title';
    }).toList();

    await _appendRoutineStatusMessage('Saved events:\n${lines.join('\n')}');
  }

  Future<void> _deleteEventFromInfo(
    String info, {
    bool auto = false,
  }) async {
    final target = info.trim().toLowerCase();
    if (target.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Event title is required.')),
        );
      }
      return;
    }

    final events = await _loadEvents();
    final index = events.indexWhere((e) {
      final title = (e['title'] ?? '').toString().toLowerCase();
      return title == target || title.contains(target);
    });

    if (index < 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Matching event not found.')),
        );
      }
      return;
    }

    final removedEvent = Map<String, dynamic>.from(events[index]);
    final removedTitle = (removedEvent['title'] ?? '').toString();
    events.removeAt(index);
    await _saveEvents(events);
    await _logAction(
      type: 'delete_event',
      payload: {
        'target': target,
        'event': removedEvent,
      },
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            auto
                ? 'Event auto-deleted: $removedTitle'
                : 'Event deleted: $removedTitle',
          ),
        ),
      );
    }
  }

  Future<void> _undoLastAction() async {
    final actions = await _loadActionLog();
    if (actions.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No action to undo.')),
        );
      }
      return;
    }

    final last = actions.removeAt(0);
    final type = (last['type'] ?? '').toString();
    final payload = (last['payload'] as Map<String, dynamic>? ?? const {});
    final prefs = await SharedPreferences.getInstance();

    if (type == 'create_note') {
      final noteText = (payload['text'] ?? '').toString().trim();
      final raw = prefs.getString(_storageNotesKey);
      List<dynamic> notes = [];
      if (raw != null && raw.isNotEmpty) {
        notes = jsonDecode(raw) as List<dynamic>;
      }
      final idx = notes.indexWhere(
        (n) => (n as Map<String, dynamic>)['text']?.toString().trim() == noteText,
      );
      if (idx >= 0) {
        notes.removeAt(idx);
        await prefs.setString(_storageNotesKey, jsonEncode(notes));
      }
    } else if (type == 'create_task') {
      final title = (payload['title'] ?? '').toString().trim();
      final raw = prefs.getString(_storageTasksKey);
      List<dynamic> tasks = [];
      if (raw != null && raw.isNotEmpty) {
        tasks = jsonDecode(raw) as List<dynamic>;
      }
      final idx = tasks.indexWhere(
        (t) => (t as Map<String, dynamic>)['title']?.toString().trim() == title,
      );
      if (idx >= 0) {
        tasks.removeAt(idx);
        await prefs.setString(_storageTasksKey, jsonEncode(tasks));
      }
    } else if (type == 'create_event') {
      final title = (payload['title'] ?? '').toString();
      final date = (payload['date'] ?? '').toString();
      final time = (payload['time'] ?? '').toString();
      final events = await _loadEvents();
      final idx = events.indexWhere(
        (e) =>
            (e['title'] ?? '').toString() == title &&
            (e['date'] ?? '').toString() == date &&
            (e['time'] ?? '').toString() == time,
      );
      if (idx >= 0) {
        events.removeAt(idx);
        await _saveEvents(events);
      }
    } else if (type == 'delete_event') {
      final event = (payload['event'] as Map<String, dynamic>?);
      if (event != null) {
        final events = await _loadEvents();
        events.insert(0, Map<String, dynamic>.from(event));
        await _saveEvents(events);
      }
    } else if (type == 'create_routine') {
      final key = (payload['key'] ?? '').toString();
      final routines = await _loadRoutines();
      routines.removeWhere((r) => (r['key'] ?? '') == key);
      await _saveRoutines(routines);
    } else if (type == 'set_timer') {
      _activeTimer?.cancel();
      _activeTimer = null;
    } else if (type == 'execute_goal_plan') {
      final createdTasks = (payload['tasks'] as List<dynamic>? ?? const [])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList();
      if (createdTasks.isNotEmpty) {
        final raw = prefs.getString(_storageTasksKey);
        List<dynamic> tasks = [];
        if (raw != null && raw.isNotEmpty) {
          tasks = jsonDecode(raw) as List<dynamic>;
        }
        tasks.removeWhere((task) {
          final title = (task as Map<String, dynamic>)['title']
                  ?.toString()
                  .trim() ??
              '';
          return createdTasks.contains(title);
        });
        await prefs.setString(_storageTasksKey, jsonEncode(tasks));
      }
    }

    await _saveActionLog(actions);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Undid action: $type')),
      );
    }
  }

  Future<void> _executeGoalPlanFromInfo(
    String info, {
    bool auto = false,
  }) async {
    final parsed = _decodeActionInfo(info);
    final goal = (parsed['goal'] ?? '').toString().trim();
    final stepsRaw = (parsed['steps'] as List<dynamic>? ?? const []);

    final steps = stepsRaw
        .whereType<Map<String, dynamic>>()
        .map((item) => (item['title'] ?? '').toString().trim())
        .where((item) => item.isNotEmpty)
        .toList();

    if (steps.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Goal plan has no executable steps.')),
        );
      }
      return;
    }

    final created = <String>[];
    for (final step in steps) {
      await addOfflineTask(step);
      created.add(step);
    }

    await _logAction(
      type: 'execute_goal_plan',
      payload: {
        'goal': goal,
        'tasks': created,
      },
    );

    await _appendRoutineStatusMessage(
      goal.isEmpty
          ? 'Goal plan executed. ${created.length} tasks added.'
          : 'Goal plan executed for "$goal". ${created.length} tasks added.',
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            auto
                ? 'Goal plan auto-executed: ${created.length} tasks added'
                : 'Goal plan executed: ${created.length} tasks added',
          ),
        ),
      );
    }
  }

  bool _isHighRiskAction(String action) {
    return action == 'open_url' ||
        action == 'delete_event' ||
        action == 'google_gmail_send_confirm' ||
        action == 'execute_goal_plan';
  }

  Future<bool> _confirmActionExecution(String action) async {
    if (!_isHighRiskAction(action)) return true;
    if (!mounted) return false;

    final label = action == 'open_url'
        ? 'open an external link'
        : action == 'delete_event'
            ? 'delete an event'
            : action == 'google_gmail_send_confirm'
                ? 'send an email'
                : action == 'execute_goal_plan'
                    ? 'create multiple tasks from this plan'
                    : 'run this action';

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Approval Required'),
          content: Text('Do you want to $label?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Approve'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  Future<void> _addKnowledgeFromInfo(
    String info, {
    bool auto = false,
  }) async {
    if (!isCloudConnected || _cloudToken.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cloud login required for knowledge save.')),
        );
      }
      return;
    }

    final parsed = _decodeActionInfo(info);
    final title = (parsed['title'] ?? '').toString().trim();
    final content =
        (parsed['content'] ?? parsed['text'] ?? '').toString().trim();
    if (content.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Knowledge content is missing.')),
        );
      }
      return;
    }

    try {
      final response = await _postJsonWithRetry(
        '/knowledge/docs',
        {'title': title, 'content': content, 'tags': <String>[]},
        headers: {'Authorization': 'Bearer $_cloudToken'},
      );
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};
      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _appendRoutineStatusMessage(
          'Knowledge saved: ${title.isEmpty ? 'Knowledge Note' : title}',
        );
        await _logAction(
          type: 'add_knowledge',
          payload: {'title': title, 'content': content},
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                auto ? 'Knowledge auto-saved' : 'Knowledge saved',
              ),
            ),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text((data['error'] ?? 'Knowledge save failed').toString())),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Knowledge save failed.')),
        );
      }
    }
  }

  Future<void> _searchKnowledgeFromInfo(String info) async {
    if (!isCloudConnected || _cloudToken.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cloud login required for knowledge search.')),
        );
      }
      return;
    }
    final parsed = _decodeActionInfo(info);
    final query = (parsed['query'] ?? parsed['text'] ?? '').toString().trim();
    if (query.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Knowledge query is missing.')),
        );
      }
      return;
    }

    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/knowledge/search?q=${Uri.encodeQueryComponent(query)}&limit=5'),
        headers: {'Authorization': 'Bearer $_cloudToken'},
      );
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final items = (data['results'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        if (items.isEmpty) {
          await _appendRoutineStatusMessage('No knowledge matches found for "$query".');
          return;
        }
        final lines = items.map((item) {
          final title = (item['title'] ?? 'Knowledge').toString();
          final snippet = (item['snippet'] ?? '').toString();
          return '- $title: $snippet';
        }).toList();
        await _appendRoutineStatusMessage(
          'Knowledge results for "$query":\n${lines.join('\n')}',
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text((data['error'] ?? 'Knowledge search failed').toString())),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Knowledge search failed.')),
        );
      }
    }
  }

  Future<void> _createWorkflowJobFromInfo(String info) async {
    if (!isCloudConnected || _cloudToken.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cloud login required for workflows.')),
        );
      }
      return;
    }
    final parsed = _decodeActionInfo(info);
    final goal = (parsed['goal'] ?? '').toString().trim();
    final title = (parsed['title'] ?? '').toString().trim();
    final steps = (parsed['steps'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((item) => {'id': item['id'], 'title': item['title'], 'done': false})
        .toList();
    if (goal.isEmpty || steps.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Workflow goal/steps are missing.')),
        );
      }
      return;
    }
    try {
      final response = await _postJsonWithRetry(
        '/assistant/jobs',
        {'goal': goal, 'title': title, 'steps': steps},
        headers: {'Authorization': 'Bearer $_cloudToken'},
      );
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final job = (data['job'] as Map<String, dynamic>? ?? const {});
        final jobId = (job['id'] ?? '').toString();
        await _appendRoutineStatusMessage(
          'Workflow job created${jobId.isEmpty ? '' : ' (#$jobId)'} for "$goal".',
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text((data['error'] ?? 'Workflow create failed').toString())),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Workflow create failed.')),
        );
      }
    }
  }

  Future<void> _listWorkflowJobsInChat() async {
    if (!isCloudConnected || _cloudToken.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cloud login required for workflows.')),
        );
      }
      return;
    }
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/assistant/jobs?limit=10'),
        headers: {'Authorization': 'Bearer $_cloudToken'},
      );
      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final jobs = (data['jobs'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        if (jobs.isEmpty) {
          await _appendRoutineStatusMessage('No workflow jobs found.');
          return;
        }
        final lines = jobs.map((item) {
          final id = (item['id'] ?? '').toString();
          final title = (item['title'] ?? '').toString();
          final status = (item['status'] ?? '').toString();
          final idx = (item['currentStepIndex'] ?? 0).toString();
          return '- #$id | $title | $status | step $idx';
        }).toList();
        await _appendRoutineStatusMessage('Workflow jobs:\n${lines.join('\n')}');
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text((data['error'] ?? 'Workflow list failed').toString())),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Workflow list failed.')),
        );
      }
    }
  }

  Future<void> executeCommandAction({
    required String action,
    required String url,
    required String info,
    bool auto = false,
  }) async {
    if (!auto) {
      final approved = await _confirmActionExecution(action);
      if (!approved) {
        return;
      }
    }

    if (action == 'open_url') {
      if (url.trim().isNotEmpty) {
        await openUrlAction(url);
      }
      return;
    }

    if (action == 'create_note') {
      final text = info.trim();
      if (text.isNotEmpty) {
        await addOfflineNote(text);
        await _logAction(type: 'create_note', payload: {'text': text});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                auto ? 'Command auto-saved as note' : 'Saved as note',
              ),
            ),
          );
        }
      }
      return;
    }

    if (action == 'create_task') {
      final text = info.trim();
      if (text.isNotEmpty) {
        await addOfflineTask(text);
        await _logAction(type: 'create_task', payload: {'title': text});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                auto ? 'Command auto-saved as task' : 'Saved as task',
              ),
            ),
          );
        }
      }
      return;
    }

    if (action == 'set_timer') {
      final seconds = _timerSecondsFromInfo(info);
      await _startAssistantTimer(seconds);
      if (seconds > 0) {
        await _logAction(type: 'set_timer', payload: {'seconds': seconds});
      }
      return;
    }

    if (action == 'create_reminder') {
      await _scheduleAssistantReminderFromInfo(info, auto: auto);
      return;
    }

    if (action == 'create_routine') {
      await _createRoutineFromInfo(info, auto: auto);
      return;
    }

    if (action == 'run_routine') {
      await _runRoutineFromInfo(info, auto: auto);
      return;
    }

    if (action == 'list_routines') {
      await _listRoutinesInChat();
      return;
    }

    if (action == 'create_event') {
      await _createEventFromInfo(info, auto: auto);
      return;
    }

    if (action == 'list_events') {
      await _listEventsInChat();
      return;
    }

    if (action == 'delete_event') {
      await _deleteEventFromInfo(info, auto: auto);
      return;
    }

    if (action == 'undo_action') {
      await _undoLastAction();
      return;
    }

    if (action == 'list_actions') {
      await _listActionHistoryInChat();
      return;
    }

    if (action == 'run_push_doctor') {
      await _runPushDoctorAction(auto: auto);
      return;
    }

    if (action == 'run_push_self_test') {
      await _runPushSelfTestAction(auto: auto);
      return;
    }

    if (action == 'google_gmail_send_confirm') {
      await _sendGoogleEmailWithConfirmation(info, auto: auto);
      return;
    }

    if (action == 'execute_goal_plan') {
      await _executeGoalPlanFromInfo(info, auto: auto);
      return;
    }

    if (action == 'add_knowledge') {
      await _addKnowledgeFromInfo(info, auto: auto);
      return;
    }

    if (action == 'search_knowledge') {
      await _searchKnowledgeFromInfo(info);
      return;
    }

    if (action == 'create_workflow_job') {
      await _createWorkflowJobFromInfo(info);
      return;
    }

    if (action == 'list_workflow_jobs') {
      await _listWorkflowJobsInChat();
      return;
    }
  }

  Future<void> sendMessage() async {
    final text = controller.text.trim();
    await _submitPrompt(text, addUserBubble: true, clearComposer: true);
  }

  void scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 110), () {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> clearChat() async {
    await stopSpeaking();

    setState(() {
      messages.clear();
      controller.clear();
    });

    await saveMessages();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _startGoogleAlertsMonitorIfNeeded();
  }

  String formatMessageTime(String? isoTime) {
    if (isoTime == null || isoTime.isEmpty) {
      return '';
    }
    final date = DateTime.tryParse(isoTime);
    if (date == null) {
      return '';
    }

    int hour = date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    hour = hour % 12;
    if (hour == 0) {
      hour = 12;
    }

    return '$hour:$minute $period';
  }

  String formatSessionDate(String? isoTime) {
    if (isoTime == null || isoTime.isEmpty) {
      return '';
    }
    final date = DateTime.tryParse(isoTime);
    if (date == null) {
      return '';
    }

    final now = DateTime.now();
    final difference = now.difference(date).inDays;
    if (difference == 0) {
      return 'Today';
    }
    if (difference == 1) {
      return 'Yesterday';
    }
    return '${date.day}/${date.month}/${date.year}';
  }

  List<Map<String, dynamic>> get filteredMessages {
    return List<Map<String, dynamic>>.from(messages);
  }

  List<Map<String, dynamic>> get filteredSessions {
    final base = List<Map<String, dynamic>>.from(chatSessions);
    base.sort((a, b) {
      final aPinned = a['isPinned'] == true ? 1 : 0;
      final bPinned = b['isPinned'] == true ? 1 : 0;
      if (aPinned != bPinned) {
        return bPinned.compareTo(aPinned);
      }
      return (b['updatedAt'] ?? '').toString().compareTo(
        (a['updatedAt'] ?? '').toString(),
      );
    });

    if (!hasActiveHistorySearch) {
      return base;
    }

    final query = historySearchText.toLowerCase();
    return base.where((session) {
      final title = (session['title'] ?? '').toString().toLowerCase();
      final items = (session['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>();
      final textMatch = items.any((item) {
        final text = (item['text'] ?? '').toString().toLowerCase();
        final prompt = (item['imagePrompt'] ?? '').toString().toLowerCase();
        final videoPrompt = (item['videoPrompt'] ?? '')
            .toString()
            .toLowerCase();
        return text.contains(query) ||
            prompt.contains(query) ||
            videoPrompt.contains(query);
      });
      return title.contains(query) || textMatch;
    }).toList();
  }

  Future<void> copyToClipboard(String text, String label) async {
    if (text.trim().isEmpty) {
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied')));
  }

  Future<void> openUrlAction(String url) async {
    if (url.trim().isEmpty) {
      return;
    }

    final uri = Uri.tryParse(url);
    if (uri == null) {
      return;
    }

    final success = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!success && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open link.')));
    }
  }

  Future<bool> _refreshCloudAccessToken() async {
    final refresh = _cloudRefreshToken.trim();
    if (refresh.isEmpty) {
      return false;
    }

    try {
      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/auth/refresh'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'refreshToken': refresh}),
          )
          .timeout(const Duration(seconds: 20));

      final data = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }

      final token = (data['token'] ?? '').toString().trim();
      final refreshToken = (data['refreshToken'] ?? '').toString().trim();
      if (token.isEmpty) {
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cloudTokenKey, token);
      _cloudToken = token;

      if (refreshToken.isNotEmpty) {
        await prefs.setString(_cloudRefreshTokenKey, refreshToken);
        _cloudRefreshToken = refreshToken;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<http.Response> _getWithAuthRetry(
    String path, {
    int retries = 1,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    Object? lastError;

    for (int attempt = 0; attempt <= retries; attempt++) {
      try {
        var response = await http
            .get(
              uri,
              headers: {'Content-Type': 'application/json', ...?headers},
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 401 &&
            (headers?['Authorization'] ?? '').isNotEmpty &&
            attempt < retries) {
          final refreshed = await _refreshCloudAccessToken();
          if (refreshed) {
            response = await http
                .get(
                  uri,
                  headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer $_cloudToken',
                  },
                )
                .timeout(const Duration(seconds: 30));
          }
        }

        if ((response.statusCode >= 500 || response.statusCode == 429) &&
            attempt < retries) {
          await Future.delayed(Duration(milliseconds: 450 * (attempt + 1)));
          continue;
        }

        return response;
      } catch (error) {
        lastError = error;
        if (attempt < retries) {
          await Future.delayed(Duration(milliseconds: 450 * (attempt + 1)));
          continue;
        }
      }
    }

    throw lastError ?? Exception('Request failed');
  }

  Future<http.Response> _postJsonWithRetry(
    String path,
    Map<String, dynamic> payload, {
    int retries = 2,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    Object? lastError;

    for (int attempt = 0; attempt <= retries; attempt++) {
      try {
        var response = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json', ...?headers},
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 401 &&
            (headers?['Authorization'] ?? '').isNotEmpty &&
            attempt < retries) {
          final refreshed = await _refreshCloudAccessToken();
          if (refreshed) {
            response = await http
                .post(
                  uri,
                  headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer $_cloudToken',
                  },
                  body: jsonEncode(payload),
                )
                .timeout(const Duration(seconds: 30));
          }
        }

        final shouldRetryStatus =
            response.statusCode >= 500 || response.statusCode == 429;
        if (shouldRetryStatus && attempt < retries) {
          await Future.delayed(Duration(milliseconds: 450 * (attempt + 1)));
          continue;
        }

        return response;
      } catch (error) {
        lastError = error;
        if (attempt < retries) {
          await Future.delayed(Duration(milliseconds: 450 * (attempt + 1)));
          continue;
        }
      }
    }

    throw lastError ?? Exception('Request failed');
  }

  Future<void> toggleMessageStar(Map<String, dynamic> msg) async {
    setState(() {
      msg['starred'] = !(msg['starred'] == true);
    });
    await saveMessages();
  }

  String _attachRequestId(
    String message,
    Map<String, dynamic> data,
    http.Response response,
  ) {
    final requestId =
        (data['requestId'] ?? response.headers['x-request-id'] ?? '')
            .toString()
            .trim();
    if (requestId.isEmpty) {
      return message;
    }
    return '$message\nRequest ID: $requestId';
  }

  String getFileNameFromCode(String codeText, String messageText) {
    final lower = (messageText + codeText).toLowerCase();

    if (lower.contains('java')) return 'Main.java';
    if (lower.contains('python')) return 'main.py';
    if (lower.contains('javascript')) return 'main.js';
    if (lower.contains('html')) return 'index.html';
    if (lower.contains('css')) return 'styles.css';
    if (lower.contains('sql')) return 'query.sql';
    if (lower.contains('c++') || lower.contains('cpp')) return 'main.cpp';
    if (lower.contains('c#')) return 'Program.cs';
    if (lower.contains('php')) return 'index.php';
    if (lower.contains('dart') || lower.contains('flutter')) return 'main.dart';

    return 'generated_code.txt';
  }

  String _contextTextFromMessage(Map<String, dynamic> msg) {
    final text = (msg['text'] ?? '').toString().trim();
    final type = (msg['type'] ?? 'chat').toString();
    final code = (msg['code'] ?? '').toString().trim();
    final imagePrompt = (msg['imagePrompt'] ?? '').toString().trim();
    final videoPrompt = (msg['videoPrompt'] ?? '').toString().trim();

    if (type == 'code' && code.isNotEmpty) {
      return '$text\n\nCode:\n$code';
    }

    if ((type == 'image' || type == 'generated_image') &&
        imagePrompt.isNotEmpty) {
      return '$text\n\nImage prompt:\n$imagePrompt';
    }

    if ((type == 'video' || type == 'generated_video') &&
        videoPrompt.isNotEmpty) {
      return '$text\n\nVideo prompt:\n$videoPrompt';
    }

    return text;
  }

  List<Map<String, String>> _chatHistoryPayload() {
    final payload = <Map<String, String>>[];

    for (final msg in messages) {
      final roleRaw = (msg['role'] ?? '').toString().trim().toLowerCase();
      final role = roleRaw == 'user'
          ? 'user'
          : roleRaw == 'ai'
          ? 'assistant'
          : '';

      if (role.isEmpty) {
        continue;
      }

      final content = _contextTextFromMessage(msg);
      if (content.isEmpty) {
        continue;
      }

      payload.add({
        'role': role,
        'content': content.length > 1400 ? content.substring(0, 1400) : content,
      });
    }

    if (payload.length <= 12) {
      return payload;
    }

    return payload.sublist(payload.length - 12);
  }

  Future<void> saveCodeToLocalFile(String fileName, String codeText) async {
    final safeName = _safeFileSegment(fileName);
    final dot = safeName.lastIndexOf('.');
    final base = dot > 0 ? safeName.substring(0, dot) : safeName;
    final ext = dot > 0 ? safeName.substring(dot + 1) : 'txt';
    await exportToLocalFile(title: base, extension: ext, content: codeText);
  }

  Future<void> saveVideoDataToLocalFile(
    String prompt,
    String videoSource,
  ) async {
    if (videoSource.trim().isEmpty) {
      return;
    }

    if (kIsWeb) {
      await copyToClipboard(videoSource, 'Video data');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Web export fallback: video data copied to clipboard.',
            ),
          ),
        );
      }
      return;
    }

    try {
      if (!videoSource.startsWith('data:video/')) {
        await openUrlAction(videoSource);
        return;
      }

      final meta = videoSource.substring(0, videoSource.indexOf(','));
      final extMatch = RegExp(
        r'data:video/([a-zA-Z0-9]+);base64',
      ).firstMatch(meta);
      final ext = (extMatch?.group(1) ?? 'mp4').toLowerCase();
      final bytes = base64Decode(videoSource.split(',').last);

      final directory = await getApplicationDocumentsDirectory();
      final fileName = _buildExportFileName(prompt, ext);
      final file = File('${directory.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved video: ${file.path}')));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save video file.')),
      );
    }
  }

  void openImagePromptAction(String prompt) {
    if (prompt.trim().isEmpty) {
      return;
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Image Prompt'),
          content: SingleChildScrollView(
            child: Text(prompt, style: const TextStyle(height: 1.5)),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async => copyToClipboard(prompt, 'Prompt'),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openImageTool(String url) async {
    await openUrlAction(url);
  }

  void showImageGeneratorDialog(String prompt) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Generate Image'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Prompt',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(prompt, style: const TextStyle(height: 1.5)),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: isGeneratingImage
                        ? null
                        : () async {
                            Navigator.pop(context);
                            await generateImageFromPrompt(prompt);
                          },
                    icon: const Icon(Icons.image_outlined),
                    label: Text(
                      isGeneratingImage
                          ? 'Generating...'
                          : 'Generate in FLOWGNIMAG',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'External Tools',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                ..._imageTools.map((tool) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.pop(context);
                          await _openImageTool(tool['url']!);
                        },
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: Text(tool['name']!),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget buildCodeActions(String codeText, String messageText) {
    final fileName = getFileNameFromCode(codeText, messageText);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _bubbleAction(
          icon: Icons.copy_rounded,
          label: 'Copy',
          onTap: () => copyToClipboard(codeText, 'Code'),
        ),
        _bubbleAction(
          icon: Icons.save_alt_rounded,
          label: 'Save',
          onTap: () => saveCodeToLocalFile(fileName, codeText),
        ),
        _bubbleAction(
          icon: Icons.note_add_outlined,
          label: 'To Note',
          onTap: () async {
            await addOfflineNote(codeText);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Code saved to notes')),
              );
            }
          },
        ),
      ],
    );
  }

  Widget buildImageActions(String imagePrompt) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _bubbleAction(
          icon: Icons.copy_rounded,
          label: 'Copy',
          onTap: () => copyToClipboard(imagePrompt, 'Prompt'),
        ),
        _bubbleAction(
          icon: Icons.auto_awesome_rounded,
          label: isGeneratingImage ? 'Generating' : 'Generate',
          onTap: isGeneratingImage
              ? null
              : () => showImageGeneratorDialog(imagePrompt),
        ),
        _bubbleAction(
          icon: Icons.visibility_outlined,
          label: 'View',
          onTap: () => openImagePromptAction(imagePrompt),
        ),
        _bubbleAction(
          icon: Icons.task_alt_outlined,
          label: 'To Task',
          onTap: () async {
            await addOfflineTask(imagePrompt);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Prompt saved as task')),
              );
            }
          },
        ),
      ],
    );
  }

  Widget buildVideoActions(String videoPrompt) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _bubbleAction(
          icon: Icons.copy_rounded,
          label: 'Copy',
          onTap: () => copyToClipboard(videoPrompt, 'Prompt'),
        ),
        _bubbleAction(
          icon: Icons.movie_creation_outlined,
          label: isGeneratingVideo ? 'Generating' : 'Generate',
          onTap: isGeneratingVideo
              ? null
              : () => generateVideoFromPrompt(videoPrompt),
        ),
        _bubbleAction(
          icon: Icons.task_alt_outlined,
          label: 'To Task',
          onTap: () async {
            await addOfflineTask(videoPrompt);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Prompt saved as task')),
              );
            }
          },
        ),
      ],
    );
  }

  Widget buildCommandActions(
    String action,
    String url,
    String info, {
    bool requiresApproval = false,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (action == 'open_url' && url.trim().isNotEmpty)
          _bubbleAction(
            icon: Icons.open_in_new_rounded,
            label: 'Open',
            onTap: () => openUrlAction(url),
          ),
        if ((action == 'create_note' ||
                action == 'create_task' ||
                action == 'set_timer' ||
                action == 'create_reminder' ||
                action == 'create_routine' ||
                action == 'run_routine' ||
                action == 'list_routines' ||
                action == 'create_event' ||
                action == 'list_events' ||
                action == 'delete_event' ||
                action == 'undo_action' ||
                action == 'list_actions' ||
                action == 'run_push_doctor' ||
                action == 'run_push_self_test' ||
                action == 'google_gmail_send_confirm' ||
                action == 'execute_goal_plan' ||
                action == 'add_knowledge' ||
                action == 'search_knowledge' ||
                action == 'create_workflow_job' ||
                action == 'list_workflow_jobs') &&
            (info.trim().isNotEmpty ||
                action == 'set_timer' ||
                action == 'create_reminder' ||
                action == 'list_routines' ||
                action == 'list_events' ||
                action == 'undo_action' ||
                action == 'list_actions' ||
                action == 'run_push_doctor' ||
                action == 'run_push_self_test' ||
                action == 'list_workflow_jobs'))
          _bubbleAction(
            icon: action == 'set_timer' || action == 'create_reminder'
                ? Icons.timer_outlined
                : action == 'create_routine'
                    ? Icons.save_alt_rounded
                    : action == 'execute_goal_plan'
                        ? Icons.auto_awesome_rounded
                    : action == 'add_knowledge'
                        ? Icons.library_add_outlined
                        : action == 'search_knowledge'
                            ? Icons.find_in_page_outlined
                            : action == 'create_workflow_job'
                                ? Icons.account_tree_outlined
                                : action == 'list_workflow_jobs'
                                    ? Icons.view_list_rounded
                    : action == 'list_routines'
                        ? Icons.list_alt_rounded
                        : action == 'create_event'
                            ? Icons.event_available_outlined
                            : action == 'list_events'
                                ? Icons.event_note_outlined
                                    : action == 'delete_event'
                                        ? Icons.event_busy_outlined
                                        : action == 'undo_action'
                                            ? Icons.undo_rounded
                                            : action == 'list_actions'
                                                ? Icons.history_rounded
                                                : action == 'run_push_doctor'
                                                    ? Icons.medical_services_outlined
                                                    : action ==
                                                            'run_push_self_test'
                                                        ? Icons.fact_check_outlined
                                                : action ==
                                                        'google_gmail_send_confirm'
                                                    ? Icons.send_rounded
                        : Icons.play_circle_outline_rounded,
            label: action == 'set_timer'
                ? 'Start Timer'
                : action == 'create_reminder'
                    ? 'Schedule'
                    : action == 'create_routine'
                        ? 'Save Routine'
                        : action == 'run_routine'
                            ? 'Run Routine'
                            : action == 'list_routines'
                                ? 'Show'
                                : action == 'create_event'
                                    ? 'Save Event'
                                    : action == 'list_events'
                                        ? 'Show Events'
                                        : action == 'delete_event'
                                            ? 'Delete Event'
                                            : action == 'undo_action'
                                                ? 'Undo'
                                                : action == 'list_actions'
                                                    ? 'History'
                                                    : action ==
                                                            'run_push_doctor'
                                                        ? 'Push Doctor'
                                                        : action ==
                                                                'run_push_self_test'
                                                            ? 'Self-Test'
                                                    : action ==
                                                            'execute_goal_plan'
                                                        ? 'Run Plan'
                                                    : requiresApproval
                                                        ? 'Approve & Run'
                                                        : action == 'add_knowledge'
                                                        ? 'Save Knowledge'
                                                        : action ==
                                                                'search_knowledge'
                                                            ? 'Search KB'
                                                            : action ==
                                                                    'create_workflow_job'
                                                                ? 'Create Workflow'
                                                                : action ==
                                                                        'list_workflow_jobs'
                                                                    ? 'Show Workflows'
                                                    : action ==
                                                            'google_gmail_send_confirm'
                                                        ? 'Send Email'
                    : 'Run',
            onTap: () =>
                executeCommandAction(action: action, url: url, info: info),
          ),
        if (info.trim().isNotEmpty)
          _bubbleAction(
            icon: Icons.copy_rounded,
            label: 'Copy Info',
            onTap: () => copyToClipboard(info, 'Info'),
          ),
        _bubbleAction(
          icon: Icons.note_add_outlined,
          label: 'To Note',
          onTap: () async {
            final value = info.trim().isNotEmpty ? info : url;
            await addOfflineNote(value);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Command saved to notes')),
              );
            }
          },
        ),
      ],
    );
  }

  Widget _bubbleAction({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      borderRadius: BorderRadius.circular(999),
      opacity: 0.12,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: AppTheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: AppTheme.textMuted(context),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildSpeakButton(String text) {
    final isThisSpeaking = isSpeaking && _currentlySpeakingText == text;

    return IconButton(
      tooltip: isThisSpeaking ? 'Stop speaking' : 'Speak',
      onPressed: () async {
        if (isThisSpeaking) {
          await stopSpeaking();
        } else {
          await speakManually(text);
        }
      },
      icon: Icon(
        isThisSpeaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
        size: 18,
        color: AppTheme.textMuted(context),
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
    );
  }

  Widget buildGeneratedImageCard(
    String text,
    String prompt,
    String imageSource,
  ) {
    Widget imageWidget;

    try {
      if (imageSource.startsWith('data:image/')) {
        final base64Part = imageSource.split(',').last;
        final bytes = base64Decode(base64Part);

        imageWidget = ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Image.memory(
            bytes,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => _fallbackMediaCard(),
          ),
        );
      } else {
        imageWidget = _fallbackMediaCard();
      }
    } catch (_) {
      imageWidget = _fallbackMediaCard();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _bubbleHeaderText(text),
        const SizedBox(height: 12),
        imageWidget,
        const SizedBox(height: 12),
        GlassPanel(
          padding: const EdgeInsets.all(14),
          borderRadius: BorderRadius.circular(20),
          opacity: 0.12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Prompt Used',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(prompt, style: const TextStyle(height: 1.45)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _bubbleAction(
                    icon: Icons.copy_rounded,
                    label: 'Copy Prompt',
                    onTap: () => copyToClipboard(prompt, 'Prompt'),
                  ),
                  _bubbleAction(
                    icon: Icons.refresh_rounded,
                    label: 'Regenerate',
                    onTap: () => showImageGeneratorDialog(prompt),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildGeneratedVideoCard(
    String text,
    String prompt,
    String videoSource,
  ) {
    final details = videoSource.startsWith('data:video/')
        ? 'Video payload is ready. Preview player can be added next.'
        : 'Video data preview is not available.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _bubbleHeaderText(text),
        const SizedBox(height: 12),
        GlassPanel(
          padding: const EdgeInsets.all(14),
          borderRadius: BorderRadius.circular(20),
          opacity: 0.12,
          child: Row(
            children: [
              Icon(Icons.smart_display_rounded, color: AppTheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  details,
                  style: TextStyle(color: AppTheme.textMuted(context)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassPanel(
          padding: const EdgeInsets.all(14),
          borderRadius: BorderRadius.circular(20),
          opacity: 0.12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Prompt Used',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(prompt, style: const TextStyle(height: 1.45)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _bubbleAction(
                    icon: Icons.copy_rounded,
                    label: 'Copy Prompt',
                    onTap: () => copyToClipboard(prompt, 'Prompt'),
                  ),
                  _bubbleAction(
                    icon: Icons.data_object_rounded,
                    label: 'Copy Data',
                    onTap: () => copyToClipboard(videoSource, 'Video data'),
                  ),
                  _bubbleAction(
                    icon: Icons.save_alt_rounded,
                    label: 'Save Video',
                    onTap: () => saveVideoDataToLocalFile(prompt, videoSource),
                  ),
                  _bubbleAction(
                    icon: Icons.refresh_rounded,
                    label: 'Regenerate',
                    onTap: () => generateVideoFromPrompt(prompt),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fallbackMediaCard() {
    return GlassPanel(
      padding: const EdgeInsets.all(16),
      borderRadius: BorderRadius.circular(18),
      child: const Text('Generated image preview could not be loaded.'),
    );
  }

  Widget _bubbleHeaderText(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 16, height: 1.42)),
        ),
        const SizedBox(width: 8),
        buildSpeakButton(text),
      ],
    );
  }

  Widget buildFollowupSuggestionChips(List<String> suggestions) {
    if (suggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: suggestions.map((text) {
        return _bubbleAction(
          icon: Icons.bolt_rounded,
          label: text.length > 30 ? '${text.substring(0, 30)}...' : text,
          onTap: () async {
            await _submitPrompt(
              text,
              addUserBubble: true,
              clearComposer: true,
            );
          },
        );
      }).toList(),
    );
  }

  Widget buildMessageBubble(Map<String, dynamic> msg) {
    final isUser = msg['role'] == 'user';
    final timeText = formatMessageTime(msg['time']?.toString());
    final type = (msg['type'] ?? 'chat').toString();
    final codeText = (msg['code'] ?? '').toString();
    final imagePrompt = (msg['imagePrompt'] ?? '').toString();
    final videoPrompt = (msg['videoPrompt'] ?? '').toString();
    final action = (msg['action'] ?? '').toString();
    final url = (msg['url'] ?? '').toString();
    final info = (msg['info'] ?? '').toString();
    final requiresApproval = msg['requiresApproval'] == true;
    final suggestions = (msg['suggestions'] as List<dynamic>? ?? const [])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final text = (msg['text'] ?? '').toString();

    Widget bubbleContent;

    if (!isUser && type == 'code' && codeText.trim().isNotEmpty) {
      bubbleContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _bubbleHeaderText(text),
          const SizedBox(height: 12),
          buildCodeActions(codeText, text),
          const SizedBox(height: 12),
          GlassPanel(
            padding: const EdgeInsets.all(12),
            borderRadius: BorderRadius.circular(18),
            opacity: 0.10,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                codeText,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ),
        ],
      );
    } else if (!isUser && type == 'image' && imagePrompt.trim().isNotEmpty) {
      bubbleContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _bubbleHeaderText(text),
          const SizedBox(height: 12),
          GlassPanel(
            padding: const EdgeInsets.all(14),
            borderRadius: BorderRadius.circular(20),
            opacity: 0.12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildImageActions(imagePrompt),
                const SizedBox(height: 10),
                Text(imagePrompt, style: const TextStyle(height: 1.45)),
              ],
            ),
          ),
        ],
      );
    } else if (!isUser && type == 'generated_image') {
      bubbleContent = buildGeneratedImageCard(text, imagePrompt, url);
    } else if (!isUser && type == 'video' && videoPrompt.trim().isNotEmpty) {
      bubbleContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _bubbleHeaderText(text),
          const SizedBox(height: 12),
          GlassPanel(
            padding: const EdgeInsets.all(14),
            borderRadius: BorderRadius.circular(20),
            opacity: 0.12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildVideoActions(videoPrompt),
                const SizedBox(height: 10),
                Text(videoPrompt, style: const TextStyle(height: 1.45)),
              ],
            ),
          ),
        ],
      );
    } else if (!isUser && type == 'generated_video') {
      bubbleContent = buildGeneratedVideoCard(text, videoPrompt, url);
    } else if (!isUser && type == 'command') {
      bubbleContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _bubbleHeaderText(text),
          const SizedBox(height: 12),
          buildCommandActions(
            action,
            url,
            info,
            requiresApproval: requiresApproval,
          ),
        ],
      );
    } else {
      bubbleContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          isUser
              ? Text(text, style: const TextStyle(fontSize: 16, height: 1.45))
              : _bubbleHeaderText(text),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _bubbleAction(
                icon: Icons.copy_rounded,
                label: 'Copy',
                onTap: () =>
                    copyToClipboard(text, isUser ? 'Message' : 'Reply'),
              ),
              if (isUser)
                _bubbleAction(
                  icon: Icons.edit_outlined,
                  label: 'Edit & Resend',
                  onTap: () => editAndResendMessage(msg),
                ),
              if (!isUser)
                _bubbleAction(
                  icon: Icons.note_add_outlined,
                  label: 'To Note',
                  onTap: () async {
                    await addOfflineNote(text);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Reply saved to notes')),
                      );
                    }
                  },
                ),
              if (!isUser)
                _bubbleAction(
                  icon: Icons.task_alt_outlined,
                  label: 'To Task',
                  onTap: () async {
                    await addOfflineTask(text);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Reply saved as task')),
                      );
                    }
                  },
                ),
            ],
          ),
        ],
      );
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset((isUser ? 18 : -18) * (1 - value), 10 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: GlassPanel(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            borderRadius: BorderRadius.circular(26),
            opacity: isUser ? 0.22 : 0.16,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: isUser
                    ? LinearGradient(
                        colors: [
                          Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.30),
                          AppTheme.secondary.withValues(alpha: 0.18),
                        ],
                      )
                    : null,
              ),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Column(
                  crossAxisAlignment: isUser
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    bubbleContent,
                    if (!isUser && suggestions.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      buildFollowupSuggestionChips(suggestions),
                    ],
                    const SizedBox(height: 8),
                    _bubbleAction(
                      icon: msg['starred'] == true
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      label: msg['starred'] == true ? 'Starred' : 'Star',
                      onTap: () async => toggleMessageStar(msg),
                    ),
                    if (timeText.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        timeText,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMuted(context),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusChip({
    required IconData icon,
    required String label,
    Color? color,
  }) {
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      borderRadius: BorderRadius.circular(999),
      opacity: 0.12,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color ?? AppTheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textMuted(context),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSettingsInfoBar() {
    return GlassPanel(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      borderRadius: BorderRadius.circular(20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _statusChip(
            icon: widget.isOnlineMode ? Icons.wifi : Icons.wifi_off,
            label: widget.isOnlineMode ? 'Online' : 'Offline',
            color: widget.isOnlineMode ? const Color(0xFF67E8A8) : AppTheme.accent,
          ),
          _statusChip(
            icon: voiceEnabled
                ? (wakeModeEnabled
                    ? Icons.record_voice_over_rounded
                    : Icons.mic)
                : Icons.mic_off,
            label: !voiceEnabled
                ? 'Voice Off'
                : wakeModeEnabled
                    ? 'Wake On'
                    : 'Voice On',
            color: voiceEnabled ? const Color(0xFF67E8A8) : null,
          ),
          _statusChip(
            icon: googleAlertsEnabled
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
            label: googleAlertsEnabled ? 'Alerts On' : 'Alerts Off',
            color: googleAlertsEnabled ? const Color(0xFF67E8A8) : null,
          ),
        ],
      ),
    );
  }

  Widget buildWelcomeScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: RevealSlide(
        child: GlassPanel(
          padding: const EdgeInsets.all(22),
          borderRadius: BorderRadius.circular(26),
          opacity: 0.20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          AppTheme.primary.withValues(alpha: 0.22),
                          AppTheme.secondary.withValues(alpha: 0.18),
                        ],
                      ),
                    ),
                    child: Image.asset('assets/images/wolf.png'),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'FLOWGNIMAG',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _quickStartButton('Start Chat'),
                  _quickStartButton('Daily briefing'),
                  _quickStartButton('Action history'),
                  _quickStartButton('Weather in Mumbai'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickStartButton(String text) {
    return GlassPanel(
      borderRadius: BorderRadius.circular(18),
      opacity: 0.10,
      child: InkWell(
        onTap: () {
          if (text == 'Start Chat') {
            controller.clear();
            return;
          }
          controller.text = text;
          controller.selection = TextSelection.collapsed(offset: text.length);
        },
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  Widget buildTopBar(bool isWide) {
    return GlassPanel(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      borderRadius: BorderRadius.circular(24),
      opacity: 0.16,
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'FLOWGNIMAG',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (isLoading) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 2),
          ],
        ],
      ),
    );
  }

  Widget _topIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GlassPanel(
        padding: const EdgeInsets.all(2),
        borderRadius: BorderRadius.circular(18),
        opacity: 0.12,
        child: IconButton(onPressed: onTap, icon: Icon(icon)),
      ),
    );
  }

  Widget buildComposer() {
    return GlassPanel(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      borderRadius: BorderRadius.circular(32),
      opacity: 0.30,
      child: Column(
        children: [
          if (isListening)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const Icon(Icons.graphic_eq_rounded, color: Colors.redAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      wakeModeEnabled
                          ? 'Wake listening... say "Hey Flow" then command.'
                          : 'Listening...',
                      style: TextStyle(color: AppTheme.textMuted(context)),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    color: Colors.white.withValues(alpha: 0.08),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.18),
                    ),
                  ),
                  child: TextField(
                    controller: controller,
                    onSubmitted: (_) => sendMessage(),
                    minLines: 1,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: 'Type your message...',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                decoration: BoxDecoration(
                  color: isListening
                      ? Colors.redAccent.withValues(alpha: 0.88)
                      : Colors.white.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  onPressed: toggleListening,
                  icon: Icon(
                    isListening ? Icons.mic : Icons.mic_none,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      AppTheme.secondary,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.30),
                      blurRadius: 24,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: IconButton(
                  onPressed: sendMessage,
                  icon: const Icon(Icons.send_rounded, color: Colors.white),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _historyTile(Map<String, dynamic> session) {
    final isSelected = session['id'] == currentSessionId;
    final isPinned = session['isPinned'] == true;
    final items = (session['items'] as List<dynamic>? ?? const []);
    final subtitle = items.isEmpty
        ? 'No messages yet'
        : '${items.length} messages • ${formatSessionDate(session['updatedAt']?.toString())}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassPanel(
        borderRadius: BorderRadius.circular(22),
        opacity: isSelected ? 0.22 : 0.10,
        child: InkWell(
          onTap: () async {
            Navigator.pop(context);
            await openSession(session['id'].toString());
          },
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        session['title']?.toString() ?? 'New Chat',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ),
                    ),
                    Icon(
                      isPinned
                          ? Icons.push_pin_rounded
                          : Icons.chat_bubble_outline_rounded,
                      size: 16,
                      color: isPinned
                          ? AppTheme.accent
                          : AppTheme.textMuted(context),
                    ),
                    const SizedBox(width: 4),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz_rounded, size: 18),
                      onSelected: (value) async {
                        if (value == 'open') {
                          await openSession(session['id'].toString());
                        } else if (value == 'rename') {
                          await renameSessionDialog(session['id'].toString());
                        } else if (value == 'pin') {
                          await togglePinSession(session['id'].toString());
                        } else if (value == 'delete') {
                          await deleteSession(session['id'].toString());
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(value: 'open', child: Text('Open')),
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('Rename'),
                        ),
                        PopupMenuItem(
                          value: 'pin',
                          child: Text(isPinned ? 'Unpin' : 'Pin'),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void showHistorySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: GlassPanel(
              padding: const EdgeInsets.all(16),
              borderRadius: BorderRadius.circular(30),
              opacity: 0.24,
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.72,
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Chat History',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        _topIconButton(
                          icon: Icons.add_rounded,
                          tooltip: 'New chat',
                          onTap: () async {
                            Navigator.pop(context);
                            await createNewChat();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: historySearchController,
                      onChanged: (value) {
                        setState(() {
                          historySearchText = value;
                        });
                      },
                      decoration: InputDecoration(
                        hintText: 'Search history...',
                        prefixIcon: const Icon(Icons.manage_search_rounded),
                        suffixIcon: hasActiveHistorySearch
                            ? IconButton(
                                onPressed: () {
                                  historySearchController.clear();
                                  setState(() {
                                    historySearchText = '';
                                  });
                                },
                                icon: const Icon(Icons.close_rounded),
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filteredSessions.length,
                        itemBuilder: (context, index) {
                          final session = filteredSessions[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _historyTile(session),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget buildChatTimeline() {
    final visibleMessages = filteredMessages;

    if (!hasMessages && showWelcome) {
      return buildWelcomeScreen();
    }

    if (visibleMessages.isEmpty) {
      return Center(
        child: GlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Text(
            'No matching messages found.',
            style: TextStyle(color: AppTheme.textMuted(context)),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: visibleMessages.length + (isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (isLoading && index == visibleMessages.length) {
          return Align(
            alignment: Alignment.centerLeft,
            child: GlassPanel(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              borderRadius: BorderRadius.circular(22),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'FLOWGNIMAG is typing...',
                    style: TextStyle(color: AppTheme.textMuted(context)),
                  ),
                ],
              ),
            ),
          );
        }

        return buildMessageBubble(visibleMessages[index]);
      },
    );
  }

  Widget buildChatPanel(bool isWide) {
    return Column(
      children: [
        buildTopBar(isWide),
        buildSettingsInfoBar(),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            child: KeyedSubtree(
              key: ValueKey('${currentSessionId}_${messages.length}'),
              child: buildChatTimeline(),
            ),
          ),
        ),
        SafeArea(top: false, child: buildComposer()),
      ],
    );
  }

  @override
  void dispose() {
    widget.onListeningChanged?.call(false);
    widget.onSpeakingChanged?.call(false);

    unawaited(_unregisterPushToken());
    _activeTimer?.cancel();
    _stopGoogleAlertsMonitor();
    _fcmOnMessageSub?.cancel();
    _fcmTokenRefreshSub?.cancel();
    speech.stop();
    speech.cancel();
    flutterTts.stop();
    controller.dispose();
    historySearchController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 980;

    return GradientScaffoldBackground(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: isWide ? 8 : 0),
        child: buildChatPanel(isWide),
      ),
    );
  }
}
