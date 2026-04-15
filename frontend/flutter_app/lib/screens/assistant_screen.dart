import 'dart:async';
import 'package:flutter/material.dart';

class AssistantScreen extends StatefulWidget {
  final bool isOnlineMode;
  final bool isListening;
  final bool isSpeaking;
  final VoidCallback onOpenChat;
  final VoidCallback onVoiceCommand;

  const AssistantScreen({
    super.key,
    required this.isOnlineMode,
    required this.isListening,
    required this.isSpeaking,
    required this.onOpenChat,
    required this.onVoiceCommand,
  });

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  Timer? _timeTimer;
  String liveTime = '';

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
      lowerBound: 0.92,
      upperBound: 1.05,
    )..repeat(reverse: true);

    _updateTime();
    _timeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateTime();
    });
  }

  void _updateTime() {
    final now = DateTime.now();

    int hour = now.hour;
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';

    hour = hour % 12;
    if (hour == 0) hour = 12;

    if (!mounted) return;

    setState(() {
      liveTime = "$hour:$minute:$second $period";
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _timeTimer?.cancel();
    super.dispose();
  }

  String getStatusTitle() {
    if (widget.isListening) return "Listening";
    if (widget.isSpeaking) return "Speaking";
    return widget.isOnlineMode ? "Online" : "Offline";
  }

  IconData getMainStatusIcon() {
    if (widget.isListening) return Icons.mic;
    if (widget.isSpeaking) return Icons.graphic_eq;
    if (widget.isOnlineMode) return Icons.memory;
    return Icons.offline_bolt;
  }

  Color getMainStatusColor() {
    if (widget.isListening) return Colors.orangeAccent;
    if (widget.isSpeaking) return Colors.blueAccent;
    if (widget.isOnlineMode) return Colors.greenAccent;
    return Colors.deepOrangeAccent;
  }

  Widget buildTopPanel() {
    final statusColor = getMainStatusColor();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          colors: [
            statusColor.withValues(alpha: 0.18),
            Colors.black.withValues(alpha: 0.25),
            Colors.blue.withValues(alpha: 0.08),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.28),
        ),
      ),
      child: Column(
        children: [
          ScaleTransition(
            scale: _pulseController,
            child: Container(
              height: 92,
              width: 92,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: statusColor.withValues(alpha: 0.10),
                border: Border.all(
                  color: statusColor.withValues(alpha: 0.5),
                  width: 2,
                ),
              ),
              child: Icon(
                getMainStatusIcon(),
                size: 42,
                color: statusColor,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            "FLOWGNIMAG",
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            getStatusTitle(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: statusColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.access_time, size: 16, color: Colors.white70),
                const SizedBox(width: 8),
                Text(
                  liveTime,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildQuickActionCard({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    required Color glowColor,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            Container(
              height: 48,
              width: 48,
              decoration: BoxDecoration(
                color: glowColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: glowColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white38),
          ],
        ),
      ),
    );
  }

  Widget buildStatusRow() {
    return Row(
      children: [
        Expanded(
          child: _statusChip(
            icon: widget.isOnlineMode ? Icons.wifi : Icons.wifi_off,
            label: widget.isOnlineMode ? 'Online' : 'Offline',
            color: widget.isOnlineMode ? Colors.greenAccent : Colors.orangeAccent,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _statusChip(
            icon: widget.isListening ? Icons.mic : Icons.hearing_disabled_outlined,
            label: widget.isListening ? 'Listening' : 'Idle',
            color: widget.isListening ? Colors.orangeAccent : Colors.white70,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _statusChip(
            icon: widget.isSpeaking ? Icons.volume_up : Icons.volume_off_outlined,
            label: widget.isSpeaking ? 'Speaking' : 'Silent',
            color: widget.isSpeaking ? Colors.blueAccent : Colors.white70,
          ),
        ),
      ],
    );
  }

  Widget _statusChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          buildTopPanel(),
          const SizedBox(height: 16),
          buildStatusRow(),
          const SizedBox(height: 20),
          buildQuickActionCard(
            icon: Icons.chat_bubble_outline,
            title: "Open Chat",
            onTap: widget.onOpenChat,
            glowColor: Colors.blueAccent,
          ),
          const SizedBox(height: 12),
          buildQuickActionCard(
            icon: Icons.mic,
            title: "Voice Start",
            onTap: widget.onVoiceCommand,
            glowColor: Colors.orangeAccent,
          ),
        ],
      ),
    );
  }
}
