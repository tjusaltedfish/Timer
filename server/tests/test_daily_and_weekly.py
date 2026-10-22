"""The daily review stays on its own day and short; Sunday brings a weekly brief."""
import asyncio
import json
from datetime import timedelta

import pytest

from test_assistant import client, model, configure, send, NOW  # noqa: F401  (fixtures)
from test_wechat import env, configure as configure_wechat, bind, run  # noqa: F401
from app import materials


def block(client, task, start, hours=1):
    return send(client, 'block.create', task_id=task['id'],
                start_at=start.isoformat(), end_at=(start + timedelta(hours=hours)).isoformat())


def test_daily_review_sees_only_that_day_and_asks_for_a_short_answer(client, model):
    configure(client)
    today = send(client, 'task.create', title='偏压分析', outcome_criteria='跑完一组', remaining_minutes=60)
    other = send(client, 'task.create', title='明天的组会报告', outcome_criteria='做完幻灯片', remaining_minutes=90)
    block(client, today, NOW + timedelta(hours=1))
    block(client, other, NOW + timedelta(days=1, hours=1))
    send(client, 'review.save', date='2026-10-18', text='昨天写了别的东西')
    model.replies.append((200, '做成了：偏压分析跑完一组。\n' + '很长' * 400))
    response = client.post('/api/v1/reviews/generate', json={
        'date': '2026-10-19', 'text': '今天做了偏压分析。', 'material_ids': [], 'request_id': 'daily-short-001'})
    assert response.status_code == 200, response.text
    messages = json.loads(model.requests[-1].content)['messages']
    prompt = json.dumps(messages, ensure_ascii=False)
    assert '偏压分析' in prompt
    assert '明天的组会报告' not in prompt and '昨天写了别的东西' not in prompt
    assert messages[0]['content'] == materials.REVIEW_PROMPT and '180 字' in materials.REVIEW_PROMPT
    assert len(response.json()['text']) <= 600


def weekly_env(env, when):
    client, app, wechat, model = env
    token = configure_wechat(client)['token']
    bind(client, app, token)
    wechat.custom.clear()
    app.state.weekly.clock = lambda: when
    return client, app, wechat, model


def sunday_evening():
    # NOW is Monday 2026-10-19 09:00 in Los Angeles; Sunday 20:30 closes that week.
    return NOW + timedelta(days=6, hours=11, minutes=30)


def focus_and_finish(client, title):
    task = send(client, 'task.create', title=title, outcome_criteria='交付', remaining_minutes=60)
    planned = block(client, task, NOW)
    session = send(client, 'session.start', block_id=planned['id'])
    send(client, 'session.end', id=session['id'])
    send(client, 'feedback.create', session_id=session['id'], choice='done', outcome_text='交了')
    return task


def test_sunday_brief_has_numbers_and_a_short_summary_once(env):
    client, app, wechat, model = weekly_env(env, sunday_evening())
    client.post('/api/v1/assistant/config', json={'base_url': 'https://llm.example/v1', 'model': 'm', 'api_key': 'sk-test-1234567890'})
    focus_and_finish(client, '实验报告')
    model.replies.append('这周主要写完了实验报告。')
    asyncio.run(app.state.weekly.run_due())
    asyncio.run(app.state.weekly.run_due())
    run(client, app)
    briefs = [b['text']['content'] for _, b in wechat.custom if '本周简报' in b['text']['content']]
    assert len(briefs) == 1
    assert '10/19–10/25' in briefs[0] and '确认完成 1 件' in briefs[0] and '这周主要写完了实验报告。' in briefs[0]
    week_input = json.loads(model.requests[-1].content)['messages'][1]['content']
    assert '实验报告完成' in week_input


def test_brief_still_goes_out_when_the_model_fails(env):
    client, app, wechat, model = weekly_env(env, sunday_evening())
    focus_and_finish(client, '实验报告')  # no model configured at all
    asyncio.run(app.state.weekly.run_due())
    run(client, app)
    [brief] = [b['text']['content'] for _, b in wechat.custom if '本周简报' in b['text']['content']]
    assert '完成：实验报告' in brief


def test_a_failed_send_does_not_swallow_the_week(env):
    client, app, wechat, model = weekly_env(env, sunday_evening())
    focus_and_finish(client, '实验报告')
    channel = app.state.weekly.channel.wechat
    original = channel.enqueue_to
    attempts = {'n': 0}

    def flaky(openid, text, **kwargs):
        attempts['n'] += 1
        if attempts['n'] == 1:
            raise RuntimeError('outbox briefly unavailable')
        return original(openid, text, **kwargs)

    channel.enqueue_to = flaky
    try:
        with pytest.raises(RuntimeError):
            asyncio.run(app.state.weekly.run_due())  # claimed, then failed
        asyncio.run(app.state.weekly.run_due())      # claim released → retries
    finally:
        channel.enqueue_to = original
    run(client, app)
    [brief] = [b['text']['content'] for _, b in wechat.custom if '本周简报' in b['text']['content']]
    assert '完成：实验报告' in brief


def test_no_brief_before_sunday_evening(env):
    client, app, wechat, _ = weekly_env(env, sunday_evening() - timedelta(hours=1))
    asyncio.run(app.state.weekly.run_due())
    app.state.weekly.clock = lambda: NOW + timedelta(days=3, hours=12)  # Thursday evening
    asyncio.run(app.state.weekly.run_due())
    run(client, app)
    assert not any('本周简报' in b['text']['content'] for _, b in wechat.custom)


def test_a_qq_only_member_still_gets_the_week(env):
    """只绑了 QQ 的人，周报走 QQ 发件箱，而不是掉进微信黑洞。"""
    from app.domain import stamp
    client, app, wechat, _ = env
    configure_wechat(client)  # no WeChat follower bound in this test
    store = app.state.store
    with store.connect() as conn:
        conn.execute(
            "INSERT INTO channel_identities(channel, external_id, user_id, created_at, last_seen_at) "
            "VALUES('qq', ?, ?, ?, ?)",
            ("o_qq_only_member", store.owner_id, stamp(NOW), stamp(NOW)))
    app.state.weekly.clock = lambda: sunday_evening()
    focus_and_finish(client, '实验报告')
    asyncio.run(app.state.weekly.run_due())
    with store.connect() as conn:
        rows = conn.execute("SELECT text FROM qq_outbox").fetchall()
    assert rows and any('本周简报' in row[0] for row in rows), "QQ-only member should get the brief on QQ"
