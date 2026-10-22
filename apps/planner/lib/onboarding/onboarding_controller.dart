import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../controller.dart';
import 'onboarding_steps.dart';

/// Where the coach overlay finds the real widgets a step points at.
///
/// `home.dart` and `settings_page.dart` wrap their controls in a widget keyed
/// by [key] for every [CoachKeys] value; the overlay measures the rectangle
/// after layout instead of hard-coding coordinates.
class OnboardingTargets {
  final Map<String, GlobalKey> _keys = {};

  GlobalKey key(String id) =>
      _keys.putIfAbsent(id, () => GlobalKey(debugLabel: 'coach.$id'));

  /// Global rectangle of a registered target, or null when it is not mounted.
  Rect? rectOf(String id) {
    final context = _keys[id]?.currentContext;
    if (context == null) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

/// First-run setup and the ten-step coach tour for v2 accounts (plan §10.1).
///
/// The account record (`GET /api/v1/me` → `user.onboarding`) is the cross-device
/// source of truth; a local copy lives in [storageKey] so the tour keeps its
/// place offline and every progress change is pushed best-effort afterwards.
/// Accounts without the `onboarding` field (older records) are [legacy]: the
/// planner behaves exactly as before and no tour appears.
class OnboardingController extends ChangeNotifier {
  OnboardingController({required this.planner}) {
    planner.addListener(_onPlannerChanged);
  }

  static const storageKey = 'onboarding_v2';
  static const version = 2;
  static const _timeout = Duration(seconds: 10);

  final PlannerController planner;
  final OnboardingTargets targets = OnboardingTargets();

  bool _loading = true;
  bool _enabled = false;
  bool _legacy = false;
  bool _setupDone = false;
  bool _tutorialDone = false;
  int _stepIndex = 0;
  String _assistantStyle = 'auto';
  final List<String> _done = [];
  final List<String> _skipped = [];
  bool _disposed = false;

  /// Set when a progress push did not reach the computer; the next time the
  /// controller reports a live connection the latest progress is retried.
  bool _pushPending = false;
  bool _pushing = false;

  /// True until the cached record has been read; the host keeps the paper
  /// blank for that single frame instead of flashing the planner.
  bool get loading => _loading;

  /// True when the signed-in account carries an `onboarding` object.
  bool get enabled => _enabled;

  /// True for accounts created before v2 (no `onboarding` field): never asked.
  bool get legacy => _legacy;
  bool get setupDone => _setupDone;
  bool get tutorialDone => _tutorialDone;
  int get stepIndex => _stepIndex;
  int get stepCount => coachSteps.length;
  List<String> get done => List.unmodifiable(_done);
  List<String> get skipped => List.unmodifiable(_skipped);
  String get assistantStyle => _assistantStyle;
  bool get confirmFirst => _assistantStyle == 'confirm';

  CoachStep get step => coachSteps[_stepIndex.clamp(0, stepCount - 1)];

  /// First screen: display name, timezone, daily window and assistant style.
  bool get showSetup => _enabled && !_setupDone;

  /// The coach tour, resumed wherever it was left.
  bool get showTutorial => _enabled && _setupDone && !_tutorialDone;

  Future<void> load() async {
    final user = planner.user;
    final raw = user?['onboarding'];
    _enabled = raw is Map;
    _legacy = user != null && !_enabled;
    if (_enabled) {
      final server = (raw as Map).cast<String, dynamic>();
      Json? local;
      try {
        final cached = await planner.storage.read(storageKey);
        if (cached != null) local = jsonDecode(cached) as Json;
      } catch (_) {
        // A damaged record falls back to the server copy.
      }
      if (local != null) {
        // A local record exists once this device started the flow; it is the
        // authoritative copy so an offline "skipped"/"finished" is not undone
        // by the older server value.
        _setupDone = local['setup_done'] as bool? ?? false;
        _tutorialDone = local['tutorial_done'] as bool? ?? false;
        _stepIndex = _asInt(local['step']);
        _assistantStyle = local['assistant_style'] as String? ?? 'auto';
        _done
          ..clear()
          ..addAll(_asStrings(local['done']));
        _skipped
          ..clear()
          ..addAll(_asStrings(local['skipped']));
      } else {
        final serverDone = _asStrings(server['done']);
        final serverSkipped = _asStrings(server['skipped']);
        final serverStep = _asInt(server['step']);
        // Past step 0 (or with done marks) means setup already happened on
        // another device; a brand-new account starts at the setup screen.
        _setupDone = serverStep > 0 || serverDone.isNotEmpty;
        _tutorialDone = serverDone.contains(StepId.finish);
        _stepIndex = serverStep;
        _assistantStyle = server['assistant_style'] as String? ?? 'auto';
        _done.addAll(serverDone);
        _skipped.addAll(serverSkipped);
        await _persist();
      }
      _clampStep();
    }
    _loading = false;
    _notify();
    // Progress made offline (or on another capture of the same record) is
    // reconciled as soon as the computer can be reached.
    if (_enabled) unawaited(_push({'onboarding': _progress()}));
  }

  /// Applies the basic setup; local first, then best-effort server sync.
  Future<void> completeSetup({
    required String displayName,
    required String timezone,
    required String dayStart,
    required String dayEnd,
    required bool confirmFirst,
  }) async {
    if (!_enabled) return;
    final replayed = _setupDone;
    _setupDone = true;
    _assistantStyle = confirmFirst ? 'confirm' : 'auto';
    if (!replayed && !_tutorialDone) _stepIndex = 0;
    _notify();
    await _persist();

    // The daily window and timezone are regular settings operations: applied
    // locally right away, queued until the computer is reachable.
    final settings = <String, dynamic>{};
    if (dayStart != planner.settings['day_start']) {
      settings['day_start'] = dayStart;
    }
    if (dayEnd != planner.settings['day_end']) settings['day_end'] = dayEnd;
    if (timezone != planner.settings['timezone']) {
      settings['timezone'] = timezone;
    }
    if (settings.isNotEmpty) unawaited(_submitSettings(settings));

    final patch = <String, dynamic>{
      'onboarding': _progress(),
      'display_name': displayName.trim(),
      'timezone': timezone,
    };
    unawaited(_push(patch));

    // The assistant style is stored on the computer and only a desktop account
    // may change it; an unreachable server just keeps the local preference.
    if (planner.state['device']?['role'] == 'desktop' && planner.configured) {
      unawaited(_pushAssistantStyle(confirmFirst));
    }
  }

  /// Next step; the last one finishes the tour and closes the overlay.
  Future<void> next() async {
    if (!_enabled || _tutorialDone) return;
    final current = step;
    if (!_done.contains(current.id)) _done.add(current.id);
    if (_stepIndex >= stepCount - 1) {
      await finish();
      return;
    }
    _stepIndex += 1;
    _notify();
    await _persist();
    unawaited(_push({'onboarding': _progress()}));
  }

  Future<void> previous() async {
    if (!_enabled || _stepIndex <= 0) return;
    _stepIndex -= 1;
    _notify();
    await _persist();
    unawaited(_push({'onboarding': _progress()}));
  }

  /// Skips the rest of the tour. Remembered as [skipped] so "重新看教程" is the
  /// only way it comes back.
  Future<void> skip() async {
    if (!_enabled || _tutorialDone) return;
    for (final remaining in coachSteps.skip(_stepIndex)) {
      if (!_done.contains(remaining.id) && !_skipped.contains(remaining.id)) {
        _skipped.add(remaining.id);
      }
    }
    _tutorialDone = true;
    _notify();
    await _persist();
    unawaited(_push({'onboarding': _progress()}));
  }

  /// Reaches the last step (the closing card) and marks the tour done.
  Future<void> finish() async {
    if (!_enabled) return;
    for (final remaining in coachSteps.skip(_stepIndex)) {
      if (!_done.contains(remaining.id)) _done.add(remaining.id);
    }
    _stepIndex = stepCount - 1;
    _tutorialDone = true;
    _notify();
    await _persist();
    unawaited(_push({'onboarding': _progress()}));
  }

  /// Settings entry: watch the tour again from step one, keeping setup done.
  Future<void> replay() async {
    if (!_enabled) return;
    _setupDone = true;
    _tutorialDone = false;
    _stepIndex = 0;
    _done.clear();
    _skipped.clear();
    _notify();
    await _persist();
    unawaited(_push({'onboarding': _progress()}));
  }

  /// Pushes the current progress; safe to call when offline (silently ignored).
  Future<void> pushProgress() => _push({'onboarding': _progress()});

  Json _progress() => {
    'version': version,
    'step': _stepIndex,
    'done': _done,
    'skipped': _skipped,
    'assistant_style': _assistantStyle,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  };

  void _clampStep() => _stepIndex = _stepIndex.clamp(0, coachSteps.length - 1);

  Future<void> _persist() async {
    try {
      await planner.storage.write(
        storageKey,
        jsonEncode({
          'version': version,
          'setup_done': _setupDone,
          'tutorial_done': _tutorialDone,
          'step': _stepIndex,
          'done': _done,
          'skipped': _skipped,
          'assistant_style': _assistantStyle,
        }),
      );
    } catch (_) {
      // Losing the cache only costs a resume point, never the local planner.
    }
  }

  Future<void> _submitSettings(Json fields) async {
    try {
      await planner.submit('settings.update', fields);
    } catch (_) {
      // The operation queue keeps retrying; setup must never be blocked.
    }
  }

  Future<void> _pushAssistantStyle(bool confirmFirst) async {
    try {
      await planner.saveAssistantConfig({'confirm_first': confirmFirst});
    } catch (_) {
      // Older/offline computers keep their own default; nothing to undo.
    }
  }

  /// `PATCH /api/v1/me`. The controller only speaks GET/POST, so the request is
  /// built here; a failure is deliberately silent — the local record stays and
  /// is pushed again on the next step, launch or reconnection.
  Future<void> _push(Json patch) async {
    if (!planner.configured || _pushing) return;
    _pushing = true;
    try {
      final request =
          http.Request('PATCH', Uri.parse('${planner.serverUrl}/api/v1/me'))
            ..headers['Content-Type'] = 'application/json'
            ..headers['Authorization'] = 'Bearer ${planner.auth.token}'
            ..body = jsonEncode(patch);
      final response = await planner.transport.send(request).timeout(_timeout);
      final bytes = await response.stream.toBytes();
      if (response.statusCode >= 500) {
        _pushPending = true;
        return;
      }
      if (response.statusCode >= 400) return;
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map) return;
      final user = value['user'];
      if (user is! Map) return;
      _pushPending = false;
      planner.auth.user = user.cast<String, dynamic>();
      await _persistSession();
    } catch (_) {
      // Offline, or a server without PATCH /me: nothing to do.
      _pushPending = true;
    } finally {
      _pushing = false;
    }
  }

  /// Best-effort catch-up: once the planner reaches the computer again, the
  /// latest progress (finished/skipped steps included) is pushed once.
  void _onPlannerChanged() {
    if (_disposed || !_pushPending || _pushing) return;
    if (!planner.connected || !planner.configured) return;
    _pushPending = false;
    unawaited(_push({'onboarding': _progress()}));
  }

  /// Keep the cached account record in step with the server response so the
  /// display name survives an offline restart.
  Future<void> _persistSession() async {
    try {
      await planner.storage.write(
        'auth_session',
        jsonEncode({
          'base_url': planner.auth.baseUrl,
          if (planner.auth.user != null) 'user': planner.auth.user,
          if (planner.auth.device != null) 'device': planner.auth.device,
        }),
      );
    } catch (_) {}
  }

  static int _asInt(Object? value) => switch (value) {
    num number => number.toInt(),
    String text => int.tryParse(text) ?? 0,
    _ => 0,
  };

  static List<String> _asStrings(Object? value) =>
      value is List ? [for (final item in value) '$item'] : const <String>[];

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    planner.removeListener(_onPlannerChanged);
    super.dispose();
  }
}
