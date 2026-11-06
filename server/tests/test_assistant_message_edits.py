"""Chat messages can be deleted, withdrawn with what they changed, or corrected."""
from datetime import timedelta

from test_assistant import model, client, configure, NOW, send  # noqa: F401  (fixtures)

SLOT = {"type": "schedule_task", "task": "t1", "start_local": "2026-10-19 14:00", "minutes": 60}


def history(client):
    return client.get("/api/v1/assistant/messages").json()["messages"]


def scheduled(client):
    return [b for b in client.get("/api/v1/snapshot").json()["blocks"] if b["status"] == "scheduled"]


def say(client, text):
    response = client.post("/api/v1/assistant/messages", json={"text": text})
    assert response.status_code == 200, response.text
    return response.json()["messages"]


def plan(model, reply="排好了。", action=SLOT):
    model.replies.append((200, {"reply": reply, "drafts": [{"summary": "排一段", "actions": [action]}]}))


def scheduling_turn(client, model, text="下午排一小时实验"):
    send(client, "task.create", title="实验", outcome_criteria="报告", remaining_minutes=60)
    plan(model)
    return say(client, text)


def test_deleting_a_message_leaves_the_rest_of_the_chat_and_the_schedule(client, model):
    configure(client, confirm_first=False)
    user, reply = scheduling_turn(client, model)
    assert client.post(f"/api/v1/assistant/messages/{user['id']}/delete").status_code == 200
    assert [m["id"] for m in history(client)] == [reply["id"]]
    assert len(scheduled(client)) == 1


def test_a_deleted_message_no_longer_reaches_the_model(client, model):
    configure(client, confirm_first=False)
    user, reply = say(client, "暗号是蓝色风筝")
    for message in (user, reply):
        assert client.post(f"/api/v1/assistant/messages/{message['id']}/delete").status_code == 200
    say(client, "你好")
    assert "蓝色风筝" not in model.requests[-1].content.decode()


def test_deleting_a_reply_retires_its_waiting_draft(client, model):
    configure(client, confirm_first=True)
    _, reply = scheduling_turn(client, model)
    draft = reply["drafts"][0]
    assert draft["status"] == "pending"
    assert client.post(f"/api/v1/assistant/messages/{reply['id']}/delete").status_code == 200
    assert client.post(f"/api/v1/assistant/drafts/{draft['id']}/apply").status_code >= 400
    assert scheduled(client) == []


def test_withdrawing_removes_the_turn_and_undoes_what_it_changed(client, model):
    configure(client, confirm_first=False)
    user, reply = scheduling_turn(client, model)
    assert reply["drafts"][0]["status"] == "applied"
    assert len(scheduled(client)) == 1
    response = client.post(f"/api/v1/assistant/messages/{user['id']}/withdraw")
    assert response.status_code == 200, response.text
    assert response.json()["undone"] == 1
    assert history(client) == []
    assert scheduled(client) == []


def test_withdrawing_undoes_every_change_of_the_turn(client, model):
    configure(client, confirm_first=False)
    send(client, "task.create", title="实验", outcome_criteria="报告", remaining_minutes=60)
    later = {**SLOT, "start_local": "2026-10-19 16:00"}
    model.replies.append((200, {"reply": "排了两段。", "drafts": [
        {"summary": "第一段", "actions": [SLOT]}, {"summary": "第二段", "actions": [later]}]}))
    user, reply = say(client, "排两段")
    assert [d["status"] for d in reply["drafts"]] == ["applied", "applied"]
    assert len(scheduled(client)) == 2
    assert client.post(f"/api/v1/assistant/messages/{user['id']}/withdraw").json()["undone"] == 2
    assert scheduled(client) == []


def test_withdrawing_retires_a_waiting_draft(client, model):
    configure(client, confirm_first=True)
    user, reply = scheduling_turn(client, model)
    assert client.post(f"/api/v1/assistant/messages/{user['id']}/withdraw").status_code == 200
    assert history(client) == []
    assert client.post(f"/api/v1/assistant/drafts/{reply['drafts'][0]['id']}/apply").status_code >= 400
    assert scheduled(client) == []


def test_withdrawing_keeps_everything_when_the_schedule_moved_on(client, model):
    configure(client, confirm_first=False)
    user, reply = scheduling_turn(client, model)
    [block] = scheduled(client)
    moved = NOW + timedelta(hours=8)
    send(client, "block.move", id=block["id"], version=block["version"], start_at=moved.isoformat(),
         end_at=(moved + timedelta(hours=1)).isoformat())
    response = client.post(f"/api/v1/assistant/messages/{user['id']}/withdraw")
    assert response.status_code == 409
    assert "没法" in response.json()["message"]
    assert [m["id"] for m in history(client)] == [user["id"], reply["id"]]
    assert history(client)[-1]["drafts"][0]["status"] == "applied"
    assert len(scheduled(client)) == 1


def test_a_partly_undoable_turn_changes_nothing(client, model):
    configure(client, confirm_first=False)
    send(client, "task.create", title="实验", outcome_criteria="报告", remaining_minutes=60)
    later = {**SLOT, "start_local": "2026-10-19 16:00"}
    model.replies.append((200, {"reply": "排了两段。", "drafts": [
        {"summary": "第一段", "actions": [SLOT]}, {"summary": "第二段", "actions": [later]}]}))
    user, reply = say(client, "排两段")
    with client.app.state.store.connect() as conn:
        conn.execute("DELETE FROM assistant_undo WHERE draft_id=?", (reply["drafts"][0]["id"],))
    assert client.post(f"/api/v1/assistant/messages/{user['id']}/withdraw").status_code == 409
    assert len(scheduled(client)) == 2
    assert len(history(client)) == 2


def test_withdrawing_closes_the_question_the_turn_asked(client, model):
    configure(client, confirm_first=False)
    model.replies.append((200, {"reply": "", "drafts": [], "question": {
        "text": "上午还是下午？", "options": ["上午", "下午"]}}))
    user, _ = say(client, "排一下")
    assert client.post(f"/api/v1/assistant/messages/{user['id']}/withdraw").status_code == 200
    say(client, "你好")
    assert "上午还是下午" not in model.requests[-1].content.decode()


def test_only_your_own_words_can_be_withdrawn_or_edited(client, model):
    configure(client, confirm_first=False)
    _, reply = say(client, "你好")
    assert client.post(f"/api/v1/assistant/messages/{reply['id']}/withdraw").status_code == 422
    response = client.post(f"/api/v1/assistant/messages/{reply['id']}/edit", json={"text": "改"})
    assert response.status_code == 422
    assert len(history(client)) == 2


def test_editing_replaces_the_last_turn_and_its_change(client, model):
    configure(client, confirm_first=False)
    user, _ = scheduling_turn(client, model, "排到下午两点")
    plan(model, "改到四点了。", {**SLOT, "start_local": "2026-10-19 16:00"})
    response = client.post(f"/api/v1/assistant/messages/{user['id']}/edit", json={"text": "排到下午四点"})
    assert response.status_code == 200, response.text
    messages = history(client)
    assert [m["text"] for m in messages][0] == "排到下午四点"
    assert all("两点" not in m["text"] for m in messages)
    assert response.json()["messages"][-1]["id"] == messages[-1]["id"]
    assert "排到下午两点" not in model.requests[-1].content.decode()
    [block] = scheduled(client)
    assert block["start_at"].startswith("2026-10-19T23:00")  # 16:00 Los Angeles


def test_only_the_last_message_can_be_edited(client, model):
    configure(client, confirm_first=False)
    first, _ = say(client, "第一句")
    say(client, "第二句")
    response = client.post(f"/api/v1/assistant/messages/{first['id']}/edit", json={"text": "改"})
    assert response.status_code == 409
    assert [m["text"] for m in history(client) if m["role"] == "user"] == ["第一句", "第二句"]


def test_editing_keeps_the_original_when_its_change_cannot_be_undone(client, model):
    configure(client, confirm_first=False)
    user, reply = scheduling_turn(client, model)
    [block] = scheduled(client)
    moved = NOW + timedelta(hours=8)
    send(client, "block.move", id=block["id"], version=block["version"], start_at=moved.isoformat(),
         end_at=(moved + timedelta(hours=1)).isoformat())
    calls = len(model.requests)
    response = client.post(f"/api/v1/assistant/messages/{user['id']}/edit", json={"text": "改"})
    assert response.status_code == 409
    assert len(model.requests) == calls
    assert [m["id"] for m in history(client)] == [user["id"], reply["id"]]


def test_another_accounts_message_is_out_of_reach(client, model):
    configure(client, confirm_first=False)
    with client.app.state.store.connect() as conn:
        conn.execute("INSERT INTO assistant_messages VALUES(?,?,?,?,?)",
                     ("theirs", "user", "别人的话", NOW.isoformat(), "someone-else"))
    for action, body in (("delete", {}), ("withdraw", {}), ("edit", {"text": "改"})):
        assert client.post(f"/api/v1/assistant/messages/theirs/{action}", json=body).status_code == 404
    with client.app.state.store.connect() as conn:
        assert conn.execute("SELECT COUNT(*) FROM assistant_messages WHERE id='theirs'").fetchone()[0] == 1
