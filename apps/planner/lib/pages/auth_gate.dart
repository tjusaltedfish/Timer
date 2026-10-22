import 'dart:async';

import 'package:flutter/material.dart';

import '../controller.dart';
import '../onboarding/onboarding_host.dart';
import '../reminders.dart';
import '../theme/tokens.dart';
import '../updates.dart';
import '../widgets/paper_background.dart';
import '../widgets/seal.dart';
import 'login_page.dart';

/// Decides between the login page and the planner.
///
/// Without a persisted token the login page appears immediately; with one the
/// app first checks `GET /api/v1/me`. A rejected token (401) drops the session
/// and routes back to login; an unreachable server keeps cached data usable.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.controller,
    this.reminders,
    this.updates,
  });
  final PlannerController controller;
  final ReminderService? reminders;
  final UpdateService? updates;
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  PlannerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.requiresLogin = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(c.bootstrapSession());
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      if (!c.sessionChecked) return const SessionLoadingPage();
      if (!c.authenticated) return LoginPage(controller: c);
      return OnboardingHost(
        controller: c,
        reminders: widget.reminders,
        updates: widget.updates,
      );
    },
  );
}

/// First frame while a persisted token is checked against the server.
class SessionLoadingPage extends StatelessWidget {
  const SessionLoadingPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: PaperBackground(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Seal('瞬', label: '瞬时', size: 44),
            const SizedBox(height: 18),
            Text(
              '正在进入瞬时',
              style: TextStyle(
                fontSize: 15,
                color: context.inkPalette.inkZhong,
              ),
            ),
            const SizedBox(height: 16),
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
          ],
        ),
      ),
    ),
  );
}
