from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.main import create_app

NOW = datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)  # 09:00 Los Angeles


@pytest.fixture
def client(tmp_path):
    app = create_app(tmp_path, clock=lambda: NOW)
    with TestClient(app) as value:
        value.headers["Authorization"] = "Bearer " + app.state.desktop_token
        yield value


def send(client, kind, expect=200, **payload):
    response = client.post("/api/v1/operations", json={"operation_id": str(uuid4()), "kind": kind, "payload": payload})
    assert response.status_code == expect, response.text
    return response.json().get("entity") if expect == 200 else response.json()


def at(hours):
    return (NOW + timedelta(hours=hours)).isoformat()


def test_categories_are_user_defined_and_optional(client):
    assert client.get("/api/v1/snapshot").json()["projects"] == []
    loose = send(client, "task.create", title="随手一件事", outcome_criteria="做完", remaining_minutes=30)
    assert loose["project_id"] is None
    reading = send(client, "project.create", name="读论文")
    send(client, "project.create", expect=409, name="读论文")
    task = send(client, "task.create", title="刻蚀综述", outcome_criteria="三条结论", remaining_minutes=60,
                project_id=reading["id"])
    send(client, "project.update", id=reading["id"], name="文献")
    send(client, "task.update", id=task["id"], version=task["version"], project_id=None)
    send(client, "project.update", id=reading["id"], archived=True)
    send(client, "task.create", expect=404, title="x", outcome_criteria="y", remaining_minutes=5,
         project_id=reading["id"])
    send(client, "task.create", expect=404, title="x", outcome_criteria="y", remaining_minutes=5, project_id="code")
    state = client.get("/api/v1/snapshot").json()
    assert state["projects"][0]["name"] == "文献" and state["projects"][0]["archived"] is True
    assert next(t for t in state["tasks"] if t["id"] == task["id"])["project_id"] is None


def test_sleep_can_be_started_finished_edited_and_reported(client):
    night = str(uuid4())
    send(client, "sleep.log", id=night, slept_at=at(-9))
    send(client, "sleep.log", expect=409, id=str(uuid4()), slept_at=at(-1))  # one open entry at a time
    send(client, "sleep.log", id=night, slept_at=at(-9), woke_at=at(-1.5), quality=4, note="醒了一次")
    state = client.get("/api/v1/snapshot").json()
    assert len(state["sleeps"]) == 1 and state["sleeps"][0]["quality"] == 4
    # Future times and overlaps are refused; impossible lengths fail validation.
    send(client, "sleep.log", expect=422, id=str(uuid4()), slept_at=at(1))
    send(client, "sleep.log", expect=409, id=str(uuid4()), slept_at=at(-8), woke_at=at(-7))
    send(client, "sleep.log", expect=422, id=str(uuid4()), slept_at=at(-30), woke_at=at(-31))
    send(client, "sleep.log", id=str(uuid4()), slept_at=at(-1), woke_at=at(-0.5))  # a nap
    report = client.get("/api/v1/reports/2026-10-19").json()
    assert "## 睡眠" in report["markdown"]
    assert "00:00 入睡，07:30 醒来，共 7 小时 30 分，自评 4/5" in report["markdown"]
    send(client, "sleep.delete", id=night)
    assert len(client.get("/api/v1/snapshot").json()["sleeps"]) == 1
