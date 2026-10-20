"""Deterministic notification templates backed by the existing WeChat outbox."""
import json
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from .domain import parse, stamp
from .store import digest, encode


class Proactive:
    def __init__(self, store, channel, clock):
        self.store, self.channel, self.clock = store, channel, clock
        with store.connect() as conn:
            conn.executescript('''
                CREATE TABLE IF NOT EXISTS notification_cursor(id INTEGER PRIMARY KEY, revision INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS notification_refs(key TEXT PRIMARY KEY, body TEXT NOT NULL);
            ''')
            # An upgrade starts at the present; it must not announce all historical edits.
            conn.execute('INSERT OR IGNORE INTO notification_cursor SELECT 1, COALESCE(MAX(revision),0) FROM events')

    def tick(self):
        now = self.clock()
        conf = self.channel.settings.load()
        bound = conf['bound_openid']
        with self.store.connect() as conn:
            conn.execute('BEGIN IMMEDIATE')
            state = self.store.state(conn)
            cursor = conn.execute('SELECT revision FROM notification_cursor WHERE id=1').fetchone()[0]
            events = conn.execute('SELECT * FROM events WHERE revision>? ORDER BY revision LIMIT 500', (cursor,)).fetchall()
            tasks = {t['id']: t for t in state['tasks']}
            blocks = {b['id']: b for b in state['blocks']}
            sessions = {s['id']: s for s in state['sessions']}
            zone = ZoneInfo(state['settings']['timezone'])
            local = now.astimezone(zone)

            def queue(kind, item_id, version, text, ref, expiry):
                key = f'notify:{digest(bound)[:12]}:{kind}:{item_id}:{version}'
                conn.execute('INSERT OR IGNORE INTO notification_refs VALUES(?,?)', (key, encode(ref)))
                self.channel._enqueue(conn, bound, text, now, key=key, expires_at=expiry)

            def live_task(task_id):
                return task_id in tasks and tasks[task_id]['state'] not in ('done', 'cancelled')

            if bound and conf.get('proactive_enabled', True):
                created = set()
                for event in events:
                    # The WeChat confirmation already sends its own receipt.
                    if event['device_id'] == 'wechat' or now - parse(event['recorded_at']) > timedelta(minutes=10):
                        continue
                    payload = json.loads(event['payload'])
                    if event['kind'] in ('task.create', 'session.start') and not payload.get('id'):
                        # IDs may be assigned by the domain rather than submitted by a client.
                        accepted = conn.execute("SELECT response FROM operations WHERE json_extract(response, '$.revision')=?",
                                                (event['revision'],)).fetchone()
                        if accepted:
                            payload['id'] = json.loads(accepted['response'])['entity']['id']
                    if event['kind'] in ('task.create', 'block.create'):
                        task_id = payload.get('id') if event['kind'] == 'task.create' else payload.get('task_id')
                        if not live_task(task_id) or task_id in created:
                            continue
                        created.add(task_id)
                        task = tasks[task_id]
                        planned = next((b for b in state['blocks'] if b.get('task_id') == task_id
                                        and b['status'] == 'scheduled' and parse(b['end_at']) > now), None)
                        when = (f"\n安排：{parse(planned['start_at']).astimezone(zone):%m/%d %H:%M}—"
                                f"{parse(planned['end_at']).astimezone(zone):%H:%M}") if planned else '\n尚未安排时段。'
                        queue('created', task_id, event['revision'], f"待办已添加\n{task['title']}\n目标：{task['outcome_criteria'][:70]}{when}",
                              {'task_id': task_id, 'title': task['title'], 'goal': task['outcome_criteria'],
                               'plan_id': planned['id'] if planned else None, 'plan_version': planned['version'] if planned else None},
                              now + timedelta(minutes=10))
                    elif event['kind'] == 'session.start':
                        s = sessions.get(payload.get('id'))
                        if not s or not live_task(s['task_id']) or s['state'] != 'running':
                            continue
                        queue('focus', s['id'], 1, f"已进入专注\n{tasks[s['task_id']]['title']}\n预计 {parse(s['expected_end_at']).astimezone(zone):%H:%M} 收尾，到点会问你结果。",
                              {'session_id': s['id'], 'running': True, 'expected_end': s['expected_end_at'],
                               'title': tasks[s['task_id']]['title']}, now + timedelta(minutes=5))
                    elif event['kind'] == 'review.analysis':
                        analysis = next((a for a in state.get('analyses', []) if a['id'] == payload.get('id')), None)
                        if analysis:
                            queue('analysis', analysis['id'], 1, f"{analysis['date']} · 复盘已归档\n{analysis['text'][:120]}\n完整材料出处见 Timer 回顾页。",
                                  {'date': analysis['date']}, now + timedelta(hours=12))
                active_blocks = {s['block_id'] for s in state['sessions']}
                for b in state['blocks']:
                    if b['status'] != 'scheduled' or b['kind'] == 'protected' or not live_task(b.get('task_id')) or b['id'] in active_blocks:
                        continue
                    if parse(b['start_at']) <= now < min(parse(b['end_at']), parse(b['start_at']) + timedelta(minutes=15)):
                        queue('start', b['id'], b['version'], f"该开始了\n{b['title']}\n打开 Timer 开始这一段；结束后记录结果。",
                              {'block_id': b['id'], 'block_version': b['version'], 'not_started': True}, parse(b['end_at']))
                    end = parse(b['end_at'])
                    if end <= now < end + timedelta(minutes=15):
                        queue('missed', b['id'], b['version'], f"这一段的时间已过\n{b['title']}\n尚未记录开始。实际做了、没有开始，还是需要重新安排？可以直接说明，或打开 Timer 补记结果。",
                              {'block_id': b['id'], 'block_version': b['version'], 'not_started': True}, end + timedelta(hours=1))
                open_sessions = [s for s in state['sessions']
                                 if live_task(s['task_id']) and s['state'] in ('running', 'awaiting_feedback')]
                for s in open_sessions:
                    end = parse(s['expected_end_at'] if s['state'] == 'running' else s['actual_end_at'])
                    if end <= now < end + timedelta(hours=24):
                        # The code is only needed to tell several open sessions apart.
                        code = f" {s['id'][:6].upper()}" if len(open_sessions) > 1 else ''
                        queue('result', s['id'], stamp(end),
                              f"这一段到时间了\n{tasks[s['task_id']]['title']}\n做完了吗？\n"
                              f"· 回复「完成了{code}」结束这一段\n· 回复「再给我15分钟{code}」接着做\n"
                              "· 要推迟或改到别的时间，直接说，比如「剩下的推到晚上八点」\n"
                              "部分完成、被打断或在等结果，也可以直接告诉我。",
                              {'session_id': s['id'], 'end': stamp(end)}, end + timedelta(hours=24))
                for check in state['waiting_checks']:
                    if check.get('resolved_at') or tasks.get(check['task_id'], {}).get('state') != 'waiting':
                        continue
                    due = parse(check['check_at'])
                    if due <= now < due + timedelta(hours=24):
                        queue('waiting', check['id'], check.get('version', 1), f"看看等待的结果\n{tasks[check['task_id']]['title']}\n结果回来了吗？没回来可以在 Timer 改约检查时间。",
                              {'check_id': check['id'], 'check_version': check.get('version', 1)}, due + timedelta(hours=24))
                hour, minute = map(int, state['settings']['daily_review_time'].split(':'))
                if (local.hour, local.minute) >= (hour, minute):
                    day = local.date().isoformat()
                    reviews = [r for r in state['reviews'] if r['date'] == day]
                    today_sessions = [s for s in state['sessions'] if parse(s['actual_start_at']).astimezone(zone).date() == local.date()]
                    unanswered = sum(s['state'] == 'awaiting_feedback' for s in today_sessions)
                    text = f"{local:%m月%d日} · 今日收尾\n执行 {len(today_sessions)} 段，待反馈 {unanswered} 段。"
                    text += ('\n你的记录：' + reviews[-1]['text'][:80]) if reviews else '\n用两三句话说说今天的产出、卡点和下一步，回复「今日总结：……」即可归档。'
                    queue('daily', day, 1, text, {'kind': 'daily', 'date': day,
                          'review_id': reviews[-1]['id'] if reviews else None,
                          'counts': [len(today_sessions), unanswered]}, now + timedelta(hours=3))
            if events:
                conn.execute('UPDATE notification_cursor SET revision=? WHERE id=1', (events[-1]['revision'],))

    def valid(self, key):
        if not key or not key.startswith('notify:'):
            return True
        conf = self.channel.settings.load()
        if not conf['bound_openid'] or not conf.get('proactive_enabled', True):
            return False
        if not key.startswith(f"notify:{digest(conf['bound_openid'])[:12]}:"):
            return False
        base = key.rsplit('#', 1)[0]
        with self.store.connect() as conn:
            row = conn.execute('SELECT body FROM notification_refs WHERE key=?', (base,)).fetchone()
            if not row:
                return False
            ref, state = json.loads(row['body']), self.store.state(conn)
        if ref.get('task_id'):
            task = next((t for t in state['tasks'] if t['id'] == ref['task_id']), None)
            if not task or task['state'] in ('done', 'cancelled'):
                return False
            if task['title'] != ref.get('title', task['title']) or task['outcome_criteria'] != ref.get('goal', task['outcome_criteria']):
                return False
            if 'plan_id' in ref:
                if ref['plan_id'] is None:
                    return not any(b.get('task_id') == task['id'] and b['status'] == 'scheduled'
                                   and parse(b['end_at']) > self.clock() for b in state['blocks'])
                return any(b['id'] == ref['plan_id'] and b['status'] == 'scheduled'
                           and b['version'] == ref['plan_version'] and parse(b['end_at']) > self.clock() for b in state['blocks'])
            return True
        if ref.get('block_id'):
            b = next((b for b in state['blocks'] if b['id'] == ref['block_id']), None)
            return bool(b and b['status'] == 'scheduled' and b['version'] == ref['block_version']
                        and not any(s['block_id'] == b['id'] for s in state['sessions']))
        if ref.get('session_id'):
            s = next((s for s in state['sessions'] if s['id'] == ref['session_id']), None)
            if not s or s['state'] not in ('running', 'awaiting_feedback'):
                return False
            if ref.get('running'):
                title = next((t['title'] for t in state['tasks'] if t['id'] == s['task_id']), None)
                return (s['state'] == 'running' and parse(s['expected_end_at']) > self.clock()
                        and s['expected_end_at'] == ref.get('expected_end', s['expected_end_at'])
                        and title == ref.get('title', title))
            end = s['expected_end_at'] if s['state'] == 'running' else s['actual_end_at']
            return stamp(parse(end)) == ref['end']
        if ref.get('check_id'):
            check = next((c for c in state['waiting_checks'] if c['id'] == ref['check_id']), None)
            return bool(check and not check.get('resolved_at') and check.get('version', 1) == ref['check_version']
                        and any(t['id'] == check['task_id'] and t['state'] == 'waiting' for t in state['tasks']))
        if ref.get('kind') == 'daily':
            zone = ZoneInfo(state['settings']['timezone'])
            if self.clock().astimezone(zone).date().isoformat() != ref['date']:
                return False
            review = next((r for r in reversed(state['reviews']) if r['date'] == ref['date']), None)
            sessions = [s for s in state['sessions'] if parse(s['actual_start_at']).astimezone(zone).date().isoformat() == ref['date']]
            return (ref['review_id'] == (review['id'] if review else None)
                    and ref['counts'] == [len(sessions), sum(s['state'] == 'awaiting_feedback' for s in sessions)])
        return True
