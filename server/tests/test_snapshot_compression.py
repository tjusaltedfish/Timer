"""The full-state snapshot is the biggest thing a phone downloads; gzip it."""
from test_assistant import client, model, send  # noqa: F401


def test_snapshot_is_gzipped_for_phones(client):  # noqa: F811
    send(client, 'task.create', title='压缩探测', outcome_criteria='交给老师' + '很好' * 800,
         remaining_minutes=60)
    response = client.get('/api/v1/snapshot', headers={'Accept-Encoding': 'gzip, deflate'})
    assert response.status_code == 200
    assert response.headers.get('content-encoding') == 'gzip'
    assert '压缩探测' in response.text


def test_tiny_responses_stay_uncompressed(client):  # noqa: F811
    response = client.get('/health', headers={'Accept-Encoding': 'gzip, deflate'})
    assert response.status_code == 200
    assert response.headers.get('content-encoding') is None
