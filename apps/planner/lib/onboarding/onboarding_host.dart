import 'dart:async';

import 'package:flutter/material.dart';

import '../controller.dart';
import '../home.dart';
import '../reminders.dart';
import '../theme/tokens.dart';
import '../updates.dart';
import '../widgets/paper_background.dart';
import 'basic_setup_page.dart';
import 'coach_overlay.dart';
import 'onboarding_controller.dart';

/// Sits between the login gate and the planner: picks the first-run setup, the
/// planner with the coach tour on top, or a plain planner for accounts that
/// already finished (or predate) the v2 onboarding.
class OnboardingHost extends StatefulWidget {
  const OnboardingHost({
    super.key,
    required this.controller,
    this.reminders,
    this.updates,
  });

  final PlannerController controller;
  final ReminderService? reminders;
  final UpdateService? updates;

  @override
  State<OnboardingHost> createState() => _OnboardingHostState();
}

class _OnboardingHostState extends State<OnboardingHost> {
  late final OnboardingController _onboarding;

  @override
  void initState() {
    super.initState();
    _onboarding = OnboardingController(planner: widget.controller);
    unawaited(_onboarding.load());
  }

  @override
  void dispose() {
    _onboarding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _onboarding,
    builder: (context, _) {
      final onboarding = _onboarding;
      if (onboarding.loading) return const _HostLoading();
      if (onboarding.showSetup) return BasicSetupPage(controller: onboarding);
      final home = PlannerHome(
        controller: widget.controller,
        reminders: widget.reminders,
        updates: widget.updates,
        onboarding: onboarding,
      );
      if (!onboarding.showTutorial) return home;
      return Stack(
        children: [
          home,
          Positioned.fill(child: CoachOverlay(controller: onboarding)),
        ],
      );
    },
  );
}

class _HostLoading extends StatelessWidget {
  const _HostLoading();

  @override
  Widget build(BuildContext context) => PaperBackground(
    child: Scaffold(
      backgroundColor: context.inkPalette.paper.withValues(alpha: 0),
      body: const Center(child: Text('正在进入瞬时')),
    ),
  );
}
