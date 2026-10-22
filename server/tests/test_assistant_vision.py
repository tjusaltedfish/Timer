"""Pictures and models that cannot see them.

The assistant used to forward every image to the model regardless of what the
model supports, so a text-only model would answer about a picture it never
saw. The config now carries a "vision" switch; with it off, the picture is
answered in words instead of pretending.
"""
import asyncio

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import create_app

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 128


class FakeModel:
    def __init__(self):
        self.requests = []
        self.reply = {"reply": "看到了，是课表。", "drafts": []}

    def __call__(self, request):
        self.requests.append(request)
        body = {"choices": [{"message": {"content": __import__("json").dumps(self.reply)}}]}
        return httpx.Response(200, json=body, request=request)


@pytest.fixture()
def app(tmp_path):
    model = FakeModel()
    application = create_app(
        tmp_path, llm_transport=httpx.MockTransport(model), background=False
    )
    application.state.model = model
    return application


@pytest.fixture()
def client(app):
    with TestClient(app) as value:
        value.headers["Authorization"] = "Bearer " + app.state.desktop_token
        yield value


def configure(client, **extra):
    payload = {
        "base_url": "https://api.deepseek.com",
        "model": "deepseek-v4-flash",
        "api_key": "sk-test-1234567890",
        **extra,
    }
    response = client.post("/api/v1/assistant/config", json=payload)
    assert response.status_code == 200, response.text
    return response.json()


def test_pictures_get_words_back_when_vision_is_off(client, app):
    configure(client)
    rows = asyncio.run(app.state.assistant.converse("看看这张图", image=("image/png", PNG)))
    answer = rows[-1]["text"]
    assert "看不了图" in answer
    assert app.state.model.requests == []  # no tokens spent pretending


def test_pictures_reach_the_model_once_vision_is_on(client, app):
    assert configure(client, vision=True)["vision"] is True
    rows = asyncio.run(app.state.assistant.converse("看看这张图", image=("image/png", PNG)))
    assert "看到了" in rows[-1]["text"]
    assert len(app.state.model.requests) == 1
    body = app.state.model.requests[0].content.decode("utf-8")
    assert "image_url" in body and "base64" in body


def test_vision_switch_survives_a_config_round_trip(client, app):
    configure(client, vision=True)
    assert client.get("/api/v1/assistant/config").json()["vision"] is True
    assert configure(client, vision=False)["vision"] is False
    assert client.get("/api/v1/assistant/config").json()["vision"] is False
