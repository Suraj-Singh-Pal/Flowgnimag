import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/pulseiq_service.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {}
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (_) {}
  runApp(const FlowgnimagApp());
}

class FlowgnimagApp extends StatefulWidget {
  const FlowgnimagApp({super.key});

  @override
  State<FlowgnimagApp> createState() => _FlowgnimagAppState();
}

class _FlowgnimagAppState extends State<FlowgnimagApp> {
  static const String themeKey = 'flowgnimag_is_dark_mode';
  final PulseIQNavigatorObserver _pulseObserver = PulseIQNavigatorObserver();

  bool isDarkMode = true;
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    loadTheme();
    PulseIQService.track('app_open', {'source': 'main_init'});
  }

  Future<void> loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTheme = prefs.getBool(themeKey);

    if (!mounted) return;

    setState(() {
      isDarkMode = savedTheme ?? true;
      isLoading = false;
    });
  }

  Future<void> toggleTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final newValue = !isDarkMode;

    await prefs.setBool(themeKey, newValue);

    if (!mounted) return;

    setState(() {
      isDarkMode = newValue;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme(),
        navigatorObservers: [_pulseObserver],
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FLOWGNIMAG',
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
      navigatorObservers: [_pulseObserver],
      home: SplashScreen(toggleTheme: toggleTheme),
    );
  }
}
