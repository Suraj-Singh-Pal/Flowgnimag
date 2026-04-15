import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/glass.dart';

class HomeScreen extends StatelessWidget {
  final VoidCallback onOpenChat;
  final VoidCallback onOpenNotes;
  final VoidCallback onOpenTasks;

  const HomeScreen({
    super.key,
    required this.onOpenChat,
    required this.onOpenNotes,
    required this.onOpenTasks,
  });

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width > 760;

    return GradientScaffoldBackground(
      child: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RevealSlide(child: _buildHeroSection(context)),
              const SizedBox(height: 18),
              RevealSlide(
                index: 1,
                child: _buildQuickActionsSection(context, isWide),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeroSection(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return GlassPanel(
      padding: const EdgeInsets.all(24),
      borderRadius: BorderRadius.circular(32),
      opacity: 0.20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 72,
                width: 72,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      AppTheme.primary.withValues(alpha: 0.28),
                      AppTheme.accent.withValues(alpha: 0.20),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                  ),
                ),
                child: Image.asset("assets/images/wolf.png"),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text("FLOWGNIMAG", style: textTheme.headlineMedium),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ElevatedButton.icon(
                onPressed: onOpenChat,
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text("Chat"),
              ),
              OutlinedButton.icon(
                onPressed: onOpenNotes,
                icon: const Icon(Icons.note_alt_outlined),
                label: const Text("Notes"),
              ),
              OutlinedButton.icon(
                onPressed: onOpenTasks,
                icon: const Icon(Icons.task_alt_outlined),
                label: const Text("Tasks"),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionsSection(BuildContext context, bool isWide) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Quick Actions", style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: isWide ? 4 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: isWide ? 1.3 : 1.1,
          children: [
            _ActionCard(
              icon: Icons.chat_rounded,
              title: "AI Chat",
              color: AppTheme.primary,
              onTap: onOpenChat,
            ),
            _ActionCard(
              icon: Icons.draw_outlined,
              title: "Images",
              color: AppTheme.secondary,
              onTap: onOpenChat,
            ),
            _ActionCard(
              icon: Icons.note_alt_outlined,
              title: "Notes",
              color: AppTheme.accent,
              onTap: onOpenNotes,
            ),
            _ActionCard(
              icon: Icons.task_alt,
              title: "Tasks",
              color: const Color(0xFF67E8A8),
              onTap: onOpenTasks,
            ),
          ],
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 44,
                width: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: color.withValues(alpha: 0.20),
                ),
                child: Icon(icon, color: color),
              ),
              const Spacer(),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
