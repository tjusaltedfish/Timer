from datetime import timedelta
from test_elastic_execution import clocked
from test_workflow import block, new_task, send, operation


def test_deleting_waiting_task_releases_plans_checks_and_keeps_evidence(clocked):
    c, current = clocked
    task = new_task(c)
    b = block(c, task['id'], start=current[0])
    s = send(c, 'session.start', block_id=b['id'])['entity']
    send(c, 'session.end', id=s['id'])
    send(c, 'feedback.create', session_id=s['id'], choice='waiting',
         outcome_text='报告已提交', check_at=(current[0] + timedelta(hours=2)).isoformat())
    future = block(c, task['id'], start=current[0] + timedelta(hours=4))
    state = c.get('/api/v1/snapshot').json()
    request = operation('task.update', id=task['id'], version=state['tasks'][0]['version'], state='cancelled')
    assert c.post('/api/v1/operations', json=request).status_code == 200
    assert c.post('/api/v1/operations', json=request).status_code == 200
    after = c.get('/api/v1/snapshot').json()
    assert after['tasks'][0]['state'] == 'cancelled'
    assert next(x for x in after['blocks'] if x['id'] == future['id'])['status'] == 'cancelled'
    assert after['waiting_checks'][0]['resolution'] == 'cancelled'
    assert after['feedbacks'][0]['outcome_text'] == '报告已提交'
    assert after['sessions'][0]['intervals'] == state['sessions'][0]['intervals']


def test_deleting_active_task_requires_ending_execution(clocked):
    c, current = clocked
    task = new_task(c)
    b = block(c, task['id'], start=current[0])
    send(c, 'session.start', block_id=b['id'])
    state = c.get('/api/v1/snapshot').json()
    response = c.post('/api/v1/operations', json=operation('task.update', id=task['id'],
        version=state['tasks'][0]['version'], state='cancelled'))
    assert response.status_code == 409
    assert c.get('/api/v1/snapshot').json()['tasks'][0]['state'] == 'in_progress'


def test_editing_task_title_updates_plans_but_keeps_recorded_block_titles(clocked):
    c, current = clocked
    task = new_task(c)
    b = block(c, task['id'], start=current[0])
    renamed = send(c, 'task.update', id=task['id'], version=1, title='重命名实验')['entity']
    snapshot = c.get('/api/v1/snapshot').json()
    assert snapshot['blocks'][0]['title'] == '重命名实验'
    session = send(c, 'session.start', block_id=b['id'])['entity']
    send(c, 'session.end', id=session['id'])
    send(c, 'feedback.create', session_id=session['id'], choice='done')
    task = c.get('/api/v1/snapshot').json()['tasks'][0]
    send(c, 'task.update', id=task['id'], version=task['version'], title='任务新标题')
    assert c.get('/api/v1/snapshot').json()['blocks'][0]['title'] == '重命名实验'
