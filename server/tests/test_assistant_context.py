"""「上一轮提到的」：让助手接得住「它 / 那个」（plan §9.2）。"""
import json
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
def clock():
    return [NOW]


@pytest.fixture
def model(monkeypatch):
    monkeypatch.setattr(assistant, "RETRY_DELAYS", (0, 0, 0))
    monkeypatch.delenv("PLANNER_LLM_API_KEY", raising=False)
    return FakeModel()


@pytest.fixture
def client(tmp_path, model, clock):
    app = create_app(tmp_path, clock=lambda: clock[0], llm_transport=httpx.MockTransport(model))
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
    return model.requests[-1].content.decode("utf-8")


def test_the_task_this_turn_created_is_visible_next_turn(client, model):
    model.replies.append((200, {"reply": "排上了", "drafts": [{
        "summary": "学两小时算法",
        "actions": [{"type": "schedule_new", "title": "学习算法",
                     "outcome_criteria": "跑通一个例子", "start_local": "2026-10-19 10:30",
                     "minutes": 120}]}]}))
    first = turn(client, "我要学算法，排两小时")
    assert "排上了" in first["text"] or "已照办" in first["text"]

    model.replies.append((200, {"reply": "好，改了", "drafts": []}))
    turn(client, "它再往后挪一个小时")
    prompt = sent_prompt(model)
    assert "上一轮提到的" in prompt
    assert "学习算法" in prompt


def test_what_was_mentioned_expires_after_forty_five_minutes(client, model, clock):
    model.replies.append((200, {"reply": "排上了", "drafts": [{
        "summary": "学两小时算法",
        "actions": [{"type": "schedule_new", "title": "学习算法",
                     "outcome_criteria": "跑通一个例子", "start_local": "2026-10-19 10:30",
                     "minutes": 120}]}]}))
    turn(client, "我要学算法，排两小时")

    clock[0] = NOW + timedelta(minutes=46)
    model.replies.append((200, {"reply": "好", "drafts": []}))
    turn(client, "它再往后挪一个小时")
    assert "上一轮提到的" not in sent_prompt(model)
