"""Explicit extensions preserve observed intervals and leave unknown gaps empty."""
from datetime import timedelta

from .domain import DomainError, close_interval, event_time, find, parse, stamp


def extend_session(state, data, now):
    session = find(state, "sessions", data["id"])
    task = find(state, "tasks", session["task_id"])
    if task["state"] in ("done", "cancelled", "waiting"):
        raise DomainError("请先确认任务可继续投入", "INVALID_TRANSITION")
    at = event_time(data.get("occurred_at"), now, session["last_event_at"])
    end = parse(session["expected_end_at"])
    if session["state"] == "running" and at >= end:
        close_interval(session, end)
        session.update(state="awaiting_feedback", ended_by="timer", actual_end_at=stamp(end))
    if session["state"] == "awaiting_feedback":
        if session.get("ended_by") != "timer" or at > end + timedelta(minutes=30):
            raise DomainError("这段已结束，请记录结果后安排下一段", "INVALID_TRANSITION")
        if any(s["id"] != session["id"] and s["state"] in ("running", "paused") for s in state["sessions"]):
            raise DomainError("已有另一段正在进行，请先结束它", "ACTIVE_SESSION")
        if at <= end:
            # The user extended before the timer, but the offline event arrived later.
            session["intervals"][-1]["end_at"] = None
        else:
            session["intervals"].append({"start_at": stamp(at), "end_at": None})
        session.update(state="running", actual_end_at=None)
        session.pop("ended_by", None)
        end = max(end, at)
    elif session["state"] not in ("running", "paused"):
        raise DomainError("已提交结果的执行段不能续时", "INVALID_TRANSITION")
    block = find(state, "blocks", session["block_id"])
    base_seconds = int((parse(block["end_at"]) - parse(block["start_at"])).total_seconds())
    session["planned_seconds"] = session.get("planned_seconds", base_seconds) + data["minutes"] * 60
    session["extension_minutes"] = session.get("extension_minutes", 0) + data["minutes"]
    session["expected_end_at"] = stamp(end + timedelta(minutes=data["minutes"]))
    session["last_event_at"] = stamp(at)
    session["version"] += 1
    if task["state"] != "in_progress":
        task["state"] = "in_progress"
        task["version"] += 1
    return session
