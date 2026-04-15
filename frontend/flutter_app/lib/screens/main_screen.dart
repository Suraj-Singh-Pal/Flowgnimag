import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/glass.dart';
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
  int currentIndex = 0;
  int chatHistorySignal = 0;

  bool isOnlineMode = true;
  bool isAssistantListening = false;
  bool isAssistantSpeaking = false;
  bool startVoiceFromAssistant = false;

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

    Navigator.of(context).maybePop();
  }

  void openChatTab() {
    if (!mounted) return;
    setState(() {
      currentIndex = 2;
    });
  }

  void openChatHistory() {
    if (!mounted) return;
    setState(() {
      currentIndex = 2;
      chatHistorySignal++;
    });
    Navigator.of(context).maybePop();
  }

  void startVoiceCommand() {
    if (!mounted) return;
    setState(() {
      currentIndex = 2;
      startVoiceFromAssistant = true;
    });
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    resetVoiceTrigger();
    final screens = buildScreens();

    return GradientScaffoldBackground(
      child: Scaffold(
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
    );
  }
}
