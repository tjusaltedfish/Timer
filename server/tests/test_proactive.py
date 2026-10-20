import asyncio
from datetime import timedelta

from test_wechat import env, configure, bind, run, NOW
from test_assistant import send


def setup(env):
    c, app, fake, _ = env
    token = configure(c)['token']
    bind(c, app, token)
    fake.custom.clear()
    return c, app, fake


def test_cross_device_task_receipt_start_and_daily_are_deduplicated(env):
    c, app, fake = setup(env)
    task = send(c, 'task.create', id='task-proactive', title='实验报告', outcome_criteria='保存报告', remaining_minutes=60)
    send(c, 'block.create', id='block-proactive', task_id=task['id'], start_at=NOW.isoformat(), end_at=(NOW + timedelta(hours=1)).isoformat())
    app.state.proactive.tick()
    app.state.proactive.tick()
    run(c, app)
    texts = [b['text']['content'] for _, b in fake.custom]
    assert sum('待办已添加' in t for t in texts) == 1
    assert sum('该开始了' in t for t in texts) == 1
    assert all('实验报告' in t for t in texts)
    app.state.proactive.clock = lambda: NOW + timedelta(hours=13)
    app.state.wechat.clock = app.state.proactive.clock
    app.state.proactive.tick()
    app.state.proactive.tick()
    run(c, app)
    assert sum('今日收尾' in b['text']['content'] for _, b in fake.custom) == 1


def test_extension_cancels_the_already_queued_result_question_and_is_replay_safe(env):
    c, app, fake = setup(env)
    task = send(c, 'task.create', id='task-proactive', title='实验报告', outcome_criteria='保存报告', remaining_minutes=60)
    b = send(c, 'block.create', id='block-proactive', task_id=task['id'], start_at=NOW.isoformat(), end_at=(NOW + timedelta(hours=1)).isoformat())
    s = send(c, 'session.start', id='abcdef-123456', block_id=b['id'])
    app.state.proactive.tick()
    run(c, app)
    assert any('已进入专注' in body['text']['content'] for _, body in fake.custom)
    later = NOW + timedelta(minutes=61)
    app.state.proactive.clock = app.state.wechat.clock = app.state.assistant.clock = lambda: later
    app.state.proactive.tick()
    result_key = next(r['dedup_key'] for r in queued(app) if ':result:' in r['dedup_key'])
    reply = c.portal.call(app.state.wechat.handle, '再给我15分钟 ABCDEF', 'extend-once')
    assert '已增加 15 分钟' in reply
    assert not app.state.proactive.valid(result_key)
    repeat = c.portal.call(app.state.wechat.handle, '再给我15分钟 ABCDEF', 'extend-once')
    assert '已经记录' in repeat
    state = c.get('/api/v1/snapshot').json()
    assert state['sessions'][0]['extension_minutes'] == 15
    run(c, app)
    assert not any('这一段到时间了' in body['text']['content'] for _, body in fake.custom)
    c.portal.call(app.state.wechat.handle, '完成了 ABCDEF', 'complete-once')
    assert c.get('/api/v1/snapshot').json()['tasks'][0]['state'] == 'done'


def queued(app):
    with app.state.store.connect() as conn:
        return [dict(row) for row in conn.execute("SELECT * FROM wechat_outbox WHERE status='queued'")]


def test_deleted_task_and_disabled_notifications_are_not_delivered(env):
    c, app, fake = setup(env)
    task = send(c, 'task.create', id='task-proactive', title='实验报告', outcome_criteria='保存报告', remaining_minutes=60)
    app.state.proactive.tick()
    send(c, 'task.update', id=task['id'], version=1, state='cancelled')
    run(c, app)
    assert fake.custom == []
    task = send(c, 'task.create', id='another-task', title='学习', outcome_criteria='笔记', remaining_minutes=60)
    app.state.proactive.tick()
    configure(c, proactive_enabled=False)
    run(c, app)
    assert fake.custom == []
