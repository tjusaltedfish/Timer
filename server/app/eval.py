"""意图评测：真实说法 × 固定状态，离线回放（plan §9.6）。

用法：
    PLANNER_DATA_DIR=.review-data server/.venv/Scripts/python.exe -m app.eval
    ... -m app.eval --file path/to/fixture.jsonl --verbose

离线模式把每条用例里记录的模型输出（`reply`）通过 MockTransport 喂回去，
所以衡量的不是模型智商，而是「模型这么说了，系统有没有按说的做对」——
草稿解析、时段换算、去重、护栏、失败降级都在这条链上。
"""
import argparse
import json
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4
from zoneinfo import ZoneInfo

import httpx
from fastapi.testclient import TestClient

from .main import create_app

FIXTURE = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "intent_eval.jsonl"
NOW = datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)  # 09:00 in Los Angeles
ZONE = ZoneInfo("America/Los_Angeles")
KEY = "sk-eval-0123456789abcdef"


def load(path=FIXTURE):
    text = Path(path).read_text(encoding="utf-8")
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def replay(reply):
    content = json.dumps(reply, ensure_ascii=False)

    def handler(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

    return httpx.MockTransport(handler)


def local_minutes(block):
    start = datetime.fromisoformat(block["start_at"].replace("Z", "+00:00")).astimezone(ZONE)
    end = datetime.fromisoformat(block["end_at"].replace("Z", "+00:00")).astimezone(ZONE)
    return start.strftime("%Y-%m-%d %H:%M"), int((end - start).total_seconds() // 60)


def _fill(value, names):
    """Replace "@name" strings with ids captured from earlier seeded operations."""
    if isinstance(value, str) and value.startswith("@") and value[1:] in names:
        return names[value[1:]]
    if isinstance(value, dict):
        return {k: _fill(v, names) for k, v in value.items()}
    if isinstance(value, list):
        return [_fill(v, names) for v in value]
    return value


def observe(snapshot, message):
    tasks = snapshot.get("tasks", [])
    return {
        "tasks": [task["title"] for task in tasks if task.get("state") != "cancelled"],
        "cancelled": [task["title"] for task in tasks if task.get("state") == "cancelled"],
        "blocks": [{"title": b["title"], "start_local": local_minutes(b)[0], "minutes": local_minutes(b)[1]}
                   for b in snapshot.get("blocks", []) if b.get("status") == "scheduled"],
        "memories": [m["text"] for m in snapshot.get("memories", [])],
        "answer": message.get("text", ""),
        "pending": sum(1 for draft in message.get("drafts", []) if draft.get("status") == "pending"),
        "running": sum(1 for s in snapshot.get("sessions", []) if s.get("state") in ("running", "paused")),
    }


def check(expect, seen):
    """Return the list of mismatches, empty means pass."""
    problems = []
    for key in ("tasks", "cancelled", "blocks", "memories", "pending", "running"):
        if key not in expect:
            continue
        if key == "blocks":
            got = [(b["title"], b["start_local"], b["minutes"]) for b in seen["blocks"]]
            want = [(b["title"], b["start_local"], b["minutes"]) for b in expect["blocks"]]
            if got != want:
                problems.append(f"blocks expected {want} got {got}")
        elif seen[key] != expect[key]:
            problems.append(f"{key} expected {expect[key]} got {seen[key]}")
    for piece in expect.get("answer_contains", []):
        if piece not in seen["answer"]:
            problems.append(f"answer missing {piece!r}: {seen['answer'][:120]}")
    for piece in expect.get("answer_excludes", []):
        if piece in seen["answer"]:
            problems.append(f"answer should not contain {piece!r}")
    return problems


def run_case(case, transport=None, verbose=False):
    with tempfile.TemporaryDirectory() as tmp:
        app = create_app(Path(tmp), clock=lambda: NOW, llm_transport=transport or replay(case["reply"]))
        with TestClient(app) as client:
            client.headers["Authorization"] = "Bearer " + app.state.desktop_token
            configured = client.post("/api/v1/assistant/config", json={
                "base_url": "https://relay.example/v1", "model": "deepseek-chat",
                "api_key": KEY, "confirm_first": False})
            assert configured.status_code == 200, configured.text
            names = {}
            for item in case.get("operations", []):
                payload = json.loads(json.dumps(item["payload"], ensure_ascii=False))
                payload = _fill(payload, names)
                seeded = client.post("/api/v1/operations", json={
                    "operation_id": str(uuid4()), "kind": item["kind"], "payload": payload})
                assert seeded.status_code == 200, (item["kind"], seeded.text)
                if item.get("as"):
                    names[item["as"]] = seeded.json()["entity"]["id"]
            response = client.post("/api/v1/assistant/messages", json={"text": case["input"]})
            assert response.status_code == 200, response.text
            message = response.json()["messages"][-1]
            snapshot = client.get("/api/v1/snapshot").json()
            if verbose:
                print(json.dumps(observe(snapshot, message), ensure_ascii=False))
            return message, snapshot


def evaluate(fixture=FIXTURE, verbose=False):
    cases = load(fixture)
    passed, failures = 0, []
    for case in cases:
        try:
            message, snapshot = run_case(case, verbose=verbose)
            problems = check(case["expect"], observe(snapshot, message))
        except AssertionError as error:  # fixture or pipeline blew up
            problems = [f"crashed: {error}"[:300]]
        if problems:
            failures.append((case["name"], problems))
        else:
            passed += 1
    return passed, len(cases), failures


def main(argv=None):
    parser = argparse.ArgumentParser(description="run the intent eval fixture offline")
    parser.add_argument("--file", default=str(FIXTURE))
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    passed, total, failures = evaluate(args.file, args.verbose)
    for name, problems in failures:
        print(f"FAIL {name}")
        for problem in problems:
            print(f"     {problem}")
    accuracy = 0 if not total else round(100 * passed / total, 1)
    print(f"{passed}/{total} passed ({accuracy}% aligned)")
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
