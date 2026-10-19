from datetime import datetime, timedelta, timezone
from fastapi.testclient import TestClient
from app.main import create_app
from test_workflow import client, new_task, send, block, operation


def test_elapsed_session_requests_feedback_without_completing_task_and_accepts_late_offline_events(tmp_path):
    origin = datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)
    current = [origin]
    app = create_app(tmp_path, clock=lambda: current[0])
    with TestClient(app) as c:
        c.headers['Authorization'] = 'Bearer ' + app.state.desktop_token
        task = new_task(c)
        planned = block(c, task['id'], start=origin, duration=1)
        session = send(c, 'session.start', block_id=planned['id'])['entity']
        current[0] = origin + timedelta(seconds=90)
        expired = c.get('/api/v1/snapshot').json()
        assert expired['sessions'][0]['state'] == 'awaiting_feedback'
        assert expired['tasks'][0]['state'] != 'done'
        # Offline pause/resume happened before the target was really exhausted.
        send(c, 'session.pause', id=session['id'], occurred_at=(origin+timedelta(seconds=20)).isoformat())
        send(c, 'session.resume', id=session['id'], occurred_at=(origin+timedelta(seconds=70)).isoformat())
        current[0] = origin + timedelta(seconds=150)
        assert c.get('/api/v1/snapshot').json()['sessions'][0]['state'] == 'awaiting_feedback'
        send(c, 'session.end', id=session['id'], occurred_at=(origin+timedelta(seconds=100)).isoformat())
        actual = c.get('/api/v1/snapshot').json()['sessions'][0]
        seconds = sum((datetime.fromisoformat(i['end_at'])-datetime.fromisoformat(i['start_at'])).total_seconds() for i in actual['intervals'])
        assert seconds == 50
        assert actual['actual_end_at'] == (origin+timedelta(seconds=100)).isoformat()


def test_returned_waiting_result_can_be_confirmed_without_a_fake_work_session(client):
    task = new_task(client)
    planned = block(client, task['id'])
    session = send(client, 'session.start', block_id=planned['id'])['entity']
    send(client, 'session.end', id=session['id'])
    send(client, 'feedback.create', session_id=session['id'], choice='waiting',
         check_at=(datetime.now(timezone.utc)+timedelta(hours=2)).isoformat())
    check = client.get('/api/v1/snapshot').json()['waiting_checks'][0]
    send(client, 'waiting.resolve', id=check['id'], resolution='done', outcome_text='结果已核对，输出正常')
    actual = client.get('/api/v1/snapshot').json()
    assert actual['tasks'][0]['state'] == 'done'
    assert len(actual['sessions']) == 1
    assert actual['waiting_checks'][0]['resolved_at']
    assert actual['feedbacks'][-1]['outcome_text'] == '结果已核对，输出正常'


def test_null_patch_and_repeated_skip_are_rejected(client):
    task = new_task(client)
    invalid = operation('task.update', id=task['id'], version=task['version'], remaining_minutes=None)
    assert client.post('/api/v1/operations', json=invalid).status_code == 422
    invalid = operation('settings.update', timezone=None)
    assert client.post('/api/v1/operations', json=invalid).status_code == 422
    planned = block(client, task['id'])
    send(client, 'feedback.create', block_id=planned['id'], choice='not_started')
    assert client.post('/api/v1/operations', json=operation('feedback.create', block_id=planned['id'], choice='not_started')).status_code == 409
