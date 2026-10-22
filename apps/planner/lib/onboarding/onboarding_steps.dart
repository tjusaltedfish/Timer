/// The v2 first-run coach tour (plan §10.1).
///
/// The step ids double as the tokens stored in `users.onboarding.done` /
/// `.skipped`, so the tour can be resumed on another device without a second
/// bookkeeping scheme. [CoachKeys] are the ids [CoachTarget] widgets register
/// with, which keeps the overlay independent from where the real UI lives.
library;

import 'package:flutter/foundation.dart';

/// Stable ids for the ten tour steps.
abstract final class StepId {
  static const today = 'today';
  static const add = 'add';
  static const session = 'session';
  static const feedback = 'feedback';
  static const week = 'week';
  static const materials = 'materials';
  static const assistant = 'assistant';
  static const account = 'account';
  static const server = 'server';
  static const finish = 'finish';
}

/// Widgets the tour points at. Kept in one place so `home.dart` and
/// `settings_page.dart` agree on the names.
abstract final class CoachKeys {
  static const navToday = 'nav.today';
  static const navWeek = 'nav.week';
  static const navReview = 'nav.review';
  static const navAssistant = 'nav.assistant';
  static const addTask = 'action.create';
  static const todayArea = 'today.area';
  static const settingsEntry = 'settings.entry';
  static const accountPanel = 'settings.account';
}

/// One coach mark: a rectangle in the real UI, a title and one sentence.
@immutable
class CoachStep {
  const CoachStep({
    required this.id,
    required this.title,
    required this.body,
    this.target,
    this.page,
  });

  final String id;
  final String title;
  final String body;

  /// [CoachKeys] id of the widget to highlight; null means a centered card
  /// over the whole dimmed app (the closing step).
  final String? target;

  /// Planner page the tour switches to before the step is measured.
  final int? page;
}

/// Ten steps, in order: today / add / start-pause-finish / waiting feedback /
/// week / knowledge base (回顾) / assistant / account / server / closing.
const List<CoachStep> coachSteps = [
  CoachStep(
    id: StepId.today,
    title: '今天从这里开始',
    body: '「今日」是每天的主场：安排、专注和结果都落在这一页。',
    target: CoachKeys.navToday,
    page: 0,
  ),
  CoachStep(
    id: StepId.add,
    title: '先安排一件事',
    body: '点这个按钮写下想做的事，顺手给它留一段时间。',
    target: CoachKeys.addTask,
    page: 0,
  ),
  CoachStep(
    id: StepId.session,
    title: '开始 · 暂停 · 结束',
    body: '到点开始专注，离开就暂停，做完点结束——时间是量出来的，不是估出来的。',
    target: CoachKeys.todayArea,
    page: 0,
  ),
  CoachStep(
    id: StepId.feedback,
    title: '说说结果',
    body: '结束时会请你用一句话记下结果；没来得及写的会留在「待反馈」，稍后补上也算。',
    target: CoachKeys.todayArea,
    page: 0,
  ),
  CoachStep(
    id: StepId.week,
    title: '一周的走法',
    body: '「一周」里能看见整周的疏密，需要时可以拉长、挪动或留白。',
    target: CoachKeys.navWeek,
    page: 1,
  ),
  CoachStep(
    id: StepId.materials,
    title: '把资料交给自己',
    body: '「回顾」里可以上传材料、写日终回顾，让每天的记录有处可去。',
    target: CoachKeys.navReview,
    page: 3,
  ),
  CoachStep(
    id: StepId.assistant,
    title: '叫得应的助手',
    body: '「助手」在服务器上读你的日程，可以帮你排期、改计划，也会说明它做了什么。',
    target: CoachKeys.navAssistant,
    page: 4,
  ),
  CoachStep(
    id: StepId.account,
    title: '账号与设置',
    body: '「我的」里有账号、提醒和每天的起止时间；手机也能配置助手和绑定公众号。',
    target: CoachKeys.settingsEntry,
    page: 0,
  ),
  CoachStep(
    id: StepId.server,
    title: '换一台服务器',
    body: '在设置里点「修改服务器地址」就能换服务器；断网照常记录，联网后自动接上。',
    target: CoachKeys.accountPanel,
    page: 5,
  ),
  CoachStep(
    id: StepId.finish,
    title: '都准备好了',
    body: '随时可以在设置里重新看这段引导。今天就先落一笔有结果的事吧。',
    page: 0,
  ),
];
