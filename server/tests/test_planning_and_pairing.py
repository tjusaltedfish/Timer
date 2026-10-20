from datetime import datetime, timedelta, timezone

from test_workflow import client, new_task, send, operation, block


def test_pairing_is_one_time_and_revocable(client):
    code = client.post("/api/v1/pairing/code").json()["code"]
    paired = client.post("/api/v1/pairing/confirm", json={"code": code, "name": "OPPO"})
    assert paired.status_code == 200
    phone = paired.json()
    assert client.post("/api/v1/pairing/confirm", json={"code": code, "name": "again"}).status_code == 401
    headers = {"Authorization": "Bearer " + phone["token"]}
    assert client.get("/api/v1/snapshot", headers=headers).status_code == 200
    assert client.post("/api/v1/pairing/code", headers=headers).status_code == 403
    assert client.post(f"/api/v1/devices/{phone['device_id']}/revoke").status_code == 200
    assert client.get("/api/v1/snapshot", headers=headers).status_code == 401


def test_replan_preserves_hard_blocks_and_reports_overload(client):
    start = datetime.now(timezone.utc) + timedelta(days=2)
    start = start.replace(hour=16, minute=0, second=0, microsecond=0)  # 09:00 PDT
    code = new_task(client)
    learn = new_task(client, "算法")
    fixed = block(client, learn["id"], start + timedelta(hours=1), duration=60, kind="fixed")
    protected = send(client, "block.create", title="用餐", kind="protected", start_at=(start+timedelta(hours=2)).isoformat(), end_at=(start+timedelta(hours=3)).isoformat())["entity"]
    proposal = client.post("/api/v1/plan/proposals", json={"task_id": code["id"], "from_at": start.isoformat(), "until_at": (start+timedelta(minutes=90)).isoformat()})
    assert proposal.status_code == 200, proposal.text
    plan = proposal.json()
    assert sum(b["duration_minutes"] for b in plan["new_blocks"]) == 60
    send(client, "plan.apply", proposal_id=plan["id"])
    snapshot = client.get("/api/v1/snapshot").json()
    for original in [fixed, protected]:
        assert next(b for b in snapshot["blocks"] if b["id"] == original["id"]) == original
    huge = new_task(client, "放不下的任务")
    send(client, "task.update", id=huge["id"], version=huge["version"], remaining_minutes=600)
    overloaded = client.post("/api/v1/plan/proposals", json={"task_id": huge["id"], "from_at": start.isoformat(), "until_at": (start+timedelta(hours=3)).isoformat()}).json()
    assert overloaded["unscheduled_items"]
    for b in overloaded["new_blocks"]:
        assert b["end_at"] <= fixed["start_at"] or b["start_at"] >= protected["end_at"]


def test_stale_proposal_rejected_atomically_and_undo(client):
    task = new_task(client)
    start = (datetime.now(timezone.utc) + timedelta(days=3)).replace(hour=16, minute=0)
    request = {"task_id": task["id"], "from_at": start.isoformat(), "until_at": (start+timedelta(hours=4)).isoformat()}
    proposal = client.post("/api/v1/plan/proposals", json=request).json()
    new_task(client, "发生变化")
    assert client.post("/api/v1/operations", json=operation("plan.apply", proposal_id=proposal["id"])).status_code == 409
    assert not client.get("/api/v1/snapshot").json()["blocks"]
    fresh = client.post("/api/v1/plan/proposals", json=request).json()
    send(client, "plan.apply", proposal_id=fresh["id"])
    assert any(b["status"] == "scheduled" for b in client.get("/api/v1/snapshot").json()["blocks"])
    send(client, "plan.undo", proposal_id=fresh["id"])
    assert not any(b["status"] == "scheduled" for b in client.get("/api/v1/snapshot").json()["blocks"])


def test_unfinished_dependency_is_not_assumed_done(client):
    predecessor = new_task(client, "准备实验")
    dependent = send(client, "task.create", title="开展实验", outcome_criteria="记录结果", remaining_minutes=45, dependency_ids=[predecessor["id"]])["entity"]
    start = (datetime.now(timezone.utc) + timedelta(days=1)).replace(hour=16, minute=0)
    response = client.post("/api/v1/plan/proposals", json={"task_id": dependent["id"], "from_at": start.isoformat(), "until_at": (start+timedelta(hours=4)).isoformat()}).json()
    assert not response["new_blocks"]
    assert response["unscheduled_items"][0]["reason"]



def test_pairing_limit_counts_each_tunnel_caller_separately(tmp_path):
    from fastapi.testclient import TestClient
    from app.main import create_app
    app = create_app(tmp_path, background=False)
    with TestClient(app, client=("127.0.0.1", 50000)) as client:
        for _ in range(10):
            client.post("/api/v1/pairing/confirm", json={"code": "AAAAAAAA", "name": "x"},
                        headers={"cf-connecting-ip": "203.0.113.5"})
        blocked = client.post("/api/v1/pairing/confirm", json={"code": "AAAAAAAA", "name": "x"},
                              headers={"cf-connecting-ip": "203.0.113.5"})
        other = client.post("/api/v1/pairing/confirm", json={"code": "AAAAAAAA", "name": "x"},
                            headers={"cf-connecting-ip": "198.51.100.7"})
        assert blocked.status_code == 429 and other.status_code == 401
