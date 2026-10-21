import asyncio
from datetime import timedelta

import httpx
import pytest
from fastapi.testclient import TestClient

from app import assistant
from app.main import create_app
from test_wechat import (env, configure, bind, run, NOW, FakeWeChat, FakeModel,
                         OWNER, APP_SECRET)
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


def test_generated_operation_ids_still_produce_creation_and_focus_receipts(env):
    c, app, fake = setup(env)
    task = send(c, 'task.create', title='服务端生成标识', outcome_criteria='输出报告', remaining_minutes=60)
    app.state.proactive.tick()
    run(c, app)
    assert any('待办已添加' in b['text']['content'] for _, b in fake.custom)
    block = send(c, 'block.create', task_id=task['id'], start_at=(NOW + timedelta(hours=1)).isoformat(),
                 end_at=(NOW + timedelta(hours=2)).isoformat())
    send(c, 'session.start', block_id=block['id'])
    app.state.proactive.tick()
    run(c, app)
    assert any('已进入专注' in b['text']['content'] for _, b in fake.custom)


def test_pending_focus_receipt_is_invalid_after_its_estimated_end_changes(env):
    c, app, fake = setup(env)
    task = send(c, 'task.create', id='focus-task', title='报告', outcome_criteria='输出报告', remaining_minutes=60)
    block = send(c, 'block.create', task_id=task['id'], start_at=NOW.isoformat(), end_at=(NOW + timedelta(hours=1)).isoformat())
    session = send(c, 'session.start', id='focus-session', block_id=block['id'])
    app.state.proactive.tick()
    key = next(r['dedup_key'] for r in queued(app) if ':focus:' in r['dedup_key'])
    send(c, 'session.extend', id=session['id'], minutes=15)
    assert app.state.proactive.valid(key) is False
    run(c, app)
    assert not any('已进入专注' in b['text']['content'] for _, b in fake.custom)


def test_queued_creation_and_daily_messages_do_not_repeat_stale_facts(env):
    c, app, fake = setup(env)
    task = send(c, 'task.create', id='renamed-task', title='旧标题', outcome_criteria='输出报告', remaining_minutes=60)
    app.state.proactive.tick()
    key = next(r['dedup_key'] for r in queued(app) if ':created:' in r['dedup_key'])
    send(c, 'task.update', id=task['id'], version=1, title='新标题')
    assert app.state.proactive.valid(key) is False
    app.state.proactive.clock = lambda: NOW + timedelta(hours=13)
    app.state.proactive.tick()
    key = next(r['dedup_key'] for r in queued(app) if ':daily:' in r['dedup_key'])
    send(c, 'review.save', date='2026-10-19', text='今天已保存原文。')
    assert app.state.proactive.valid(key) is False


def test_reopened_task_does_not_receive_a_waiting_check_prompt(env):
    c, app, fake = setup(env)
    task = send(c, 'task.create', id='waiting-task', title='等待实验', outcome_criteria='输出报告', remaining_minutes=60)
    block = send(c, 'block.create', task_id=task['id'], start_at=NOW.isoformat(), end_at=(NOW + timedelta(hours=1)).isoformat())
    session = send(c, 'session.start', block_id=block['id'])
    send(c, 'session.end', id=session['id'])
    send(c, 'feedback.create', session_id=session['id'], choice='waiting', check_at=(NOW + timedelta(minutes=1)).isoformat())
    app.state.proactive.clock = lambda: NOW + timedelta(minutes=2)
    app.state.proactive.tick()
    key = next(r['dedup_key'] for r in queued(app) if ':waiting:' in r['dedup_key'])
    task = c.get('/api/v1/snapshot').json()['tasks'][0]
    send(c, 'task.update', id=task['id'], version=task['version'], state='ready')
    assert app.state.proactive.valid(key) is False
    app.state.proactive.tick()
    run(c, app)
    assert not any('看看等待的结果' in b['text']['content'] for _, b in fake.custom)


def test_wechat_assistant_change_is_not_echoed_as_a_second_receipt(env):
    c, app, fake = setup(env)
    model = env[3]
    c.post('/api/v1/assistant/config', json={'base_url': 'https://llm.example/v1', 'model': 'm', 'api_key': 'sk-test-1234567890'})
    model.replies.append({'reply': '已排明早十点写脚本。', 'drafts': [{'summary': '脚本', 'actions': [
        {'type': 'schedule_new', 'title': '脚本', 'outcome_criteria': 'CSV', 'start_local': '2026-10-20 10:00', 'minutes': 60}]}]})
    reply = c.portal.call(app.state.wechat.handle, '明早十点写脚本', 'wx-auto-1')
    assert reply.startswith('已排明早十点写脚本。')
    app.state.proactive.tick()
    run(c, app)
    assert not any('待办已添加' in body['text']['content'] for _, body in fake.custom)


def test_time_up_question_offers_finish_extend_and_postpone_without_codes(env):
    c, app, fake = setup(env)
    task = send(c, 'task.create', id='task-up', title='实验报告', outcome_criteria='保存报告', remaining_minutes=60)
    b = send(c, 'block.create', id='block-up', task_id=task['id'], start_at=NOW.isoformat(), end_at=(NOW + timedelta(hours=1)).isoformat())
    send(c, 'session.start', id='abcdef-654321', block_id=b['id'])
    app.state.proactive.clock = app.state.wechat.clock = lambda: NOW + timedelta(minutes=61)
    app.state.proactive.tick()
    run(c, app)
    [text] = [body['text']['content'] for _, body in fake.custom if '到时间了' in body['text']['content']]
    assert '「完成了」' in text and '「再给我15分钟」' in text and '推迟' in text


@pytest.fixture
def movable_env(tmp_path, monkeypatch):
    """WeChat env whose clock can advance without recreating the app."""
    monkeypatch.setattr(assistant, "RETRY_DELAYS", (0, 0, 0))
    monkeypatch.delenv("PLANNER_LLM_API_KEY", raising=False)
    wechat, model = FakeWeChat(), FakeModel()
    now = [NOW]
    app = create_app(tmp_path, clock=lambda: now[0], llm_transport=httpx.MockTransport(model),
                     wechat_transport=httpx.MockTransport(wechat), background=False)
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer " + app.state.desktop_token
        token = configure(client)['token']
        bind(client, app, token)
        wechat.custom.clear()
        yield client, app, wechat, now


def test_late_end_tells_wechat_that_following_blocks_moved(movable_env):
    c, app, fake, now = movable_env
    task = send(c, 'task.create', title='实验报告', outcome_criteria='保存报告', remaining_minutes=120)
    source = send(c, 'block.create', task_id=task['id'], start_at=now[0].isoformat(),
                  end_at=(now[0] + timedelta(hours=1)).isoformat())
    later = send(c, 'block.create', task_id=send(c, 'task.create', title='下一件', outcome_criteria='完成', remaining_minutes=30)['id'],
                 start_at=(now[0] + timedelta(hours=1)).isoformat(),
                 end_at=(now[0] + timedelta(hours=1, minutes=30)).isoformat())
    session = send(c, 'session.start', block_id=source['id'])
    now[0] += timedelta(minutes=70)
    info = send(c, 'session.end', id=session['id'])['adjustment']
    assert info['status'] == 'applied' and info['minutes'] == 10
    app.state.proactive.tick()
    run(c, app)
    texts = [body['text']['content'] for _, body in fake.custom]
    assert any('后面的安排已顺延 10 分钟' in t for t in texts)


def test_early_end_asks_in_wechat_and_reply_pulls_the_chain(movable_env):
    c, app, fake, now = movable_env
    task = send(c, 'task.create', title='实验报告', outcome_criteria='保存报告', remaining_minutes=120)
    source = send(c, 'block.create', task_id=task['id'], start_at=now[0].isoformat(),
                  end_at=(now[0] + timedelta(hours=1)).isoformat())
    next_task = send(c, 'task.create', title='下一件', outcome_criteria='完成', remaining_minutes=30)
    later = send(c, 'block.create', task_id=next_task['id'],
                 start_at=(now[0] + timedelta(hours=1)).isoformat(),
                 end_at=(now[0] + timedelta(hours=1, minutes=30)).isoformat())
    session = send(c, 'session.start', block_id=source['id'])
    now[0] += timedelta(minutes=40)
    info = send(c, 'session.end', id=session['id'])['adjustment']
    assert info['status'] == 'proposal' and info['early'] is True
    app.state.proactive.tick()
    run(c, app)
    texts = [body['text']['content'] for _, body in fake.custom]
    assert any('回复「提前」就改' in t for t in texts)
    assert not any('已提前' in t for t in texts)

    reply = c.portal.call(app.state.wechat.handle, '提前', 'early-once')
    assert '已提前：下一件' in reply
    state = c.get('/api/v1/snapshot').json()
    moved = next(b for b in state['blocks'] if b.get('source_block_id') == later['id'])
    assert moved['start_at'] == (NOW + timedelta(minutes=40)).isoformat()
    again = c.portal.call(app.state.wechat.handle, '提前', 'early-twice')
    assert '没有可以提前' in again
