from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import create_app


@pytest.fixture
def client(tmp_path):
    app = create_app(tmp_path)
    with TestClient(app) as value:
        value.headers["Authorization"] = "Bearer " + app.state.desktop_token
        yield value


def operation(op_kind, **payload):
    from uuid import uuid4
    return {"operation_id": str(uuid4()), "kind": op_kind, "payload": payload}


def send(client, op_kind, **payload):
    result = client.post("/api/v1/operations", json=operation(op_kind, **payload))
    assert result.status_code == 200, result.text
    return result.json()


def new_task(client, title="实验代码"):
    return send(client, "task.create", title=title, outcome_criteria="保存可运行输出", remaining_minutes=60)["entity"]


def block(client, task_id, start=None, duration=60, **extra):
    start = start or datetime.now(timezone.utc) + timedelta(hours=1)
    return send(client, "block.create", task_id=task_id, start_at=start.isoformat(),
                end_at=(start + timedelta(minutes=duration)).isoformat(), **extra)["entity"]


def test_authentication_and_restart_persistence(client, tmp_path):
    task = new_task(client)
    assert client.get("/api/v1/snapshot", headers={"Authorization": "Bearer invalid"}).status_code == 401
    restarted = create_app(tmp_path)
    with TestClient(restarted) as other:
        other.headers["Authorization"] = "Bearer " + restarted.state.desktop_token
        assert other.get("/api/v1/snapshot").json()["tasks"][0]["id"] == task["id"]


def test_idempotent_retry_and_operation_id_reuse(client):
    request = operation("task.create", title="算法", outcome_criteria="完成两道题", remaining_minutes=45)
    first = client.post("/api/v1/operations", json=request)
    retry = client.post("/api/v1/operations", json=request)
    assert first.json() == retry.json()
    assert len(client.get("/api/v1/snapshot").json()["tasks"]) == 1
    request["payload"]["title"] = "不同任务"
    assert client.post("/api/v1/operations", json=request).status_code == 409


def test_rejects_overlap_and_fixed_move(client):
    task = new_task(client)
    fixed = block(client, task["id"], kind="fixed")
    overlap = operation("block.create", task_id=task["id"], start_at=fixed["start_at"], end_at=fixed["end_at"])
    assert client.post("/api/v1/operations", json=overlap).status_code == 409
    move = operation("block.move", id=fixed["id"], version=fixed["version"], start_at=fixed["start_at"], end_at=fixed["end_at"])
    assert client.post("/api/v1/operations", json=move).status_code == 409


def test_task_execution_and_feedback_are_separate(client):
    task = new_task(client)
    scheduled = block(client, task["id"])
    session = send(client, "session.start", block_id=scheduled["id"])["entity"]
    assert client.post("/api/v1/operations", json=operation("session.start", block_id=scheduled["id"])).status_code == 409
    send(client, "session.pause", id=session["id"])
    send(client, "session.resume", id=session["id"])
    send(client, "session.end", id=session["id"])
    snapshot = client.get("/api/v1/snapshot").json()
    assert snapshot["sessions"][0]["state"] == "awaiting_feedback"
    assert snapshot["tasks"][0]["state"] != "done"
    send(client, "feedback.create", session_id=session["id"], choice="partial", remaining_minutes=30, outcome_text="还差输出")
    snapshot = client.get("/api/v1/snapshot").json()
    assert snapshot["tasks"][0]["state"] == "ready"
    assert snapshot["tasks"][0]["remaining_minutes"] == 30
    assert snapshot["sessions"][0]["state"] == "closed"


def test_waiting_releases_execution_and_records_check(client):
    task = new_task(client)
    scheduled = block(client, task["id"])
    session = send(client, "session.start", block_id=scheduled["id"])["entity"]
    send(client, "session.end", id=session["id"])
    check_at = (datetime.now(timezone.utc) + timedelta(hours=3)).isoformat()
    send(client, "feedback.create", session_id=session["id"], choice="waiting", check_at=check_at)
    snapshot = client.get("/api/v1/snapshot").json()
    assert snapshot["tasks"][0]["state"] == "waiting"
    assert snapshot["waiting_checks"][0]["check_at"]
    other_task = new_task(client, "算法")
    other_block = block(client, other_task["id"], start=datetime.now(timezone.utc) + timedelta(hours=5))
    assert send(client, "session.start", block_id=other_block["id"])["entity"]["state"] == "running"


def test_invalid_input_and_stale_version(client):
    invalid = operation("task.create", title=" ", outcome_criteria="结果", remaining_minutes=60)
    assert client.post("/api/v1/operations", json=invalid).status_code == 422
    task = new_task(client)
    send(client, "task.update", id=task["id"], version=task["version"], title="新标题")
    stale = operation("task.update", id=task["id"], version=task["version"], title="过期标题")
    assert client.post("/api/v1/operations", json=stale).status_code == 409


def test_review_archive_preserves_original_and_unknowns(client, tmp_path):
    new_task(client)
    send(client, "review.save", date="2026-10-19", text="脚本还未完成。明天继续。")
    report = client.get("/api/v1/reports/2026-10-19")
    assert report.status_code == 200
    assert "脚本还未完成" in report.json()["markdown"]
    assert "未确认" in report.json()["markdown"]
    assert (tmp_path / "archives" / "2026-10-19.md").exists()
    assert (tmp_path / "archives" / "2026-10-19.json").exists()

def test_compaction_keeps_recent_history_only(tmp_path):
    from app.maintenance import compact

    now = datetime.now(timezone.utc).replace(microsecond=0)
    app = create_app(tmp_path, clock=lambda: now, background=False)
    store = app.state.store
    user_id = store.owner_id
    with store.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        state = store.state(conn, user_id)
        state["proposals"] = [{"id": f"p{i}", "created_at": "2026-10-01T00:00:00Z"} for i in range(30)]
        state["feedbacks"] = [{"id": f"f{i}"} for i in range(250)]
        state["reviews"] = [{"date": "2026-10-01", "version": i} for i in range(120)]
        store.save(conn, state, user_id)
        for revision in range(1, 30):
            store.record_event(conn, user_id, revision, "test", "ping", {}, now)
    removed = compact(store, now, user_id)
    with store.connect() as conn:
        state = store.state(conn, user_id)
        assert len(state["proposals"]) == 20
        assert len(state["feedbacks"]) == 200
        assert len(state["reviews"]) == 100
        assert removed["proposals"] == 10 and removed["feedbacks"] == 50 and removed["reviews"] == 20
        assert conn.execute("SELECT COUNT(*) FROM user_events WHERE user_id=?",
                            (user_id,)).fetchone()[0] == 29
