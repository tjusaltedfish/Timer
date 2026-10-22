"""v2 accounts: login, session, password and device endpoints."""
import pytest
from fastapi.testclient import TestClient

from app import auth
from app.domain import DomainError
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


def make_user(app, username="shidi", password=PASSWORD, **extra):
    with app.state.store.connect() as conn:
        user = auth.create_user(
            conn,
            username=username,
            password=password,
            display_name=extra.pop("display_name", "师弟"),
            **extra,
        )
        app.state.store.save(conn, app.state.store.initial_state(), user["id"])
    return user


def login(client, username, password=PASSWORD, platform="android"):
    return client.post(
        "/api/v1/auth/login",
        json={"username": username, "password": password, "device": {"name": "手机", "platform": platform}},
    )


def bearer(token):
    return {"Authorization": "Bearer " + token}


def test_login_persists_and_me_returns_the_account(client, app):
    user = make_user(app)
    response = login(client, "shidi")
    assert response.status_code == 200, response.text
    data = response.json()
    token = data["token"]
    assert data["user"]["username"] == "shidi"
    assert data["user"]["id"] == user["id"]
    assert "password_hash" not in data["user"]
    assert "token_hash" not in data["device"]
    me = client.get("/api/v1/me", headers=bearer(token))
    assert me.status_code == 200
    assert me.json()["user"]["display_name"] == "师弟"
    assert me.json()["user"]["onboarding"]["step"] == 0


def test_wrong_credentials_are_rejected_without_user_enumeration(client, app):
    make_user(app)
    wrong = login(client, "shidi", "nope-nope-nope")
    missing = login(client, "ghost", "nope-nope-nope")
    assert wrong.status_code == missing.status_code == 401
    assert wrong.json()["code"] == missing.json()["code"] == "AUTH_FAILED"


def test_snapshot_and_me_need_a_valid_token(client):
    assert client.get("/api/v1/snapshot", headers={"Authorization": "Bearer wrong"}).status_code == 401
    assert client.get("/api/v1/me", headers={"Authorization": ""}).status_code == 401


def test_logout_revokes_the_device(client, app):
    make_user(app)
    token = login(client, "shidi").json()["token"]
    assert client.post("/api/v1/auth/logout", headers=bearer(token)).status_code == 200
    assert client.get("/api/v1/me", headers=bearer(token)).status_code == 401


def test_password_change_keeps_current_device_and_revokes_others(client, app):
    make_user(app)
    first = login(client, "shidi").json()["token"]
    second = login(client, "shidi").json()["token"]
    changed = client.post(
        "/api/v1/me/password",
        json={"current_password": PASSWORD, "new_password": "another-good-1"},
        headers=bearer(first),
    )
    assert changed.status_code == 200, changed.text
    assert client.get("/api/v1/me", headers=bearer(second)).status_code == 401
    assert client.get("/api/v1/me", headers=bearer(first)).status_code == 200
    assert login(client, "shidi", PASSWORD).status_code == 401
    assert login(client, "shidi", "another-good-1").status_code == 200


def test_profile_patch_validation_and_device_management(client, app):
    make_user(app)
    started = login(client, "shidi")
    token, device = started.json()["token"], started.json()["device"]
    patched = client.patch(
        "/api/v1/me", json={"display_name": "师弟", "timezone": "Asia/Shanghai"}, headers=bearer(token)
    )
    assert patched.status_code == 200
    assert patched.json()["user"]["timezone"] == "Asia/Shanghai"
    assert client.patch("/api/v1/me", json={"timezone": "Mars/Base"}, headers=bearer(token)).status_code == 422
    assert client.delete(f"/api/v1/me/devices/{device['id']}", headers=bearer(token)).status_code == 409
    other = login(client, "shidi", platform="windows").json()["device"]
    assert client.delete(f"/api/v1/me/devices/{other['id']}", headers=bearer(token)).status_code == 200
    listed = client.get("/api/v1/me/devices", headers=bearer(token)).json()["devices"]
    assert [row["id"] for row in listed if not row["revoked"]] == [device["id"]]


def test_account_rules_reject_bad_usernames_and_weak_passwords(client, app):
    with app.state.store.connect() as conn:
        with pytest.raises(DomainError) as weak:
            auth.create_user(conn, username="okname", password="short")
        assert weak.value.code == "WEAK_PASSWORD"
        with pytest.raises(DomainError) as bad_name:
            auth.create_user(conn, username="有空格 的名字", password=PASSWORD)
        assert bad_name.value.code == "INVALID_USERNAME"
        auth.create_user(conn, username="taken", password=PASSWORD)
    duplicate = None
    with app.state.store.connect() as conn:
        with pytest.raises(DomainError) as duplicate:
            auth.create_user(conn, username="taken", password=PASSWORD)
    assert duplicate.value.code == "USERNAME_TAKEN"


def test_login_attempts_are_rate_limited(client, app):
    make_user(app)
    attempts = [login(client, "shidi", "wrong-pass-1") for _ in range(10)]
    assert {response.status_code for response in attempts} == {401}
    assert login(client, "shidi", PASSWORD).status_code == 429


def register(client, username="newbie", password=PASSWORD, **extra):
    payload = {
        "username": username,
        "password": password,
        "display_name": extra.pop("display_name", "新同学"),
        "device": {"name": "新手机", "platform": "android"},
        **extra,
    }
    return client.post("/api/v1/auth/register", json=payload)


def test_registration_is_closed_until_the_owner_opens_it(client, app):
    closed = register(client)
    assert closed.status_code == 403, closed.text
    assert closed.json()["code"] == "REGISTRATION_CLOSED"


def test_registration_opens_with_the_admin_switch(client, app):
    with app.state.store.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        auth.set_registration(conn, True)
    created = register(client, username="newbie")
    assert created.status_code == 200, created.text
    body = created.json()
    assert body["user"]["username"] == "newbie"
    assert body["user"]["role"] == "member"
    token = body["token"]
    # The new account gets its own document and cannot see the owner's.
    snapshot = client.get("/api/v1/snapshot", headers=bearer(token)).json()
    assert snapshot["tasks"] == []
    assert snapshot["settings"]["timezone"] == "Asia/Shanghai"
    assert login(client, "newbie").status_code == 200
    # Closing the switch stops further sign-ups.
    with app.state.store.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        auth.set_registration(conn, False)
    assert register(client, username="stranger").status_code == 403


def test_first_registrant_on_an_empty_server_becomes_admin(client, app):
    with app.state.store.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("DELETE FROM users")
        conn.execute("DELETE FROM user_state")
        conn.execute("DELETE FROM devices")
    created = register(client, username="founder", display_name="站长")
    assert created.status_code == 200, created.text
    assert created.json()["user"]["role"] == "admin"
    me = client.get("/api/v1/me", headers=bearer(created.json()["token"]))
    assert me.json()["user"]["username"] == "founder"


def test_registration_rejects_bad_names_and_weak_passwords(client, app):
    with app.state.store.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        auth.set_registration(conn, True)
    assert register(client, username="a").status_code == 422
    assert register(client, password="short").status_code == 422
    assert register(client, username="has space").status_code == 422
    make_user(app, username="taken")
    assert register(client, username="taken").status_code == 409

