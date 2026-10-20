"""The assistant carries out clear requests at once; every schedule change can be undone."""
from datetime import timedelta
from uuid import uuid4

from app import assistant
from test_assistant import model, client, configure, NOW, send  # noqa: F401  (fixtures)


def block(client, **payload):
    response = client.post('/api/v1/operations', json={'operation_id': str(uuid4()), 'kind': 'block.create',
                                                       'payload': payload})
    assert response.status_code == 200, response.text
    return response.json()['entity']


def auto(client):
    return configure(client, confirm_first=False)


def ask(client, text):
    response = client.post('/api/v1/assistant/messages', json={'text': text})
    assert response.status_code == 200, response.text
    return response.json()['messages'][-1]


def scheduled(client):
    return [b for b in client.get('/api/v1/snapshot').json()['blocks'] if b['status'] == 'scheduled']


def test_noon_deadline_is_scheduled_immediately_without_a_question(client, model):
    auto(client)
    send(client, 'task.create', title='完成时间表开发', outcome_criteria='可运行', remaining_minutes=60)
    current = [NOW + timedelta(hours=2, minutes=10, seconds=35)]  # 11:10:35 local
    client.app.state.assistant.clock = lambda: current[0]
    model.replies.append((200, {'reply': '已排 11:10–12:00 做 t1，还差约 10 分钟。你定是否降低标准？', 'drafts': [{
        'summary': '12 点前做 t1', 'actions': [{'type': 'schedule_task', 'task': 't1', 'start_local': 'now',
                                               'until_local': '2026-10-19 12:00', 'minutes': 60}]}]}))
    reply = ask(client, '今天上午12点之前完成这个项目的开发')
    assert reply['text'] == '已排 11:10–12:00 做 完成时间表开发，还差约 10 分钟。'
    assert reply['drafts'][0]['status'] == 'applied' and reply['drafts'][0]['undoable'] is True
    [block] = scheduled(client)
    assert assistant.parse(block['end_at']) == NOW + timedelta(hours=3)
    system = model.requests[-1].content.decode()
    assert '立即执行' in system


def test_cancel_and_move_protected_meals_then_undo_both(client, model):
    auto(client)
    lunch = block(client, title='吃饭2', kind='protected',
                 start_at=(NOW + timedelta(hours=3)).isoformat(), end_at=(NOW + timedelta(hours=4)).isoformat())
    breakfast = block(client, title='吃饭', kind='protected',
                     start_at=(NOW + timedelta(days=1)).isoformat(), end_at=(NOW + timedelta(days=1, hours=1)).isoformat())
    model.replies.append((200, {'reply': '已把午饭挪到 13:00，明早的饭撤了。', 'drafts': [{
        'summary': '午饭改到一点，撤下明早的饭', 'actions': [
            {'type': 'move_block', 'block': 'b1', 'start_local': '2026-10-19 13:00', 'minutes': 45},
            {'type': 'cancel_block', 'block': 'b2'}]}]}))
    reply = ask(client, '把午饭改到一点，吃 45 分钟；明天早上的吃饭关了')
    draft = reply['drafts'][0]
    assert draft['status'] == 'applied' and draft['undoable']
    assert any(line.startswith('撤下') and '吃饭' in line for line in draft['lines'])
    [moved] = scheduled(client)
    assert moved['id'] == lunch['id']
    assert assistant.parse(moved['start_at']) == NOW + timedelta(hours=4)
    assert assistant.parse(moved['end_at']) - assistant.parse(moved['start_at']) == timedelta(minutes=45)
    assert client.post(f"/api/v1/assistant/drafts/{draft['id']}/undo").status_code == 200
    blocks = {b['id']: b for b in scheduled(client)}
    assert set(blocks) == {lunch['id'], breakfast['id']}
    assert blocks[lunch['id']]['start_at'] == lunch['start_at'] and blocks[lunch['id']]['end_at'] == lunch['end_at']
    history = client.get('/api/v1/assistant/messages').json()['messages']
    assert history[-1]['drafts'][0]['status'] == 'undone'
    assert client.post(f"/api/v1/assistant/drafts/{draft['id']}/undo").status_code == 404


def test_undo_of_a_new_task_removes_it_and_its_time(client, model):
    auto(client)
    model.replies.append((200, {'reply': '已排明早十点写扫描脚本。', 'drafts': [{'summary': '扫描脚本', 'actions': [
        {'type': 'schedule_new', 'title': '扫描脚本', 'outcome_criteria': '输出 CSV',
         'start_local': '2026-10-20 10:00', 'minutes': 90}]}]}))
    draft = ask(client, '明早十点写扫描脚本')['drafts'][0]
    assert len(scheduled(client)) == 1
    client.post(f"/api/v1/assistant/drafts/{draft['id']}/undo")
    state = client.get('/api/v1/snapshot').json()
    assert scheduled(client) == [] and state['tasks'][0]['state'] == 'cancelled'


def test_undo_refuses_after_a_later_edit(client, model):
    auto(client)
    model.replies.append((200, {'reply': '已排。', 'drafts': [{'summary': '午饭', 'actions': [
        {'type': 'protect', 'title': '午饭', 'start_local': '2026-10-19 12:00', 'minutes': 60}]}]}))
    draft = ask(client, '中午留一小时吃饭')['drafts'][0]
    [block] = scheduled(client)
    send(client, 'block.move', id=block['id'], version=block['version'], allow_fixed=True,
         start_at=(NOW + timedelta(hours=5)).isoformat(), end_at=(NOW + timedelta(hours=6)).isoformat())
    response = client.post(f"/api/v1/assistant/drafts/{draft['id']}/undo")
    assert response.status_code == 409 and '没法整体撤销' in response.json()['message']
    assert len(scheduled(client)) == 1


def test_a_change_that_cannot_be_made_is_never_reported_as_done(client, model):
    auto(client)
    block(client, title='组会', kind='protected',
         start_at=(NOW + timedelta(hours=1)).isoformat(), end_at=(NOW + timedelta(hours=2)).isoformat())
    model.replies.append((200, {'reply': '已排好十点读论文。', 'drafts': [{'summary': '读论文', 'actions': [
        {'type': 'schedule_new', 'title': '读论文', 'outcome_criteria': '读完', 'start_local': '2026-10-19 10:00',
         'minutes': 60}]}]}))
    reply = ask(client, '十点读论文')
    assert '已排好' not in reply['text'] and '冲突' in reply['text']
    assert reply['drafts'] == []
    assert len(scheduled(client)) == 1


def test_stated_habits_become_visible_deletable_memories(client, model):
    auto(client)
    model.replies.append((200, {'reply': '好，以后实验优先排上午。', 'drafts': [],
                                'remember': ['实验类任务优先安排在上午']}))
    reply = ask(client, '我上午脑子最清楚，实验都放上午吧')
    assert '已记下：实验类任务优先安排在上午' in reply['text']
    [memory] = client.get('/api/v1/snapshot').json()['memories']
    assert memory['source'] == 'assistant'
    model.replies.append((200, {'reply': '好。', 'drafts': [], 'remember': ['实验类任务优先安排在上午']}))
    assert '已记下' not in ask(client, '实验放上午')['text']
    assert len(client.get('/api/v1/snapshot').json()['memories']) == 1


def test_confirm_first_keeps_drafts_waiting(client, model):
    configure(client, confirm_first=True)
    model.replies.append((200, {'reply': '拟办：明早十点写脚本。', 'drafts': [{'summary': '脚本', 'actions': [
        {'type': 'schedule_new', 'title': '脚本', 'outcome_criteria': 'CSV', 'start_local': '2026-10-20 10:00',
         'minutes': 60}]}]}))
    reply = ask(client, '明早十点写脚本')
    assert reply['drafts'][0]['status'] == 'pending' and scheduled(client) == []
    assert '确认后' in model.requests[-1].content.decode()
