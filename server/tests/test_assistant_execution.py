import json
from datetime import timedelta
from zoneinfo import ZoneInfo
import pytest
from app.domain import DomainError
from app import assistant
from test_assistant import model, client, configure, NOW, send


def test_current_minute_becomes_executable_without_missing_the_deadline(client, model):
    configure(client)
    task = send(client, 'task.create', title='项目开发', outcome_criteria='可演示版本', remaining_minutes=60)
    model.replies.append((200, {'reply': 't1 剩余60分，你定是否降低标准。', 'drafts': [{
        'summary': '午前开发', 'actions': [{'type': 'schedule_task', 'task': 't1',
          'start_local': '2026-10-19 09:00', 'until_local': '2026-10-19 10:00', 'minutes': 60}]}]}))
    reply = client.post('/api/v1/assistant/messages', json={'text': '今天10点前完成项目开发'}).json()['messages'][-1]
    assert len(reply['drafts']) == 1
    assert len(reply['text']) < 40 and 't1' not in reply['text']
    draft = reply['drafts'][0]
    assert client.post(f"/api/v1/assistant/drafts/{draft['id']}/apply").status_code == 200
    block = client.get('/api/v1/snapshot').json()['blocks'][0]
    assert block['task_id'] == task['id']
    assert assistant.parse(block['start_at']) > NOW
    assert assistant.parse(block['end_at']) <= NOW + timedelta(hours=1)


def test_immediate_draft_rebases_on_confirmation_but_absolute_past_is_rejected():
    state = {'settings': {'timezone': 'UTC'}, 'tasks': [], 'blocks': []}
    reply = assistant.ModelReply.model_validate({'reply': '', 'drafts': [{'summary': '现在', 'actions': [
        {'type': 'schedule_new', 'title': '代码', 'outcome_criteria': 'CSV', 'start_local': 'now',
         'until_local': '2026-10-19 17:00', 'minutes': 60}]}]})
    drafts, _ = assistant.resolve_drafts(reply, state, {}, NOW)
    later = NOW + timedelta(minutes=5)
    ops = assistant.draft_operations(state, drafts[0]['actions'], later)
    assert assistant.parse(ops[1][1]['start_at']) > later
    assert assistant.parse(ops[1][1]['end_at']) <= NOW + timedelta(hours=1)


def test_explicit_preferences_are_logged_persistent_and_shared_in_context(client, model):
    result = client.post('/api/v1/assistant/messages', json={'text': '记住：回答请简短，上午优先做实验'}).json()
    assert '已记住' in result['messages'][-1]['text']
    state = client.get('/api/v1/snapshot').json()
    memory = state['memories'][0]
    assert memory['source'] == 'user'
    assert model.requests == []
    configure(client)
    client.post('/api/v1/assistant/messages', json={'text': '明天做什么'})
    context = json.loads(model.requests[-1].content)['messages'][1]['content']
    assert '上午优先做实验' in context
    assert client.post('/api/v1/assistant/messages', json={'text': '忘记：回答请简短，上午优先做实验'}).status_code == 200
    assert client.get('/api/v1/snapshot').json()['memories'] == []
    client.post('/api/v1/assistant/messages', json={'text': '现在有什么安排'})
    context = json.loads(model.requests[-1].content)['messages']
    assert '上午优先做实验' not in json.dumps(context, ensure_ascii=False)


def test_control_drafts_are_executable_and_reject_changed_execution_state(client, model):
    configure(client)
    task = send(client, 'task.create', title='代码', outcome_criteria='CSV', remaining_minutes=60)
    b = send(client, 'block.create', task_id=task['id'], start_at=NOW.isoformat(), end_at=(NOW + timedelta(hours=1)).isoformat())
    session = send(client, 'session.start', block_id=b['id'])
    model.replies.append((200, {'reply': '续时', 'drafts': [{'summary': '续时15分钟', 'actions': [
        {'type': 'control_session', 'block': 'b1', 'action': 'extend', 'minutes': 15}]}]}))
    reply = client.post('/api/v1/assistant/messages', json={'text': '再给我15分钟'}).json()['messages'][-1]
    assert len(reply['drafts']) == 1
    draft = reply['drafts'][0]
    send(client, 'session.pause', id=session['id'])
    assert client.post(f"/api/v1/assistant/drafts/{draft['id']}/apply").status_code == 409
    assert client.get('/api/v1/snapshot').json()['sessions'][0].get('extension_minutes', 0) == 0


def test_conflicting_draft_is_caught_before_it_is_offered(client, model):
    configure(client)
    task = send(client, 'task.create', title='代码', outcome_criteria='CSV', remaining_minutes=60)
    send(client, 'block.create', task_id=task['id'], start_at='2026-10-19T18:00:00Z', end_at='2026-10-19T19:00:00Z')
    model.replies.append((200, {'reply': '安排', 'drafts': [{'summary': '冲突', 'actions': [
        {'type': 'schedule_task', 'task': 't1', 'start_local': '2026-10-19 11:00', 'minutes': 60}]}]}))
    reply = client.post('/api/v1/assistant/messages', json={'text': '安排11点'}).json()['messages'][-1]
    assert reply['drafts'] == [] and '冲突' in reply['text']


def test_clock_precision_and_dst_boundaries_are_explicit():
    zone = ZoneInfo('America/Los_Angeles')
    with pytest.raises(DomainError, match='出现两次'):
        assistant.to_utc('2026-11-01 01:30', zone)
    first = assistant.to_utc('2026-11-01 01:30-07:00', zone)
    second = assistant.to_utc('2026-11-01 01:30-08:00', zone)
    assert second - first == timedelta(hours=1)
    with pytest.raises(DomainError, match='不存在'):
        assistant.to_utc('2026-03-08 02:30', zone)
    requested = NOW + timedelta(seconds=35)
    response_at = NOW + timedelta(minutes=1, seconds=20)
    reply = assistant.ModelReply.model_validate({'drafts': [{'summary': '现在开始', 'actions': [{
        'type': 'schedule_new', 'title': '代码', 'outcome_criteria': 'CSV',
        'start_local': '2026-10-19 09:00', 'until_local': '2026-10-19 10:00', 'minutes': 60}]}]})
    drafts, notes = assistant.resolve_drafts(reply, {'settings': {'timezone': 'America/Los_Angeles'}}, {}, response_at, requested_at=requested)
    assert len(drafts) == 1 and not notes
