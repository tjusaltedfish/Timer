"""记忆去重：同一句话换个标点不该变成两条；一轮最多两条（plan §9.4）。"""
import json
from datetime import datetime, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from app import assistant
from app.main import create_app

NOW = datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)  # 09:00 in Los Angeles


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
            "api_key": "sk-test-0123456789abcdef", "confirm_first": False})
        yield value


def say(client, model, text, remember):
    model.replies.append((200, {"reply": "记住了。", "drafts": [], "remember": remember}))
    response = client.post("/api/v1/assistant/messages", json={"text": text})
    assert response.status_code == 200, response.text
    return response.json()["messages"][-1]


def memories(client):
    return [m["text"] for m in client.get("/api/v1/snapshot").json().get("memories", [])]


def test_the_same_preference_with_new_punctuation_does_not_duplicate(client, model):
    say(client, model, "记一下：我喜欢早上学习", ["我喜欢早上学习"])
    say(client, model, "再说一遍，我的习惯是早上学东西", ["我喜欢早上 学习。"])
    assert memories(client) == ["我喜欢早上学习"]


def test_a_turn_can_add_at_most_two_memories(client, model):
    say(client, model, "记几件事", ["我早上效率最高", "番茄钟二十五分钟", "不喜欢开会"])
    assert memories(client) == ["我早上效率最高", "番茄钟二十五分钟"]


def test_punctuation_only_is_not_a_memory(client, model):
    say(client, model, "记一下", ["。。。", " ，"])
    assert memories(client) == []
