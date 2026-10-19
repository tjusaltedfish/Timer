'use strict';

// Disposable, in-memory interaction sketch. No API, notifications or disk persistence.
const $ = (selector) => document.querySelector(selector);
const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
const projects = { code: '毕业 · 实验代码', learn: '秋招 · 转行自学', fab: 'Fab · 工艺实验' };
const tasks = {
  code: { title: '跑通参数扫描脚本', project: 'code', goal: '保存一组可复现输出，记录运行参数与异常。', state: 'ready', remaining: 60 },
  learn: { title: '算法练习与思路复述', project: 'learn', goal: '完成两道题，并能解释其中一道的解法。', state: 'ready', remaining: 45 },
  fab: { title: 'Fab 工艺参数调整', project: 'fab', goal: '记录本轮参数、样品观察与下一轮调整依据。', state: 'ready', remaining: 90 },
  check: { title: '检查参数扫描结果', project: 'code', goal: '确认运行结果是否可用，记录下一步分析。', state: 'waiting', remaining: 15 },
  study: { title: '项目知识点整理', project: 'learn', goal: '整理一个知识点和一个可验证的小练习。', state: 'ready', remaining: 60 },
  analysis: { title: '实验结果分析', project: 'code', goal: '对比两组输出，写下差异与后续问题。', state: 'ready', remaining: 60 },
  fabprep: { title: '整理下一轮工艺方案', project: 'fab', goal: '检查材料和设备需求，形成预约前的准备清单。', state: 'ready', remaining: 60 },
};
let blocks = [
  { id: 'b1', taskId: 'code', day: 0, start: 600, end: 660 },
  { id: 'b2', taskId: 'learn', day: 0, start: 675, end: 720 },
  { id: 'b3', taskId: 'fab', day: 0, start: 840, end: 930, fixed: true },
  { id: 'b4', taskId: 'check', day: 0, start: 990, end: 1005 },
  { id: 'b5', taskId: 'study', day: 1, start: 570, end: 630 },
  { id: 'b6', taskId: 'analysis', day: 2, start: 600, end: 660 },
  { id: 'b7', taskId: 'fabprep', day: 3, start: 840, end: 900 },
];
let day = 0;
let selectedId = 'b1';
let feedbackId = null;
let detailId = null;
let proposal = null;
let planRevision = 1;
let serial = 10;
let lastDialogTrigger = null;
const sessions = {};
const feedbacks = [];
const reviewDrafts = {};
const savedReviews = {};
const time = (minutes) => `${String(Math.floor(minutes / 60)).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`;
const fromTime = (value) => { const [h, m] = value.split(':').map(Number); return h * 60 + m; };
const escapeHtml = (value) => String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const dayBlocks = () => blocks.filter((block) => block.day === day).sort((a, b) => a.start - b.start);
const selected = () => blocks.find((block) => block.id === selectedId);
const statusText = (block) => {
  const session = sessions[block.id];
  if (session === 'running') return '进行中';
  if (session === 'paused') return '已暂停';
  if (session === 'awaiting_feedback') return '待反馈';
  if (session === 'closed') return '本段已记录';
  return tasks[block.taskId].state === 'done' ? '已完成' : block.fixed ? '⌑ 固定预约' : tasks[block.taskId].state === 'waiting' ? '等待检查' : '待开始';
};

function toast(message) {
  $('#toast').textContent = message;
  $('#toast').hidden = false;
  clearTimeout(toast.timeout);
  toast.timeout = setTimeout(() => { $('#toast').hidden = true; }, 4200);
}

function showPage(name) {
  for (const page of document.querySelectorAll('.page')) { page.hidden = page.id !== `page-${name}`; page.classList.toggle('active', !page.hidden); }
  for (const button of document.querySelectorAll('[data-page]')) {
    button.classList.toggle('active', button.dataset.page === name);
    if (button.dataset.page === name) button.setAttribute('aria-current', 'page'); else button.removeAttribute('aria-current');
  }
  $('#breadcrumb').textContent = `工作台 / ${{ today: '今天', week: '一周课表', assistant: '助手', review: '日终回顾' }[name]}`;
  if (name === 'review') renderReview();
}

function showDialog(id) {
  lastDialogTrigger = document.activeElement;
  $(id).showModal();
}

function renderDates() {
  const englishDays = ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY'];
  $('#page-today .page-heading .eyebrow').textContent = `${englishDays[day]}, OCTOBER ${19 + day} · 示例周`;
  $('.paper-date > span').textContent = String(19 + day);
  $('.paper-date > div').textContent = `OCTOBER 2026 · ${weekdays[day]} · 演示日报`;
  for (const target of ['#day-strip', '#week-day-strip']) {
    $(target).innerHTML = weekdays.map((label, index) => `<button class="day-button ${index === day ? 'active' : ''}" data-day="${index}" aria-pressed="${index === day}" aria-label="10月${19 + index}日 ${label}"><span>${label}</span><b>${19 + index}</b></button>`).join('');
  }
}

function selectDay(value) {
  day = value;
  selectedId = dayBlocks()[0]?.id ?? null;
  render();
}

function renderCard() {
  const block = selected();
  const items = dayBlocks();
  const index = items.findIndex((item) => item.id === selectedId);
  $('#previous-card').disabled = index <= 0;
  $('#next-card').disabled = index < 0 || index >= items.length - 1;
  if (!block) {
    $('#carousel').innerHTML = '<article class="focus-card"><div class="eyebrow">ROOM FOR WHAT MATTERS</div><h3>这一天，还留着空间。</h3><p class="card-goal">先安排一件有明确结果的事，也给休息留个位置。</p><div class="card-actions"><button class="button dark" data-action="new">＋ 安排一件事</button></div></article>';
    return;
  }
  const task = tasks[block.taskId];
  const session = sessions[block.id];
  let actions;
  if (session === 'running' || session === 'paused') {
    actions = `<button class="button dark" data-action="pause">${session === 'running' ? 'Ⅱ 暂停这一段' : '▶ 继续这一段'}</button><button class="text-button" data-action="end">结束并反馈 ↗</button>`;
  } else if (session === 'awaiting_feedback') {
    actions = '<button class="button dark" data-action="feedback">补充结果反馈 ↗</button>';
  } else if (session === 'closed' || task.state === 'done') {
    actions = '<button class="button" data-action="detail">查看这一段记录</button>';
  } else {
    actions = '<button class="button dark" data-action="start">▶ 开始这一段</button><button class="text-button" data-action="feedback">记录进展 ↗</button>';
  }
  const next = items[index + 1];
  $('#carousel').innerHTML = `<article class="focus-card"><div class="card-meta"><span class="tag ${task.project}">${projects[task.project]}</span><span class="card-time">${time(block.start)} — ${time(block.end)}</span></div><h3>${escapeHtml(task.title)}</h3><p class="card-goal"><span>这次的结果</span>${escapeHtml(task.goal)}</p><div class="card-actions">${actions}<span class="card-status">${statusText(block)}</span></div></article>${next ? `<button class="peek-card" data-block="${next.id}" style="width:calc(100% - 30px)"><span>下一项 · ${escapeHtml(tasks[next.taskId].title)}</span><span>${time(next.start)} →</span></button>` : '<div class="peek-card"><span>这一项之后，给自己一点留白。</span><span>◌</span></div>'}`;
}

function renderTimeline() {
  const items = dayBlocks();
  $('#day-count').textContent = `${weekdays[day]} · ${items.length} 个时间块`;
  $('#planned-total').textContent = (items.reduce((sum, item) => sum + item.end - item.start, 0) / 60).toFixed(1);
  $('#timeline').innerHTML = items.length ? items.map((block) => {
    const task = tasks[block.taskId];
    return `<button class="timeline-row" data-detail="${block.id}"><span class="timeline-time">${time(block.start)}<small>${time(block.end)}</small></span><span class="timeline-body"><strong><i class="dot ${task.project}"></i>${escapeHtml(task.title)}</strong><p>${escapeHtml(task.goal)}</p></span><span class="row-status ${block.id === selectedId ? 'current' : ''}">${statusText(block)}</span></button>`;
  }).join('') : '<p style="padding:22px 0">还没有安排。你可以从一个具体结果开始。</p>';
}

function renderWeek() {
  const hours = Array.from({ length: 9 }, (_, i) => `<div class="hour">${String(9 + i).padStart(2, '0')}:00</div>`).join('');
  $('#week-grid').innerHTML = `<div class="week-hours"><div class="week-heading"></div><div style="padding-top:0">${hours}</div></div>` + weekdays.map((label, d) => `<div class="week-column ${d === day ? 'selected' : ''}"><div class="week-heading">${label}<b>${19 + d}</b></div><div class="week-body"><div class="week-protected">用餐与休息</div>${blocks.filter((b) => b.day === d).map((block) => {
    const task = tasks[block.taskId];
    return `<button class="week-block ${task.project} ${block.end - block.start < 30 ? 'compact' : ''}" data-detail="${block.id}" style="top:${(block.start - 540) * 68 / 60}px;height:${(block.end - block.start) * 68 / 60}px" aria-label="${label} ${time(block.start)}至${time(block.end)} ${escapeHtml(task.title)}${block.fixed ? ' 固定预约' : ''}"><small>${time(block.start)}${block.fixed ? ' ⌑' : ''}</small><strong>${escapeHtml(task.title)}</strong></button>`;
  }).join('')}</div></div>`).join('');
}

function renderReview() {
  const counts = { done: 0, partial: 0, waiting: 0, interrupted: 0, not_started: 0 };
  feedbacks.filter((f) => f.day === day).forEach((feedback) => { counts[feedback.choice] += 1; });
  $('#review-facts').textContent = feedbacks.length ? `快捷记录：${counts.done} 次完成确认 · ${counts.partial} 次部分完成 · ${counts.waiting} 次等待结果。未反馈的事项仍待确认。` : '还没有提交结果反馈。未反馈的事项保持未确认。';
  $('#review-input').value = reviewDrafts[day] ?? '';
  renderSavedReview(savedReviews[day]);
}

function renderSavedReview(text) {
  $('#review-output').replaceChildren();
  $('#review-output').hidden = !text;
  if (!text) return;
  const title = document.createElement('strong'); title.textContent = '你的回顾 · 已保留在本页';
  const original = document.createElement('div'); original.textContent = text;
  const note = document.createElement('p'); note.textContent = '这里保留的是原文。模型分析与电脑归档尚未接入；刷新会恢复演示数据。';
  $('#review-output').append(title, original, note);
}

function render() { renderDates(); renderCard(); renderTimeline(); renderWeek(); renderReview(); }

function openDetail(id) {
  detailId = id;
  const block = blocks.find((item) => item.id === id);
  const task = tasks[block.taskId];
  $('#task-title').textContent = task.title;
  const feedback = feedbacks.findLast((item) => item.blockId === id);
  $('#task-detail').innerHTML = `<p><span class="tag ${task.project}">${projects[task.project]}</span></p><p>${weekdays[block.day]} · ${time(block.start)}—${time(block.end)}${block.fixed ? ' · ⌑ 固定预约' : ''}</p><p><strong>完成标准</strong><br>${escapeHtml(task.goal)}</p><p>本段状态：${statusText(block)}</p>${feedback ? `<p><strong>本次反馈</strong><br>${escapeHtml(feedback.text || '已保存快捷选择')}<br>状态：${escapeHtml(feedback.label)}</p>` : ''}`;
  showDialog('#task-dialog');
}

function openFeedback(id) {
  feedbackId = id;
  $('#feedback-form').reset();
  $('#remaining-field').hidden = true;
  $('#check-field').hidden = true;
  $('#check-time').required = false;
  $('#feedback-task').textContent = tasks[blocks.find((block) => block.id === id).taskId].title;
  showDialog('#feedback-dialog');
}

// Sample-only greedy proposal: respects fixed appointments, lunch and 15-minute chunks.
function prepareProposal(block, remaining) {
  const future = blocks.filter((b) => b.day === block.day && b.start >= block.end && b.id !== block.id && !b.fixed);
  const occupied = blocks.filter((b) => b.day === block.day && !future.some((f) => f.id === b.id));
  occupied.push({ start: 720, end: 810 });
  const result = [];
  const unscheduled = [];
  const items = [{ taskId: block.taskId, start: block.end, duration: remaining, label: '补充投入' }, ...future.sort((a, b) => a.start - b.start).map((b) => ({ taskId: b.taskId, start: b.start, duration: b.end - b.start, label: '后续安排' }))];
  let cursor = block.end;
  for (const item of items) {
    let left = item.duration;
    let position = Math.max(cursor, item.start);
    const intervals = occupied.concat(result).sort((a, b) => a.start - b.start);
    for (let guard = 0; left > 0 && position < 1080 && guard < 100; guard += 1) {
      const overlap = intervals.find((b) => b.start <= position && b.end > position);
      if (overlap) { position = overlap.end; continue; }
      const next = intervals.find((b) => b.start > position);
      const capacity = Math.min(next?.start ?? 1080, 1080) - position;
      const amount = Math.min(left, capacity);
      if (amount < 15) { position = next?.end ?? 1080; continue; }
      result.push({ id: `p${++serial}`, taskId: item.taskId, day: block.day, start: position, end: position + amount, label: item.label });
      left -= amount;
      position += amount;
    }
    cursor = position;
    if (left) unscheduled.push({ title: tasks[item.taskId].title, minutes: left });
  }
  proposal = { revision: planRevision, day: block.day, removeIds: future.map((b) => b.id), blocks: result, unscheduled };
  $('#plan-changes').innerHTML = result.map((b) => {
    const original = future.find((f) => f.taskId === b.taskId);
    const before = original ? `原安排 ${time(original.start)}—${time(original.end)}` : '新增剩余工作投入';
    return `<div class="plan-change"><h3>${escapeHtml(tasks[b.taskId].title)}</h3><p>${before}\n→ ${time(b.start)}—${time(b.end)} · ${b.label}</p></div>`;
  }).join('') + unscheduled.map((item) => `<div class="plan-change"><h3>尚未安排</h3><p>${escapeHtml(item.title)} · ${item.minutes} 分钟，需要另选时间。</p></div>`).join('');
  showDialog('#plan-dialog');
}

document.addEventListener('click', (event) => {
  const page = event.target.closest('[data-page]');
  if (page) showPage(page.dataset.page);
  const date = event.target.closest('[data-day]');
  if (date) selectDay(Number(date.dataset.day));
  const card = event.target.closest('[data-block]');
  if (card) { selectedId = card.dataset.block; render(); }
  const detail = event.target.closest('[data-detail]');
  if (detail) openDetail(detail.dataset.detail);
  const close = event.target.closest('[data-close]');
  if (close) close.closest('dialog').close();
  const action = event.target.closest('[data-action]')?.dataset.action;
  if (action === 'new') { $('#new-form').reset(); $('#new-day').value = String(day); $('#new-error').textContent = ''; showDialog('#new-dialog'); }
  if (action === 'detail') openDetail(selectedId);
  if (action === 'feedback') openFeedback(selectedId);
  if (action === 'start') {
    const active = Object.keys(sessions).find((id) => ['running', 'paused'].includes(sessions[id]));
    if (active) return toast('已有一段进行中的安排，请先结束或继续它。');
    sessions[selectedId] = 'running';
    tasks[selected().taskId].state = 'in_progress';
    render();
    toast('已进入本页演示专注；系统计时与通知将在正式版本接入。');
  }
  if (action === 'pause') { sessions[selectedId] = sessions[selectedId] === 'running' ? 'paused' : 'running'; render(); }
  if (action === 'end') { sessions[selectedId] = 'awaiting_feedback'; render(); openFeedback(selectedId); }
});

for (const dialog of document.querySelectorAll('dialog')) dialog.addEventListener('close', () => { if (lastDialogTrigger?.isConnected) lastDialogTrigger.focus(); });
$('#device-toggle').addEventListener('click', () => {
  const mobile = $('#app-shell').classList.toggle('mobile-preview');
  $('#device-toggle').setAttribute('aria-pressed', String(mobile));
  $('#device-toggle').textContent = mobile ? '返回电脑预览 ↗' : '手机预览 ↗';
});
for (const [selector, direction] of [['#previous-card', -1], ['#next-card', 1]]) $(selector).addEventListener('click', () => {
  const items = dayBlocks();
  const index = items.findIndex((item) => item.id === selectedId);
  if (items[index + direction]) { selectedId = items[index + direction].id; render(); }
});

$('#feedback-form').addEventListener('change', () => {
  const choice = new FormData($('#feedback-form')).get('feedback');
  $('#remaining-field').hidden = choice !== 'partial';
  $('#check-field').hidden = choice !== 'waiting';
  $('#check-time').required = choice === 'waiting';
});
$('#feedback-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const choice = new FormData(event.target).get('feedback');
  const block = blocks.find((b) => b.id === feedbackId);
  const task = tasks[block.taskId];
  const labels = { done: '完成确认', partial: '部分完成', waiting: '等待结果', interrupted: '被打断', not_started: '尚未开始' };
  task.state = choice === 'done' ? 'done' : choice === 'waiting' ? 'waiting' : 'ready';
  if (choice === 'partial') task.remaining = Number($('#remaining').value);
  if (choice === 'done') task.remaining = 0;
  if (choice !== 'not_started') sessions[block.id] = 'closed';
  else if (sessions[block.id]) { sessions[block.id] = 'closed'; }
  feedbacks.push({ blockId: block.id, day: block.day, choice, label: labels[choice], text: $('#outcome').value.trim(), checkAt: choice === 'waiting' ? $('#check-time').value : null });
  $('#feedback-dialog').close();
  render();
  if (choice === 'partial') prepareProposal(block, task.remaining);
  else toast(choice === 'waiting' ? `已记录等待，示例检查点 ${$('#check-time').value}；未注册系统提醒。` : '已保留这次反馈，刷新前可以在详情查看。');
});
$('#apply-plan').addEventListener('click', () => {
  if (!proposal || proposal.revision !== planRevision) return toast('日程已变化，请重新生成预览。');
  blocks = blocks.filter((b) => !proposal.removeIds.includes(b.id)).concat(proposal.blocks);
  planRevision += 1;
  day = proposal.day;
  selectedId = proposal.blocks[0]?.id ?? selectedId;
  $('#plan-dialog').close();
  proposal = null;
  render();
  toast('演示课表已更新，固定预约和保护时段已保留。');
});
$('#show-on-today').addEventListener('click', () => {
  const block = blocks.find((b) => b.id === detailId);
  day = block.day;
  selectedId = block.id;
  $('#task-dialog').close(); render(); showPage('today');
});

$('#new-day').innerHTML = weekdays.map((label, i) => `<option value="${i}">10/${19 + i} ${label}</option>`).join('');
$('#new-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const d = Number($('#new-day').value);
  const start = fromTime($('#new-start').value);
  const end = start + Number($('#new-duration').value);
  const title = $('#new-name').value.trim();
  const goal = $('#new-goal').value.trim();
  if (!title || !goal) { $('#new-error').textContent = '请填写任务名称和完成标准。'; return; }
  const overlap = blocks.find((b) => b.day === d && b.start < end && b.end > start);
  if (start < 540 || end > 1080 || (start < 810 && end > 720)) { $('#new-error').textContent = '示例可安排范围为 09:00—18:00，12:00—13:30 留作保护时间。'; return; }
  if (overlap) { $('#new-error').textContent = `与「${tasks[overlap.taskId].title}」冲突，请换一个时间。`; return; }
  const id = `new${++serial}`;
  tasks[id] = { title, goal, project: $('#new-project').value, state: 'ready', remaining: end - start };
  blocks.push({ id, taskId: id, day: d, start, end });
  planRevision += 1;
  day = d; selectedId = id;
  $('#new-dialog').close(); render(); showPage('today'); toast('任务已加入内存中的演示课表。');
});

function addMessage(text, user = false) {
  const node = document.createElement('div'); node.className = `message ${user ? 'user-message' : 'assistant-message'}`; node.textContent = text; $('#messages').append(node); node.scrollIntoView({ block: 'nearest' });
}
$('#example-message').addEventListener('click', () => {
  $('#chat-input').value = '实验代码还需要 30 分钟';
  $('#chat-form').requestSubmit();
});
$('#chat-form').addEventListener('submit', (event) => {
  event.preventDefault(); const text = $('#chat-input').value.trim(); if (!text) return;
  addMessage(text, true); $('#chat-input').value = '';
  if (text === '实验代码还需要 30 分钟') {
    addMessage('示例提案：为代码补充 30 分钟投入，调整后续弹性安排，并保留固定 Fab 预约与用餐时间。请在预览中确认。');
    prepareProposal(blocks.find((b) => b.id === 'b1'), 30);
  } else addMessage('已展示你的消息。本草图尚未连接模型；正式版本会解析任务、必要时补问，并生成可确认的建议。你可以点击预设示例体验重排。');
});
$('#review-input').addEventListener('input', () => { reviewDrafts[day] = $('#review-input').value; });
$('#save-review').addEventListener('click', () => {
  const text = $('#review-input').value.trim();
  if (!text) return toast('先写下今天的两三句话。');
  savedReviews[day] = text;
  renderSavedReview(text);
  toast('回顾原文已保留在当前页面。');
});

// Horizontal swipe on date selection supplements explicit accessible date buttons.
for (const strip of document.querySelectorAll('.day-strip')) {
  let touchX = null;
  strip.addEventListener('touchstart', (event) => { touchX = event.changedTouches[0].clientX; }, { passive: true });
  strip.addEventListener('touchend', (event) => {
    if (touchX === null) return;
    const dx = event.changedTouches[0].clientX - touchX;
    if (Math.abs(dx) > 45) selectDay(Math.max(0, Math.min(6, day + (dx < 0 ? 1 : -1))));
    touchX = null;
  }, { passive: true });
}
render();
