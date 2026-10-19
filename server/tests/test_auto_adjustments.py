from datetime import datetime, timedelta, timezone

import pytest

from test_elastic_execution import clocked
from test_workflow import block, new_task, operation, send


def calendar(clocked, start=True, duration=60):
    c, current = clocked
    origin = current[0]
    source_task = new_task(c, "代码")
    source = block(c, source_task["id"], start=origin, duration=duration)
    later = []
    for i in range(2):
        task = new_task(c, f"后续 {i}")
        later.append(block(c, task["id"], start=origin + timedelta(minutes=duration + 30 * i), duration=30))
    session = send(c, "session.start", block_id=source["id"])["entity"] if start else None
    return c, current, source, later, session


def change(c, session, minutes=15):
    return send(c, "session.extend", id=session["id"], minutes=minutes)["entity"]


def active_blocks(c):
    return [b for b in c.get("/api/v1/snapshot").json()["blocks"] if b["status"] == "scheduled"]


def test_small_ripple_moves_only_following_blocks_and_undo_keeps_execution_facts(clocked):
    c, current, source, later, session = calendar(clocked)
    extended = change(c, session)
    info = extended["adjustment"]
    assert info["status"] == "applied" and info["count"] == 2
    state = c.get("/api/v1/snapshot").json()
    plan = next(p for p in state["proposals"] if p["id"] == info["proposal_id"])
    assert plan["auto"] is True and plan["status"] == "applied"
    assert plan["applied_revision"] == state["revision"]
    for before, after in zip(later, plan["new_blocks"]):
        assert datetime.fromisoformat(after["start_at"]) == datetime.fromisoformat(before["start_at"]) + timedelta(minutes=15)
        assert after["source_block_id"] == before["id"]
    send(c, "plan.undo", proposal_id=plan["id"])
    restored = c.get("/api/v1/snapshot").json()
    assert {b["id"] for b in restored["blocks"] if b["status"] == "scheduled"} == {source["id"], *[b["id"] for b in later]}
    assert restored["sessions"][0]["expected_end_at"] == extended["expected_end_at"]
    assert restored["sessions"][0]["state"] == "running"


@pytest.mark.parametrize("disabled,minutes", [(True, 15), (False, 45)])
def test_disabled_micro_adjust_or_large_displacement_requires_confirmation(clocked, disabled, minutes):
    c, current, source, later, session = calendar(clocked)
    if disabled:
        send(c, "settings.update", auto_adjust=False)
    changed = change(c, session, minutes)
    assert changed["adjustment"]["status"] == "proposal"
    assert {b["id"] for b in active_blocks(c)} == {source["id"], *[b["id"] for b in later]}
    proposal_id = changed["adjustment"]["proposal_id"]
    send(c, "plan.apply", proposal_id=proposal_id)
    state = c.get("/api/v1/snapshot").json()
    assert next(p for p in state["proposals"] if p["id"] == proposal_id)["auto"] is False
    assert all(b["status"] == "superseded" for b in state["blocks"] if b["id"] in {x["id"] for x in later})


@pytest.mark.parametrize("kind", ["fixed", "protected", "check"])
def test_fixed_protected_or_check_barrier_blocks_the_entire_ripple(clocked, kind):
    c, current = clocked
    origin = current[0]
    source_task = new_task(c)
    source = block(c, source_task["id"], start=origin)
    movable_task = new_task(c, "可移动")
    movable = block(c, movable_task["id"], start=origin + timedelta(hours=1), duration=30)
    fixed_task = new_task(c, "预约") if kind != "protected" else None
    barrier = block(c, fixed_task["id"] if fixed_task else None,
                    start=origin + timedelta(minutes=90), duration=30, kind=kind, title="固定边界")
    session = send(c, "session.start", block_id=source["id"])["entity"]
    changed = change(c, session)
    assert changed["adjustment"]["status"] == "blocked"
    actual = active_blocks(c)
    assert next(b for b in actual if b["id"] == movable["id"])["start_at"] == movable["start_at"]
    assert next(b for b in actual if b["id"] == barrier["id"])["start_at"] == barrier["start_at"]
    assert c.post("/api/v1/operations", json=operation("plan.apply", proposal_id=changed["adjustment"]["proposal_id"])).status_code == 409


@pytest.mark.parametrize("constraint", ["day_end", "deadline", "history"])
def test_day_end_deadline_and_execution_history_are_hard_constraints(clocked, constraint):
    c, current, source, later, _ = calendar(clocked, start=False)
    if constraint == "day_end":
        send(c, "settings.update", day_end="10:30")
    elif constraint == "deadline":
        task = next(t for t in c.get("/api/v1/snapshot").json()["tasks"] if t["id"] == later[0]["task_id"])
        send(c, "task.update", id=task["id"], version=task["version"],
             deadline=(datetime.fromisoformat(later[0]["end_at"]) + timedelta(minutes=5)).isoformat())
    else:
        ahead = send(c, "session.start", block_id=later[0]["id"])["entity"]
        send(c, "session.end", id=ahead["id"])
    session = send(c, "session.start", block_id=source["id"])["entity"]
    assert change(c, session)["adjustment"]["status"] == "blocked"
    assert {b["id"] for b in active_blocks(c)} == {source["id"], *[b["id"] for b in later]}


def test_late_start_and_resume_shift_but_keep_end_does_not(clocked):
    c, current, source, later, _ = calendar(clocked, start=False)
    current[0] += timedelta(minutes=10)
    session = send(c, "session.start", block_id=source["id"], mode="keep_end")["entity"]
    assert session["adjustment"]["status"] == "none"
    send(c, "session.pause", id=session["id"])
    current[0] += timedelta(minutes=15)
    resumed = send(c, "session.resume", id=session["id"])["entity"]
    assert resumed["adjustment"]["status"] == "applied"
    send(c, "task.create", title="另一项变化", outcome_criteria="产出", remaining_minutes=15)
    assert c.post("/api/v1/operations", json=operation("plan.undo", proposal_id=resumed["adjustment"]["proposal_id"])).status_code == 409


def test_late_keep_duration_shifts_and_offline_replay_never_rewrites_the_past(clocked):
    c, current, source, later, _ = calendar(clocked, start=False)
    origin = current[0]
    current[0] += timedelta(minutes=20)
    session = send(c, "session.start", block_id=source["id"])["entity"]
    assert session["adjustment"]["status"] == "applied"
    snapshot = c.get("/api/v1/snapshot").json()
    current[0] += timedelta(hours=4)
    changed = send(c, "session.extend", id=session["id"], minutes=15,
                   occurred_at=(origin + timedelta(minutes=25)).isoformat())["entity"]
    assert changed["adjustment"]["status"] == "none"
    after = c.get("/api/v1/snapshot").json()
    assert after["blocks"] == snapshot["blocks"]


def test_regular_planner_and_manual_booking_respect_the_extended_live_interval(clocked):
    c, current = clocked
    source_task = new_task(c)
    source = block(c, source_task["id"], start=current[0])
    session = send(c, "session.start", block_id=source["id"])["entity"]
    changed = change(c, session)
    target = new_task(c, "下一件")
    start = datetime.fromisoformat(source["end_at"])
    assert c.post("/api/v1/operations", json=operation("block.create", task_id=target["id"],
                  start_at=start.isoformat(), end_at=(start + timedelta(minutes=10)).isoformat())).status_code == 409
    result = c.post("/api/v1/plan/proposals", json={"task_id":target["id"],
                   "from_at":current[0].isoformat(), "until_at":(current[0] + timedelta(hours=4)).isoformat()})
    assert result.status_code == 200
    assert result.json()["new_blocks"][0]["start_at"] == changed["expected_end_at"]


def test_ripple_preserves_actual_minutes_across_a_repeated_dst_hour(clocked):
    c, current = clocked
    current[0] = datetime(2026, 11, 1, 8, tzinfo=timezone.utc)
    send(c, "settings.update", day_start="00:00", day_end="03:00")
    source_task = new_task(c)
    source = block(c, source_task["id"], start=current[0], duration=30)
    next_task = new_task(c, "折返时刻")
    following = block(c, next_task["id"], start=current[0] + timedelta(minutes=30), duration=30)
    session = send(c, "session.start", block_id=source["id"])["entity"]
    changed = change(c, session)
    assert changed["adjustment"]["status"] == "applied"
    moved = next(b for b in active_blocks(c) if b.get("source_block_id") == following["id"])
    assert datetime.fromisoformat(moved["start_at"]) == current[0] + timedelta(minutes=45)
    assert datetime.fromisoformat(moved["end_at"]) - datetime.fromisoformat(moved["start_at"]) == timedelta(minutes=30)


def test_offline_batch_keeps_block_ids_available_for_later_queued_execution(clocked):
    c, current, source, later, session = calendar(clocked)
    changed = send(c, "session.extend", id=session["id"], minutes=15, defer_adjustment=True)["entity"]
    assert changed["adjustment"]["status"] == "proposal"
    send(c, "session.end", id=session["id"])
    send(c, "feedback.create", session_id=session["id"], choice="partial", remaining_minutes=30)
    assert send(c, "session.start", block_id=later[0]["id"], defer_adjustment=True)["entity"]["state"] == "running"


def test_a_replayed_event_does_not_automatically_move_an_unused_future_block(clocked):
    c, current, source, later, session = calendar(clocked)
    happened = current[0] + timedelta(minutes=5)
    current[0] += timedelta(minutes=6)
    changed = send(c, "session.extend", id=session["id"], minutes=15, occurred_at=happened.isoformat())["entity"]
    assert changed["adjustment"]["status"] == "proposal"
    assert {b["id"] for b in active_blocks(c)} == {source["id"], *[b["id"] for b in later]}


def test_dependency_is_still_unfinished_after_a_schedule_shift(clocked):
    c, current = clocked
    source_task = new_task(c)
    source = block(c, source_task["id"], start=current[0])
    dependent = send(c, "task.create", title="依赖当前输出", outcome_criteria="核验文件", remaining_minutes=30,
                     dependency_ids=[source_task["id"]])["entity"]
    following = block(c, dependent["id"], start=current[0] + timedelta(hours=1), duration=30)
    session = send(c, "session.start", block_id=source["id"])["entity"]
    changed = change(c, session)
    assert changed["adjustment"]["status"] == "applied"
    state = c.get("/api/v1/snapshot").json()
    moved = next(b for b in state["blocks"] if b.get("source_block_id") == following["id"])
    send(c, "session.end", id=session["id"])
    assert c.post("/api/v1/operations", json=operation("session.start", block_id=moved["id"])).status_code == 409


def test_cross_day_chain_is_left_for_manual_review(clocked):
    c, current = clocked
    current[0] = datetime(2026, 10, 20, 5, 30, tzinfo=timezone.utc)  # 22:30 previous local day
    send(c, "settings.update", day_start="00:00", day_end="23:59")
    source_task = new_task(c)
    source = block(c, source_task["id"], start=current[0], duration=60)
    target = new_task(c)
    following = block(c, target["id"], start=current[0] + timedelta(hours=1), duration=60)
    session = send(c, "session.start", block_id=source["id"])["entity"]
    assert change(c, session)["adjustment"]["status"] == "blocked"
    assert any(b["id"] == following["id"] for b in active_blocks(c))
