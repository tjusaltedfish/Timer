import json

from test_workflow import client, operation, send


def test_each_same_day_revision_keeps_a_distinct_archive_and_retry_is_idempotent(client):
    day = "2026-10-19"
    entries = []
    for number in range(1, 4):
        request = operation("review.save", date=day, text=f"第 {number} 次回顾")
        first = client.post("/api/v1/operations", json=request)
        assert first.status_code == 200
        assert client.post("/api/v1/operations", json=request).json() == first.json()
        entries.append(first.json()["entity"])
    assert [entry["version"] for entry in entries] == [1, 2, 3]
    folder = client.app.state.store.directory / "archives"
    for number in range(1, 4):
        original = json.loads((folder / "versions" / f"{day}-v{number}.json").read_text(encoding="utf-8"))
        assert original["text"] == f"第 {number} 次回顾"
    assert json.loads((folder / f"{day}.json").read_text(encoding="utf-8"))["original"] == "第 3 次回顾"
    assert len(client.get("/api/v1/snapshot").json()["reviews"]) == 3
    assert send(client, "review.save", date="2026-10-20", text="另一日")["entity"]["version"] == 1


def test_next_version_follows_the_largest_existing_version_including_legacy_duplicates(client):
    store = client.app.state.store
    with store.connect() as conn:
        state = store.state(conn)
        state["reviews"] = [{"id": str(i), "date": "2026-10-19", "version": v} for i, v in enumerate([1, 2, 2])]
        store.save(conn, state)
    assert send(client, "review.save", date="2026-10-19", text="继续回顾")["entity"]["version"] == 3
