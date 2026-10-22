"""Materials, review analyses and the weekly brief belong to one account each."""
import asyncio
from datetime import timedelta

import httpx
import pytest
from fastapi.testclient import TestClient

from test_assistant import model, NOW  # noqa: F401  (fixture)

from app import auth
from app.main import create_app

PASSWORD = "correct-horse-9"


@pytest.fixture
def app(tmp_path, model):  # noqa: F811
    return create_app(tmp_path, llm_transport=httpx.MockTransport(model))


@pytest.fixture
def client(app):
    with TestClient(app) as value:
        value.headers["Authorization"] = "Bearer " + app.state.desktop_token
        yield value


def make_user(app, username="shidi"):
    with app.state.store.connect() as conn:
        user = auth.create_user(conn, username=username, password=PASSWORD, display_name=username)
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


def upload(client, token, name="资料.txt", day="2026-10-19", text="傅里叶变换要点：采样与频谱。"):
    response = client.post(
        "/api/v1/materials/upload",
        params={"name": name, "day": day},
        content=text.encode(),
        headers=bearer(token),
    )
    assert response.status_code == 200, response.text
    return response.json()


def configure_assistant(client, token=None):
    headers = bearer(token) if token else None
    response = client.post(
        "/api/v1/assistant/config",
        json={"base_url": "https://llm.example/v1", "model": "m", "api_key": "sk-test-1234567890"},
        headers=headers,
    )
    assert response.status_code == 200, response.text


def test_material_upload_lands_only_in_the_callers_state(client, app):
    make_user(app)
    token = login(client, "shidi")
    material = upload(client, token)
    shidi = client.get("/api/v1/snapshot", headers=bearer(token)).json()
    owner = client.get("/api/v1/snapshot").json()
    assert [m["id"] for m in shidi["materials"]] == [material["id"]]
    assert owner.get("materials", []) == []


def test_review_analysis_is_stored_for_the_requester_only(client, app, model):
    make_user(app)
    token = login(client, "shidi")
    configure_assistant(client, token)
    model.replies.append((200, "今天读完了傅里叶变换那章。"))
    response = client.post(
        "/api/v1/reviews/generate",
        json={"date": "2026-10-19", "text": "今天读完了傅里叶变换那章。", "material_ids": [],
              "request_id": "shidi-review-1"},
        headers=bearer(token),
    )
    assert response.status_code == 200, response.text
    shidi = client.get("/api/v1/snapshot", headers=bearer(token)).json()
    owner = client.get("/api/v1/snapshot").json()
    assert len(shidi["analyses"]) == 1 and len(shidi["reviews"]) == 1
    assert shidi["analyses"][0]["id"] == "shidi-review-1"
    assert owner.get("analyses", []) == [] and owner.get("reviews", []) == []


def test_the_same_request_id_from_two_accounts_does_not_collide(client, app, model):
    make_user(app)
    token = login(client, "shidi")
    configure_assistant(client, token)
    configure_assistant(client, None)
    for headers in (bearer(token), None):
        model.replies.append((200, "做完了。"))
        response = client.post(
            "/api/v1/reviews/generate",
            json={"date": "2026-10-19", "text": "做完了。", "material_ids": [], "request_id": "same-001"},
            headers=headers,
        )
        assert response.status_code == 200, response.text
    shidi = client.get("/api/v1/snapshot", headers=bearer(token)).json()
    owner = client.get("/api/v1/snapshot").json()
    assert len(shidi["analyses"]) == 1 and len(owner.get("analyses", [])) == 1


def test_weekly_brief_reaches_each_accounts_own_follower(client, app):
    make_user(app)
    sunday = NOW + timedelta(days=6, hours=11, minutes=30)
    app.state.weekly.clock = lambda: sunday
    with app.state.store.connect() as conn:
        owner = conn.execute("SELECT id FROM users ORDER BY created_at").fetchone()["id"]
        shidi = conn.execute("SELECT id FROM users WHERE username='shidi'").fetchone()["id"]
        app.state.wechat.identities.bind(conn, "wechat", "owner-openid", owner, "主账号")
        app.state.wechat.identities.bind(conn, "wechat", "shidi-openid", shidi, "师弟")
    asyncio.run(app.state.weekly.run_due())
    asyncio.run(app.state.weekly.run_due())
    with app.state.store.connect() as conn:
        rows = list(conn.execute("SELECT openid, text FROM wechat_outbox ORDER BY openid, created_at"))
    owner_briefs = [r["text"] for r in rows if r["openid"] == "owner-openid" and "本周简报" in r["text"]]
    shidi_briefs = [r["text"] for r in rows if r["openid"] == "shidi-openid" and "本周简报" in r["text"]]
    assert len(owner_briefs) == 1 and len(shidi_briefs) == 1


def test_material_files_live_under_the_uploaders_folder(client, app):
    shidi = make_user(app)
    token = login(client, "shidi")
    entity = upload(client, token)
    folder = app.state.store.directory / "materials" / shidi["id"]
    assert (folder / f"{entity['id']}.source").read_bytes() == "傅里叶变换要点：采样与频谱。".encode()
    assert (folder / f"{entity['id']}.txt").is_file()
    # The owner's folder holds no trace of another account's upload.
    owner_folder = app.state.store.directory / "materials" / app.state.store.owner_id
    assert not owner_folder.exists() or not any(owner_folder.iterdir())
