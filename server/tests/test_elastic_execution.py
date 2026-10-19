from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from test_workflow import block, new_task, operation, send


@pytest.fixture
def clocked(tmp_path):
    current = [datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)]
    app = create_app(tmp_path, clock=lambda: current[0])
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer " + app.state.desktop_token
        yield client, current


def running(clocked, minutes=30, **options):
    client, current = clocked
    task = new_task(client)
    planned = block(client, task["id"], start=current[0], duration=minutes)
    session = send(client, "session.start", block_id=planned["id"], **options)["entity"]
    return client, current, task, planned, session


def test_late_start_can_keep_original_end_or_original_duration(clocked):
    client, current = clocked
    task = new_task(client)
    planned = block(client, task["id"], start=current[0], duration=60)
    current[0] += timedelta(minutes=20)
    session = send(client, "session.start", block_id=planned["id"], mode="keep_end")["entity"]
    assert session["expected_end_at"] == planned["end_at"]
    assert session["start_mode"] == "keep_end"
    send(client, "session.end", id=session["id"])
    send(client, "feedback.create", session_id=session["id"], choice="partial", remaining_minutes=30)
    next_block = block(client, task["id"], start=current[0] + timedelta(hours=2), duration=30)
    current[0] = datetime.fromisoformat(next_block["start_at"]) + timedelta(minutes=15)
    started = send(client, "session.start", block_id=next_block["id"])["entity"]
    assert datetime.fromisoformat(started["expected_end_at"]) == current[0] + timedelta(minutes=30)


def test_cannot_keep_an_end_that_has_passed(clocked):
    client, current = clocked
    task = new_task(client)
    planned = block(client, task["id"], start=current[0], duration=30)
    current[0] += timedelta(minutes=31)
    result = client.post("/api/v1/operations", json=operation("session.start", block_id=planned["id"], mode="keep_end"))
    assert result.status_code == 409
    assert not client.get("/api/v1/snapshot").json()["sessions"]


def test_extension_is_idempotent_and_pause_time_is_not_work(clocked):
    client, current, task, planned, session = running(clocked)
    request = operation("session.extend", id=session["id"], minutes=15, occurred_at=current[0].isoformat())
    response = client.post("/api/v1/operations", json=request)
    assert response.status_code == 200
    assert client.post("/api/v1/operations", json=request).json() == response.json()
    assert datetime.fromisoformat(response.json()["entity"]["expected_end_at"]) == current[0] + timedelta(minutes=45)
    current[0] += timedelta(minutes=10)
    send(client, "session.pause", id=session["id"])
    current[0] += timedelta(minutes=5)
    paused = send(client, "session.extend", id=session["id"], minutes=15)["entity"]
    assert paused["state"] == "paused"
    current[0] += timedelta(minutes=5)
    resumed = send(client, "session.resume", id=session["id"])["entity"]
    assert datetime.fromisoformat(resumed["expected_end_at"]) == datetime.fromisoformat(planned["end_at"]) + timedelta(minutes=40)
    for minutes in [4, 121]:
        assert client.post("/api/v1/operations", json=operation("session.extend", id=session["id"], minutes=minutes)).status_code == 422


def test_timer_extension_starts_now_without_filling_unknown_gap(clocked):
    client, current, task, planned, session = running(clocked, 10)
    current[0] += timedelta(minutes=15)
    result = send(client, "session.extend", id=session["id"], minutes=15)["entity"]
    assert result["state"] == "running"
    assert result["actual_end_at"] is None
    assert len(result["intervals"]) == 2
    assert result["intervals"][0]["end_at"] == planned["end_at"]
    assert datetime.fromisoformat(result["intervals"][1]["start_at"]) == current[0]
    assert datetime.fromisoformat(result["expected_end_at"]) == current[0] + timedelta(minutes=15)
    assert client.get("/api/v1/snapshot").json()["tasks"][0]["state"] != "done"


def test_offline_extension_before_timer_reconciles_and_late_extension_is_rejected(clocked):
    client, current, task, planned, session = running(clocked, 10)
    origin = current[0]
    current[0] += timedelta(hours=1)
    result = send(client, "session.extend", id=session["id"], minutes=15,
                  occurred_at=(origin + timedelta(minutes=5)).isoformat())["entity"]
    assert len(result["intervals"]) == 1
    assert result["intervals"][0]["end_at"] is None
    assert datetime.fromisoformat(result["expected_end_at"]) == origin + timedelta(minutes=25)
    rejected = client.post("/api/v1/operations", json=operation("session.extend", id=session["id"], minutes=15))
    assert rejected.status_code == 409  # More than 30 minutes after the new end.


def test_manual_end_or_another_active_session_cannot_be_reopened(clocked):
    client, current, task, planned, session = running(clocked, 10)
    send(client, "session.end", id=session["id"])
    assert client.post("/api/v1/operations", json=operation("session.extend", id=session["id"], minutes=15)).status_code == 409
    send(client, "feedback.create", session_id=session["id"], choice="partial", remaining_minutes=30)
    other_task = new_task(client)
    other_block = block(client, other_task["id"], start=current[0] + timedelta(hours=2), duration=10)
    timer = send(client, "session.start", block_id=other_block["id"])["entity"]
    current[0] += timedelta(minutes=15)
    third_task = new_task(client)
    third = block(client, third_task["id"], start=current[0] + timedelta(hours=4))
    send(client, "session.start", block_id=third["id"])
    assert client.post("/api/v1/operations", json=operation("session.extend", id=timer["id"], minutes=15)).status_code == 409


def test_interrupted_feedback_tracks_remaining_and_waiting_can_be_rescheduled(clocked):
    client, current, task, planned, session = running(clocked)
    send(client, "session.end", id=session["id"])
    missing = client.post("/api/v1/operations", json=operation("feedback.create", session_id=session["id"], choice="interrupted"))
    assert missing.status_code == 422
    send(client, "feedback.create", session_id=session["id"], choice="interrupted", remaining_minutes=45)
    assert client.get("/api/v1/snapshot").json()["tasks"][0]["remaining_minutes"] == 45
    planned = block(client, task["id"], start=current[0] + timedelta(hours=2))
    session = send(client, "session.start", block_id=planned["id"])["entity"]
    send(client, "session.end", id=session["id"])
    send(client, "feedback.create", session_id=session["id"], choice="waiting", check_at=(current[0] + timedelta(hours=3)).isoformat())
    check = client.get("/api/v1/snapshot").json()["waiting_checks"][0]
    request = operation("waiting.snooze", id=check["id"], version=1, check_at=(current[0] + timedelta(hours=5)).isoformat())
    changed = client.post("/api/v1/operations", json=request)
    assert changed.status_code == 200
    assert client.post("/api/v1/operations", json=request).json() == changed.json()
    assert changed.json()["entity"]["version"] == 2
    assert len(client.get("/api/v1/snapshot").json()["waiting_checks"]) == 1
    assert client.post("/api/v1/operations", json=operation("waiting.snooze", id=check["id"], version=1,
                       check_at=(current[0] + timedelta(hours=6)).isoformat())).status_code == 409
    assert client.post("/api/v1/operations", json=operation("waiting.snooze", id=check["id"], version=2, check_at=current[0].isoformat())).status_code == 422
    # Waiting must be resolved before this task starts working again.
    blocked = block(client, task["id"], start=current[0] + timedelta(hours=7))
    assert client.post("/api/v1/operations", json=operation("session.start", block_id=blocked["id"])).status_code == 409
    send(client, "waiting.resolve", id=check["id"], resolution="done")
    assert client.post("/api/v1/operations", json=operation("waiting.snooze", id=check["id"], version=2,
                       check_at=(current[0] + timedelta(hours=6)).isoformat())).status_code == 409


def test_waiting_identity_allows_offline_feedback_followed_by_snooze_without_a_snapshot(clocked):
    client, current, task, planned, session = running(clocked)
    send(client, "session.end", id=session["id"])
    feedback = operation("feedback.create", session_id=session["id"], choice="waiting",
                         check_at=(current[0] + timedelta(hours=2)).isoformat())
    assert client.post("/api/v1/operations", json=feedback).status_code == 200
    changed = send(client, "waiting.snooze", id=feedback["operation_id"], version=1,
                   check_at=(current[0] + timedelta(hours=4)).isoformat())["entity"]
    assert changed["id"] == feedback["operation_id"]
    assert changed["version"] == 2
