import "dart:convert";
import "dart:math";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_dotenv/flutter_dotenv.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

class PulseIQService {
  static String get apiKey {
    final fromDotEnv = dotenv.isInitialized
        ? (dotenv.env["PULSEIQ_API_KEY"] ?? "")
        : "";
    if (fromDotEnv.trim().isNotEmpty) return fromDotEnv.trim();
    return const String.fromEnvironment("PULSEIQ_API_KEY").trim();
  }

  static String get projectId {
    final fromDotEnv = dotenv.isInitialized
        ? (dotenv.env["PULSEIQ_PROJECT_ID"] ?? "")
        : "";
    if (fromDotEnv.trim().isNotEmpty) return fromDotEnv.trim();
    return const String.fromEnvironment(
      "PULSEIQ_PROJECT_ID",
      defaultValue: "69df59433719108df765d5ba",
    ).trim();
  }
  static const endpoint = "https://pulseiq-ffio.onrender.com/api/ingest/event";

  static Future<String> _getAnonId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString("_piq_anon");
    if (existing != null) return existing;
    final next = "anon_${Random().nextInt(99999999)}";
    await prefs.setString("_piq_anon", next);
    return next;
  }

  static Future<void> track(
    String eventName,
    Map<String, dynamic> properties,
  ) async {
    if (apiKey.trim().isEmpty) {
      if (kDebugMode) {
        debugPrint("PulseIQ skipped: missing PULSEIQ_API_KEY");
      }
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final anonId = await _getAnonId();
    final userId = prefs.getString("_piq_user");

    try {
      final response = await http.post(
        Uri.parse(endpoint),
        headers: {"Content-Type": "application/json", "x-api-key": apiKey},
        body: jsonEncode({
          "projectId": projectId,
          "eventName": eventName,
          "userId": userId,
          "anonymousId": anonId,
          "properties": properties,
        }),
      );
      if (kDebugMode) {
        final body = response.body.trim();
        debugPrint(
          "PulseIQ track: $eventName status=${response.statusCode} "
          "screen=${properties["screen_name"] ?? "-"} "
          "body=${body.isEmpty ? "-" : body}",
        );
      }
    } catch (_) {}
  }

  static Future<void> identify(String userId) async {
    final clean = userId.trim();
    if (clean.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("_piq_user", clean);
    await track("identify", {"userId": clean});
  }

  static Future<void> screenView(
    String screenName, {
    Map<String, dynamic> properties = const {},
  }) async {
    final cleanName = screenName.trim().isEmpty ? "unknown" : screenName.trim();
    final props = <String, dynamic>{"screen_name": cleanName, ...properties};
    await track("page_view", props);
  }

  static Future<void> signupClick({
    Map<String, dynamic> properties = const {},
  }) {
    return track("signup_click", properties);
  }

  static Future<void> purchase({Map<String, dynamic> properties = const {}}) {
    return track("purchase", properties);
  }

  static Future<void> formSubmit({Map<String, dynamic> properties = const {}}) {
    return track("form_submit", properties);
  }
}

class PulseIQNavigatorObserver extends NavigatorObserver {
  String _routeLabel(Route<dynamic>? route) {
    if (route == null) return "unknown";
    final name = route.settings.name;
    if (name != null && name.trim().isNotEmpty) return name;
    return route.runtimeType.toString();
  }

  Future<void> _trackRoute(
    Route<dynamic>? route, {
    Route<dynamic>? previousRoute,
    String trigger = "push",
  }) async {
    final current = _routeLabel(route);
    final previous = _routeLabel(previousRoute);
    await PulseIQService.screenView(
      current,
      properties: {"trigger": trigger, "previous_route": previous},
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _trackRoute(route, previousRoute: previousRoute, trigger: "push");
    super.didPush(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _trackRoute(newRoute, previousRoute: oldRoute, trigger: "replace");
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _trackRoute(previousRoute, previousRoute: route, trigger: "pop");
    super.didPop(route, previousRoute);
  }
}
