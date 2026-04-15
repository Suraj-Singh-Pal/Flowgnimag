import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../services/pulseiq_service.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'auth_screen.dart';
import 'assistant_screen.dart';
import 'chat_screen.dart';
import 'home_screen.dart';
import 'notes_screen.dart';
import 'settings_screen.dart';
import 'tasks_screen.dart';

class MainScreen extends StatefulWidget {
  final VoidCallback toggleTheme;

  const MainScreen({super.key, required this.toggleTheme});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int currentIndex = 0;
  int chatHistorySignal = 0;
  int? _lastTrackedIndex;

  bool isOnlineMode = true;
  bool isAssistantListening = false;
  bool isAssistantSpeaking = false;
  bool startVoiceFromAssistant = false;
  bool isExitProcessing = false;
  AuthSession? currentSession;

  late final Connectivity connectivity;
  StreamSubscription<List<ConnectivityResult>>? connectivitySubscription;

  @override
  void initState() {
    super.initState();
    connectivity = Connectivity();
    initConnectivity();
    connectivitySubscription = connectivity.onConnectivityChanged.listen(
      updateConnectionStatus,
    );
    loadCurrentSession();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _trackCurrentScreen('init_state');
    });
  }

  Future<void> loadCurrentSession() async {
    final session = await AuthService.getStoredSession();
    if (!mounted) return;
    setState(() {
      currentSession = session;
    });
  }

  Future<void> initConnectivity() async {
    final results = await connectivity.checkConnectivity();
    updateConnectionStatus(results);
  }

  void updateConnectionStatus(List<ConnectivityResult> results) {
    final hasConnection = !results.contains(ConnectivityResult.none);

    if (!mounted) return;

    setState(() {
      isOnlineMode = hasConnection;
    });
  }

  @override
  void dispose() {
    connectivitySubscription?.cancel();
    super.dispose();
  }

  void goToTab(int index) {
    if (!mounted) return;

    setState(() {
      currentIndex = index;
    });

    _trackCurrentScreen('drawer_tab_switch');
    Navigator.of(context).maybePop();
  }

  void openChatTab() {
    if (!mounted) return;
    setState(() {
      currentIndex = 2;
    });
    _trackCurrentScreen('open_chat_tab');
  }

  void openChatHistory() {
    if (!mounted) return;
    setState(() {
      currentIndex = 2;
      chatHistorySignal++;
    });
    _trackCurrentScreen('open_chat_history');
    Navigator.of(context).maybePop();
  }

  void startVoiceCommand() {
    if (!mounted) return;
    setState(() {
      currentIndex = 2;
      startVoiceFromAssistant = true;
    });
    _trackCurrentScreen('assistant_voice_command');
  }

  void resetVoiceTrigger() {
    if (!mounted || !startVoiceFromAssistant) return;

    Future.microtask(() {
      if (!mounted) return;
      setState(() {
        startVoiceFromAssistant = false;
      });
    });
  }

  String getScreenTitle() {
    switch (currentIndex) {
      case 0:
        return "FLOWGNIMAG";
      case 1:
        return "Assistant";
      case 2:
        return "Chat";
      case 3:
        return "Notes";
      case 4:
        return "Tasks";
      case 5:
        return "Settings";
      default:
        return "FLOWGNIMAG";
    }
  }

  String getAnalyticsScreenName() {
    switch (currentIndex) {
      case 0:
        return 'HomeScreen';
      case 1:
        return 'AssistantScreen';
      case 2:
        return 'ChatScreen';
      case 3:
        return 'NotesScreen';
      case 4:
        return 'TasksScreen';
      case 5:
        return 'SettingsScreen';
      default:
        return 'UnknownScreen';
    }
  }

  void _trackCurrentScreen(String trigger) {
    final screenName = getAnalyticsScreenName();
    final previousIndex = _lastTrackedIndex;
    _lastTrackedIndex = currentIndex;
    PulseIQService.screenView(
      screenName,
      properties: {
        'trigger': trigger,
        'main_tab_index': currentIndex,
        'previous_main_tab_index': previousIndex,
      },
    );
  }

  String get currentUserName {
    final name = currentSession?.name.trim() ?? '';
    if (name.isNotEmpty) return name;
    final email = currentSession?.email.trim() ?? '';
    if (email.contains('@')) {
      return email.split('@').first;
    }
    return 'Cloud User';
  }

  String get currentUserEmail =>
      currentSession?.email.trim() ?? 'No email found';

  Future<void> promptLogoutAndExit() async {
    if (isExitProcessing) return;

    final shouldExit =
        await showGeneralDialog<bool>(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Exit FLOWGNIMAG',
          barrierColor: Colors.black.withValues(alpha: 0.55),
          transitionDuration: const Duration(milliseconds: 240),
          pageBuilder: (context, animation, secondaryAnimation) {
            return _ExitDialog(
              userName: currentUserName,
              userEmail: currentUserEmail,
              isProcessing: isExitProcessing,
            );
          },
          transitionBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween(begin: 0.92, end: 1.0).animate(curved),
                child: child,
              ),
            );
          },
        ) ??
        false;

    if (!shouldExit) return;

    if (mounted) {
      setState(() => isExitProcessing = true);
    }

    try {
      await PulseIQService.track('exit_confirmed', {
        'screen_name': getAnalyticsScreenName(),
        'user_email': currentUserEmail,
      });
      await AuthService.logout(currentSession);
      await PulseIQService.clearIdentity();
      await PulseIQService.track('page_view', {
        'screen_name': 'AuthScreen',
        'trigger': 'logout_exit',
      });
    } finally {
      await SystemNavigator.pop();
      if (mounted) {
        setState(() => isExitProcessing = false);
      }
    }
  }

  Future<bool> handleBackPress() async {
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
      return false;
    }

    await promptLogoutAndExit();
    return false;
  }

  Future<void> logoutToAuthScreen() async {
    if (isExitProcessing) return;
    setState(() => isExitProcessing = true);
    try {
      await PulseIQService.track('logout_button_click', {
        'screen_name': getAnalyticsScreenName(),
        'user_email': currentUserEmail,
      });
      await AuthService.logout(currentSession);
      await PulseIQService.clearIdentity();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          settings: const RouteSettings(name: 'AuthScreen'),
          builder: (_) => AuthScreen(toggleTheme: widget.toggleTheme),
        ),
        (route) => false,
      );
    } finally {
      if (mounted) {
        setState(() => isExitProcessing = false);
      }
    }
  }

  String getConnectionText() {
    return isOnlineMode ? "Online Mode" : "Offline Mode";
  }

  Color getConnectionColor() {
    return isOnlineMode ? const Color(0xFF67E8A8) : AppTheme.accent;
  }

  IconData getConnectionIcon() {
    return isOnlineMode ? Icons.wifi : Icons.wifi_off;
  }

  Widget buildDrawerItem({
    required IconData icon,
    required String title,
    required int index,
  }) {
    final isSelected = currentIndex == index;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: GlassPanel(
        borderRadius: BorderRadius.circular(18),
        opacity: isSelected ? 0.20 : 0.12,
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          leading: Icon(
            icon,
            color: isSelected ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(
            title,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              color: isSelected ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
          trailing: isSelected
              ? const Icon(Icons.arrow_forward_ios_rounded, size: 14)
              : null,
          onTap: () => goToTab(index),
        ),
      ),
    );
  }

  List<Widget> buildScreens() {
    return [
      HomeScreen(
        onOpenChat: openChatTab,
        onOpenNotes: () => goToTab(3),
        onOpenTasks: () => goToTab(4),
      ),
      AssistantScreen(
        isOnlineMode: isOnlineMode,
        isListening: isAssistantListening,
        isSpeaking: isAssistantSpeaking,
        onOpenChat: openChatTab,
        onVoiceCommand: startVoiceCommand,
      ),
      ChatScreen(
        isOnlineMode: isOnlineMode,
        autoStartListening: startVoiceFromAssistant,
        openHistorySignal: chatHistorySignal,
        onListeningChanged: (value) {
          if (!mounted) return;
          setState(() {
            isAssistantListening = value;
          });
        },
        onSpeakingChanged: (value) {
          if (!mounted) return;
          setState(() {
            isAssistantSpeaking = value;
          });
        },
      ),
      const NotesScreen(),
      const TasksScreen(),
      SettingsScreen(toggleTheme: widget.toggleTheme),
    ];
  }

  Widget buildConnectionBadge() {
    final connectionColor = getConnectionColor();

    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      borderRadius: BorderRadius.circular(999),
      opacity: 0.16,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(getConnectionIcon(), size: 16, color: connectionColor),
          const SizedBox(width: 8),
          Text(
            getConnectionText(),
            style: TextStyle(
              color: connectionColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildDrawerHeader() {
    return GlassPanel(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      borderRadius: BorderRadius.circular(28),
      opacity: 0.22,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                colors: [
                  AppTheme.primary.withValues(alpha: 0.28),
                  AppTheme.secondary.withValues(alpha: 0.22),
                ],
              ),
            ),
            child: Image.asset("assets/images/wolf.png", height: 46),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "FLOWGNIMAG",
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  currentUserName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  currentUserEmail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Logout',
            onPressed: isExitProcessing ? null : logoutToAuthScreen,
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    resetVoiceTrigger();
    final screens = buildScreens();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await handleBackPress();
      },
      child: GradientScaffoldBackground(
        child: Scaffold(
          key: _scaffoldKey,
          backgroundColor: Colors.transparent,
          extendBody: true,
          appBar: AppBar(
            title: Text(
              getScreenTitle(),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(child: buildConnectionBadge()),
              ),
            ],
          ),
          drawer: Drawer(
            backgroundColor: Colors.transparent,
            elevation: 0,
            child: GradientScaffoldBackground(
              child: SafeArea(
                child: Column(
                  children: [
                    buildDrawerHeader(),
                    buildDrawerItem(
                      icon: Icons.home_outlined,
                      title: "Home",
                      index: 0,
                    ),
                    buildDrawerItem(
                      icon: Icons.smart_toy_outlined,
                      title: "Assistant",
                      index: 1,
                    ),
                    buildDrawerItem(
                      icon: Icons.chat_bubble_outline,
                      title: "Chat",
                      index: 2,
                    ),
                    if (currentIndex == 2)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        child: GlassPanel(
                          borderRadius: BorderRadius.circular(18),
                          opacity: 0.16,
                          child: ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            leading: Icon(
                              Icons.history_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            title: Text(
                              "Chat History",
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            onTap: openChatHistory,
                          ),
                        ),
                      ),
                    buildDrawerItem(
                      icon: Icons.note_alt_outlined,
                      title: "Notes",
                      index: 3,
                    ),
                    buildDrawerItem(
                      icon: Icons.check_circle_outline,
                      title: "Tasks",
                      index: 4,
                    ),
                    buildDrawerItem(
                      icon: Icons.settings_outlined,
                      title: "Settings",
                      index: 5,
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ),
          ),
          body: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: KeyedSubtree(
              key: ValueKey(currentIndex),
              child: screens[currentIndex],
            ),
          ),
          bottomNavigationBar: null,
        ),
      ),
    );
  }
}

class _ExitDialog extends StatelessWidget {
  final String userName;
  final String userEmail;
  final bool isProcessing;

  const _ExitDialog({
    required this.userName,
    required this.userEmail,
    required this.isProcessing,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: GlassPanel(
            padding: const EdgeInsets.all(24),
            borderRadius: BorderRadius.circular(28),
            opacity: 0.22,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          gradient: LinearGradient(
                            colors: [AppTheme.accent, AppTheme.primary],
                          ),
                        ),
                        child: const Icon(
                          Icons.logout_rounded,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          'Logout and exit?',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Current user: $userName\nEmail: $userEmail\n\nIf you exit now, the app will log this account out properly before closing.',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppTheme.textMuted(context),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: isProcessing
                              ? null
                              : () => Navigator.of(context).pop(false),
                          child: const Text('Stay'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: isProcessing
                              ? null
                              : () => Navigator.of(context).pop(true),
                          child: isProcessing
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                  ),
                                )
                              : const Text('Logout & Exit'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
