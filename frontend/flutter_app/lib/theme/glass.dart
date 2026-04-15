import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_theme.dart';

class GradientScaffoldBackground extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;

  const GradientScaffoldBackground({
    super.key,
    required this.child,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(gradient: AppTheme.backgroundGradient(isDark)),
      child: Stack(
        children: [
          Positioned(
            top: -80,
            right: -40,
            child: _GlowOrb(
              size: 220,
              color: AppTheme.primary.withValues(alpha: isDark ? 0.22 : 0.18),
            ),
          ),
          Positioned(
            left: -60,
            bottom: 80,
            child: _GlowOrb(
              size: 180,
              color: AppTheme.accent.withValues(alpha: isDark ? 0.18 : 0.14),
            ),
          ),
          Positioned.fill(
            child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
          ),
        ],
      ),
    );
  }
}

class GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadius? borderRadius;
  final double blur;
  final double opacity;

  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius,
    this.blur = 18,
    this.opacity = 0.18,
  });

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(24);

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: AppTheme.glassShadow(context),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: radius,
              color: AppTheme.glassFill(context, opacity: opacity),
              border: Border.all(color: AppTheme.glassBorder(context)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(
                    alpha:
                    Theme.of(context).brightness == Brightness.dark
                        ? 0.12
                        : 0.34,
                  ),
                  Colors.white.withValues(
                    alpha:
                    Theme.of(context).brightness == Brightness.dark
                        ? 0.03
                        : 0.08,
                  ),
                ],
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class RevealSlide extends StatelessWidget {
  final Widget child;
  final int index;
  final Offset beginOffset;

  const RevealSlide({
    super.key,
    required this.child,
    this.index = 0,
    this.beginOffset = const Offset(0, 0.05),
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + (index * 70)),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(
              beginOffset.dx * 40 * (1 - value),
              beginOffset.dy * 40 * (1 - value),
            ),
            child: child,
          ),
        );
      },
    );
  }
}

class _GlowOrb extends StatelessWidget {
  final double size;
  final Color color;

  const _GlowOrb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0.0)]),
        ),
      ),
    );
  }
}
