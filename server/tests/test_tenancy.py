"""v2 tenancy: one account can never read or change another account's data."""
import pytest
from fastapi.testclient import TestClient
from uuid import uuid4

from app import auth
from app.main import create_app

PASSWORD = "correct-horse-9"


@pytest.fixture
def app(tmp_path):
    return create_app(tmp_path)


@pytest.fixture
def client(app):
    with TestClient(app) as value:
        value.headers["Authorization"] = "Bearer " + app.state.desktop_token
        yield value


def make_user(app, username="shidi", password=PASSWORD):
    with app.state.store.connect() as conn:
        user = auth.create_user(conn, username=username, password=password, display_name=username)
        app.state.store.save(conn, app.state.store.initial_state(), user["id"])
    return user


def login(client, username, password=PASSWORD):
    response = client.post(
        "/api/v1/auth/login",
        json={"username": username, "password": password, "device": {"name": "手机", "platform": "android"}},
    )
    assert response.status_code == 200, response.text
    return response.json()["token"]


def bearer(token):
    return {"Authorization": "Bearer " + token}


def operation(kind, **payload):
    return {"operation_id": str(uuid4()), "kind": kind, "payload": payload}


def create_task(client, title, token=None):
    headers = bearer(token) if token else None
    response = client.post(
        "/api/v1/operations",
        json=operation("task.create", title=title, outcome_criteria="完成", remaining_minutes=30),
        headers=headers,
    )
    assert response.status_code == 200, response.text
    return response.json()["entity"]


def test_each_account_has_its_own_schedule(client, app):
    make_user(app)
    owner_task = create_task(client, "我的任务")
    member_token = login(client, "shidi")
    member_snapshot = client.get("/api/v1/snapshot", headers=bearer(member_token)).json()
    assert member_snapshot["tasks"] == []
    member_task = create_task(client, "师弟任务", member_token)
    assert member_task["id"] != owner_task["id"]
    mine = client.get("/api/v1/snapshot", headers=bearer(member_token)).json()
    assert [task["title"] for task in mine["tasks"]] == ["师弟任务"]
    owners = client.get("/api/v1/snapshot").json()
    assert [task["title"] for task in owners["tasks"]] == ["我的任务"]


def test_cross_account_task_ids_are_not_found(client, app):
    make_user(app)
    owner_task = create_task(client, "我的任务")
    member_token = login(client, "shidi")
    stolen = client.post(
        "/api/v1/operations",
        json=operation("task.update", id=owner_task["id"], version=owner_task["version"], title="偷改"),
        headers=bearer(member_token),
    )
    assert stolen.status_code == 404, stolen.text
    assert client.get("/api/v1/snapshot").json()["tasks"][0]["title"] == "我的任务"


def test_operation_id_reuse_across_accounts_is_rejected(client, app):
    make_user(app)
    request = operation("task.create", title="甲的任务", outcome_criteria="完成", remaining_minutes=20)
    assert client.post("/api/v1/operations", json=request).status_code == 200
    member_token = login(client, "shidi")
    reused = client.post("/api/v1/operations", json=request, headers=bearer(member_token))
    assert reused.status_code == 409
    assert reused.json()["code"] == "OPERATION_ID_REUSED"


def test_members_cannot_use_the_owner_only_assistant_and_channels(client, app):
    make_user(app)
    member_token = login(client, "shidi")
    blocked = [
        client.get("/api/v1/wechat/config", headers=bearer(member_token)),
        client.get("/api/v1/qq/config", headers=bearer(member_token)),
        client.post("/api/v1/assistant/messages", json={"text": "你好"}, headers=bearer(member_token)),
    ]
    assert [response.status_code for response in blocked] == [403, 403, 403]
    assert blocked[0].json()["code"] == "OWNER_ONLY"


def test_legacy_desktop_token_is_the_owner_account(client, app):
    snapshot = client.get("/api/v1/snapshot").json()
    assert snapshot["device"]["id"] == "desktop"
    me = client.get("/api/v1/me").json()["user"]
    assert me["role"] == "admin"
    assert me["username"] == "me"


def test_member_data_survives_a_restart(tmp_path):
    app = create_app(tmp_path)
    with TestClient(app) as client:
        client.headers["Authorization"] = "Bearer " + app.state.desktop_token
        make_user(app)
        token = login(client, "shidi")
        create_task(client, "重启也要在", token)
    restarted = create_app(tmp_path)
    with TestClient(restarted) as client:
        snapshot = client.get("/api/v1/snapshot", headers=bearer(token)).json()
        assert [task["title"] for task in snapshot["tasks"]] == ["重启也要在"]
