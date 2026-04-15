import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/pulseiq_service.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'main_screen.dart';

class AuthScreen extends StatefulWidget {
  final VoidCallback toggleTheme;

  const AuthScreen({super.key, required this.toggleTheme});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool isSignup = false;
  bool isSubmitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PulseIQService.screenView(
        'AuthScreen',
        properties: {'trigger': 'auth_required'},
      );
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate() || isSubmitting) {
      return;
    }

    setState(() => isSubmitting = true);

    try {
      if (isSignup) {
        await PulseIQService.signupClick(properties: {'source': 'auth_screen'});
      }

      final session = isSignup
          ? await AuthService.signUp(
              name: _nameController.text.trim(),
              email: _emailController.text.trim(),
              password: _passwordController.text,
            )
          : await AuthService.signIn(
              email: _emailController.text.trim(),
              password: _passwordController.text,
            );

      await PulseIQService.identify(session.email);
      await PulseIQService.formSubmit(
        properties: {
          'form_name': isSignup ? 'signup' : 'login',
          'email_domain': session.email.contains('@')
              ? session.email.split('@').last
              : 'unknown',
        },
      );
      await PulseIQService.track(
        isSignup ? 'signup_success' : 'login_success',
        {
          'channel': 'cloud_email_password',
          'email_domain': session.email.contains('@')
              ? session.email.split('@').last
              : 'unknown',
        },
      );

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          settings: const RouteSettings(name: 'MainScreen'),
          builder: (_) => MainScreen(toggleTheme: widget.toggleTheme),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isSubmitting = false);
      }
    }
  }

  String? validateName(String? value) {
    if (!isSignup) return null;
    if ((value ?? '').trim().length < 2) {
      return 'Please enter your full name.';
    }
    return null;
  }

  String? validateEmail(String? value) {
    final email = (value ?? '').trim();
    if (email.isEmpty) {
      return 'Email is required.';
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  String? validatePassword(String? value) {
    final password = value ?? '';
    if (password.length < 6) {
      return 'Password must be at least 6 characters.';
    }
    return null;
  }

  Widget buildModeToggle() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.glassFill(context, opacity: 0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.glassBorder(context, opacity: 0.24)),
      ),
      child: Row(
        children: [
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              child: TextButton(
                onPressed: isSubmitting
                    ? null
                    : () => setState(() {
                        isSignup = false;
                      }),
                style: TextButton.styleFrom(
                  backgroundColor: !isSignup
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.18)
                      : Colors.transparent,
                  foregroundColor: !isSignup
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).textTheme.bodyLarge?.color,
                ),
                child: const Text('Login'),
              ),
            ),
          ),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              child: TextButton(
                onPressed: isSubmitting
                    ? null
                    : () => setState(() {
                        isSignup = true;
                      }),
                style: TextButton.styleFrom(
                  backgroundColor: isSignup
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.18)
                      : Colors.transparent,
                  foregroundColor: isSignup
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).textTheme.bodyLarge?.color,
                ),
                child: const Text('Sign Up'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildHeroCard() {
    final muted = AppTheme.textMuted(context);

    return RevealSlide(
      child: GlassPanel(
        padding: const EdgeInsets.all(28),
        borderRadius: BorderRadius.circular(30),
        opacity: 0.18,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  colors: [
                    Theme.of(context).colorScheme.primary,
                    AppTheme.secondary,
                  ],
                ),
              ),
              child: const Icon(
                Icons.lock_open_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              'Secure access to your AI workspace',
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontSize: 30),
            ),
            const SizedBox(height: 12),
            Text(
              'Login before opening chat, dashboard, notes, and task workflows. Your session stays active until you log out.',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: muted),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: const [
                _AuthPill(
                  icon: Icons.shield_outlined,
                  label: 'Persistent sessions',
                ),
                _AuthPill(
                  icon: Icons.chat_bubble_outline,
                  label: 'Protected chat access',
                ),
                _AuthPill(
                  icon: Icons.cloud_sync_outlined,
                  label: 'Cloud-linked workspace',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget buildFormCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return RevealSlide(
      index: 1,
      child: GlassPanel(
        padding: const EdgeInsets.all(24),
        borderRadius: BorderRadius.circular(30),
        opacity: isDark ? 0.16 : 0.32,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isSignup ? 'Create your account' : 'Welcome back',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                isSignup
                    ? 'Set up your cloud account to unlock the full FLOWGNIMAG workspace.'
                    : 'Use your cloud credentials to continue where you left off.',
                style: TextStyle(
                  color: AppTheme.textMuted(context),
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 20),
              buildModeToggle(),
              const SizedBox(height: 20),
              if (isSignup) ...[
                TextFormField(
                  controller: _nameController,
                  textInputAction: TextInputAction.next,
                  validator: validateName,
                  decoration: const InputDecoration(
                    labelText: 'Full Name',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                validator: validateEmail,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.mail_outline_rounded),
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                textInputAction: TextInputAction.done,
                validator: validatePassword,
                onFieldSubmitted: (_) => submit(),
                decoration: const InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: isSubmitting ? null : submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: isSubmitting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : Text(isSignup ? 'Create Account' : 'Login'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: isSubmitting
                      ? null
                      : () => setState(() {
                          isSignup = !isSignup;
                        }),
                  child: Text(
                    isSignup
                        ? 'Already have an account? Login'
                        : 'Need an account? Sign up',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GradientScaffoldBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 840;
                    return Flex(
                      direction: compact ? Axis.vertical : Axis.horizontal,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: compact ? 0 : 11,
                          child: buildHeroCard(),
                        ),
                        SizedBox(
                          width: compact ? 0 : 24,
                          height: compact ? 20 : 0,
                        ),
                        Expanded(flex: compact ? 0 : 9, child: buildFormCard()),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _AuthPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.glassFill(context, opacity: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.glassBorder(context, opacity: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).textTheme.bodyLarge?.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
