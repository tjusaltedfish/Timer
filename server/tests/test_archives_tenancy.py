"""归档目录按账号隔离：同一天的两份复盘不能互相覆盖（plan §11 P1 ⚠）。"""
from datetime import datetime, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from test_assistant import model  # noqa: F401  (fixture shared with other suites)

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


def make_user(app, username):
    with app.state.store.connect() as conn:
        user = auth.create_user(conn, username=username, password=PASSWORD, display_name=username)
        app.state.store.save(conn, app.state.store.initial_state(), user["id"])
    return user


def login(client, username):
    response = client.post(
        "/api/v1/auth/login",
        json={"username": username, "password": PASSWORD, "device": {"name": "手机", "platform": "android"}},
    )
    assert response.status_code == 200, response.text
    return response.json()["token"]


def review(client, token, text):
    day = datetime.now(timezone.utc).date().isoformat()
    response = client.post(
        "/api/v1/operations",
        json={"operation_id": f"review-{token[:8]}-{day}", "kind": "review.save", "payload": {"date": day, "text": text}},
        headers={"Authorization": "Bearer " + token},
    )
    assert response.status_code == 200, response.text
    return day


def test_same_day_reviews_land_in_different_folders(app, client):
    owner_day = review(client, app.state.desktop_token, "今天是我写的复盘。")
    member = make_user(app, "shidi")
    member_day = review(client, login(client, "shidi"), "今天是他写的复盘。")
    assert owner_day == member_day

    root = app.state.store.directory / "archives"
    owner_file = root / f"{owner_day}.md"
    member_file = root / f"u-{member['id'][:8]}" / f"{member_day}.md"
    assert owner_file.exists(), list(root.iterdir())
    assert member_file.exists(), list(root.iterdir())
    assert "今天是我写的复盘" in owner_file.read_text(encoding="utf-8")
    assert "今天是他写的复盘" in member_file.read_text(encoding="utf-8")
    assert "今天是他写的复盘" not in owner_file.read_text(encoding="utf-8")
