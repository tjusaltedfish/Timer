"""Clarification queue: one short question, answered on the next turn (plan §9.2)."""
import json
import sqlite3
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app import assistant
from app.main import create_app

NOW = datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)  # 09:00 in Los Angeles
SECRET = "sk-test-0123456789abcdef"


class FakeModel:
    def __init__(self):
        self.replies, self.requests = [], []

    def __call__(self, request):
        self.requests.append(request)
        status, body = self.replies.pop(0) if self.replies else (200, {"reply": "好的", "drafts": []})
        if status != 200:
            return httpx.Response(status, json={"error": {"message": "nope"}})
        content = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})


@pytest.fixture
def model(monkeypatch):
    monkeypatch.setattr(assistant, "RETRY_DELAYS", (0, 0, 0))
    monkeypatch.delenv("PLANNER_LLM_API_KEY", raising=False)
    return FakeModel()


@pytest.fixture
def client(tmp_path, model):
    app = create_app(tmp_path, clock=lambda: NOW, llm_transport=httpx.MockTransport(model))
    with TestClient(app) as value:
        value.headers["Authorization"] = "Bearer " + app.state.desktop_token
        value.post("/api/v1/assistant/config", json={
            "base_url": "https://relay.example/v1", "model": "deepseek-chat",
            "api_key": SECRET, "confirm_first": False})
        yield value


def turn(client, text):
    response = client.post("/api/v1/assistant/messages", json={"text": text})
    assert response.status_code == 200, response.text
    return response.json()["messages"][-1]


def sent_prompt(model):
    """Everything the model saw on the last request, as one searchable string."""
    return model.requests[-1].content.decode("utf-8")


def open_questions(tmp_path):
    with sqlite3.connect(tmp_path / "planner.db") as conn:
        return conn.execute(
            "SELECT text, options, expires_at FROM assistant_pending_questions WHERE answered_at IS NULL"
        ).fetchall()


def test_a_short_question_with_options_is_asked_and_remembered(client, model, tmp_path):
    model.replies.append((200, {"reply": "", "drafts": [], "question": {
        "text": "这两件先做哪个？", "options": ["写报告", "回邮件"]}}))
    answer = turn(client, "写报告和回邮件先做哪个")
    assert "这两件先做哪个？" in answer["text"]
    assert "1. 写报告" in answer["text"] and "2. 回邮件" in answer["text"]

    rows = open_questions(tmp_path)
    assert len(rows) == 1
    assert rows[0][0] == "这两件先做哪个？"
    assert json.loads(rows[0][1]) == ["写报告", "回邮件"]
    assert rows[0][2].startswith("2026-10-19T16:10")


def test_the_next_turn_carries_the_answer_context_and_closes_the_question(client, model, tmp_path):
    model.replies.append((200, {"question": {"text": "这两件先做哪个？", "options": ["写报告", "回邮件"]}}))
    turn(client, "写报告和回邮件先做哪个")

    model.replies.append((200, {"reply": "那就先写报告。", "drafts": []}))
    turn(client, "1")

    seen = sent_prompt(model)
    assert "上一轮你问过的问题" in seen
    assert "这两件先做哪个？" in seen
    assert "1. 写报告" in seen
    # answering the question closes it, so the same question is not fed back forever.
    assert open_questions(tmp_path) == []


def test_an_expired_question_is_not_pushed_into_the_next_turn(client, model, tmp_path):
    with sqlite3.connect(tmp_path / "planner.db") as conn:
        conn.execute(
            "INSERT INTO assistant_pending_questions"
            " (id, user_id, text, options, created_at, expires_at) VALUES(?,?,?,?,?,?)",
            ("old", "owner", "还做吗？", "[]",
             (NOW - timedelta(minutes=30)).isoformat(),
             (NOW - timedelta(minutes=20)).isoformat()),
        )
    # The account id is not literally "owner": use the owner row instead of guessing.
    with sqlite3.connect(tmp_path / "planner.db") as conn:
        owner = conn.execute("SELECT id FROM users WHERE role='admin' ORDER BY created_at LIMIT 1").fetchone()[0]
        conn.execute("UPDATE assistant_pending_questions SET user_id=? WHERE id='old'", (owner,))
    model.replies.append((200, {"reply": "好", "drafts": []}))
    turn(client, "随便说点什么")
    assert "还做吗？" not in sent_prompt(model)
