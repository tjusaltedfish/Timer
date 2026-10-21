"""Bounded deterministic ripple; a blocked chain never moves even its first block."""
from copy import deepcopy
from datetime import timedelta
from zoneinfo import ZoneInfo

from .domain import DomainError, find, identifier, parse, stamp, validate_block
from .planning import apply_plan


def adjust_following(state, session, now, automatic_allowed=True, end_at=None):
    """Move following flexible blocks later after a late start, extension or end.

    ``end_at`` is the real end of a session that has just been closed; without
    it the running session's projected end is used.
    """
    if session["state"] not in ("running", "awaiting_feedback"):
        return {"status": "none"}
    if end_at is not None and session["state"] != "awaiting_feedback":
        return {"status": "none"}
    source = find(state, "blocks", session["block_id"])
    end = parse(end_at or session["expected_end_at"])
    original_end = parse(source["end_at"])
    if end <= original_end or (end_at is None and end <= now):
        return {"status": "none"}
    zone = ZoneInfo(state["settings"]["timezone"])
    day = original_end.astimezone(zone).date()
    used = {s["block_id"] for s in state["sessions"]}
    live = sorted((b for b in state["blocks"] if b["status"] == "scheduled" and b["id"] != source["id"]),
                  key=lambda b: b["start_at"])
    old, new, cursor = [], [], end
    blocked = None
    for before in live:
        begin, finish = parse(before["start_at"]), parse(before["end_at"])
        if finish <= original_end:
            continue
        if begin >= cursor:
            break
        # At a real end the clock has already passed the next start; a block
        # that merely started on paper (no session) can still be moved.
        if before["id"] in used or (end_at is None and begin < now):
            blocked = f"「{before['title']}」已到时或有执行记录，需手动处理"
            break
        if before["kind"] != "flexible":
            blocked = f"遇到固定、保护或检查时段「{before['title']}」，已保留原安排"
            break
        after = {**deepcopy(before), "id": identifier(), "source_block_id": before["id"],
                 "start_at": stamp(cursor), "end_at": stamp(cursor + (finish - begin)), "version": 1}
        old.append(deepcopy(before))
        new.append(after)
        cursor = parse(after["end_at"])
    if not old and blocked is None:
        return {"status": "none"}
    if blocked is None:
        for item in new:
            a, b = parse(item["start_at"]).astimezone(zone), parse(item["end_at"]).astimezone(zone)
            if a.date() != day or b.date() != day or now.astimezone(zone).date() != day:
                blocked = "顺延会跨日，请确认后续安排"
                break
            if a.strftime("%H:%M") < state["settings"]["day_start"] or b.strftime("%H:%M") > state["settings"]["day_end"]:
                blocked = "后续时间超出作息范围，请重新安排"
                break
    if blocked is None:
        trial = deepcopy(state)
        old_ids = {b["id"] for b in old}
        for item in trial["blocks"]:
            if item["id"] in old_ids:
                item["status"] = "superseded"
        trial["blocks"].extend(deepcopy(new))
        try:
            for item in new:
                validate_block(trial, item, item["id"], now=now)
        except DomainError as error:
            blocked = error.message
    small = all(parse(b["start_at"]) - parse(a["start_at"]) <= timedelta(minutes=30) for a, b in zip(old, new))
    timely = abs((now - parse(session["last_event_at"])).total_seconds()) <= 5
    automatic = blocked is None and small and timely and automatic_allowed and state["settings"].get("auto_adjust", True)
    proposal = {
        "id": identifier(), "base_revision": state["revision"],
        "expires_at": stamp(now + timedelta(minutes=15)), "created_at": stamp(now),
        "status": "blocked" if blocked else "draft", "kind": "ripple", "auto": automatic,
        "trigger_session_id": session["id"], "old_blocks": old, "new_blocks": [] if blocked else new,
        "unscheduled_items": [{"title": source["title"], "task_id": source["task_id"],
                               "minutes": max(1, int((end - original_end).total_seconds() / 60)), "reason": blocked}] if blocked else [],
        "reason": blocked or ("同日后续弹性段每段顺延不超过 30 分钟，约束已校验。" if automatic else
                              "本次需要确认：涉及较大位移、离线重放或已关闭自动微调；确认前保留后续原安排。"),
    }
    state["proposals"].append(proposal)
    if automatic:
        apply_plan(state, proposal["id"], now)
        status = "applied"
    else:
        # The execution operation itself advances revision immediately after apply returns.
        proposal["base_revision"] = state["revision"] + 1
        status = "blocked" if blocked else "proposal"
    return {"status": status, "proposal_id": proposal["id"], "count": len(new) if not blocked else 0,
            "minutes": max(1, int((end - original_end).total_seconds() / 60)),
            "reason": proposal["reason"]}


def adjust_after_end(state, session, now, automatic_allowed=True):
    """A segment that ran over shifts what follows; one that ended early may
    offer to pull the next flexible blocks earlier, but never moves them
    without confirmation."""
    late = adjust_following(state, session, now, automatic_allowed, end_at=session.get("actual_end_at"))
    if late["status"] != "none":
        return late
    return propose_early(state, session, now)


def propose_early(state, session, now):
    """Draft a pull-earlier proposal after an explicit early end."""
    if session.get("state") != "awaiting_feedback" or session.get("ended_by") != "user":
        return {"status": "none"}
    source = find(state, "blocks", session["block_id"])
    original_end = parse(source["end_at"])
    actual_end = parse(session["actual_end_at"])
    early = original_end - actual_end
    if early < timedelta(minutes=15):
        return {"status": "none"}
    # Offline or delayed reports are history; do not reshuffle the day after the fact.
    if abs((now - parse(session["last_event_at"])).total_seconds()) > 5:
        return {"status": "none"}
    zone = ZoneInfo(state["settings"]["timezone"])
    day = original_end.astimezone(zone).date()
    if now.astimezone(zone).date() != day:
        return {"status": "none"}
    used = {s["block_id"] for s in state["sessions"]}
    live = sorted((b for b in state["blocks"] if b["status"] == "scheduled" and b["id"] != source["id"]),
                  key=lambda b: b["start_at"])
    chain, cursor = [], original_end
    for block in live:
        begin, finish = parse(block["start_at"]), parse(block["end_at"])
        if begin < original_end:
            continue
        # Only a chain that already follows this segment is a candidate; a
        # deliberate gap later in the day is not something to collapse.
        if begin - cursor > timedelta(minutes=5):
            break
        if block["kind"] != "flexible" or block["id"] in used or begin.astimezone(zone).date() != day:
            break
        chain.append(block)
        cursor = finish
    if not chain:
        return {"status": "none"}
    old, new, position = [], [], None
    for block in chain:
        begin, finish = parse(block["start_at"]), parse(block["end_at"])
        start = begin - early
        start = max(start, now) if position is None else max(start, position)
        length = finish - begin
        if start.astimezone(zone).date() != day or (start + length).astimezone(zone).date() != day:
            return {"status": "none"}
        after = {**deepcopy(block), "id": identifier(), "source_block_id": block["id"],
                 "start_at": stamp(start), "end_at": stamp(start + length), "version": 1}
        old.append(deepcopy(block))
        new.append(after)
        position = start + length
    trial = deepcopy(state)
    old_ids = {b["id"] for b in old}
    for item in trial["blocks"]:
        if item["id"] in old_ids:
            item["status"] = "superseded"
    trial["blocks"].extend(deepcopy(new))
    try:
        for item in new:
            validate_block(trial, item, item["id"], now=now)
    except DomainError:
        return {"status": "none"}
    proposal = {
        "id": identifier(), "base_revision": state["revision"] + 1,
        "expires_at": stamp(now + timedelta(minutes=15)), "created_at": stamp(now),
        "status": "draft", "kind": "early", "auto": False, "trigger_session_id": session["id"],
        "old_blocks": old, "new_blocks": new, "unscheduled_items": [],
        "reason": f"提前 {int(early.total_seconds() / 60)} 分钟结束，后面的弹性安排可以往前挪。",
    }
    state["proposals"].append(proposal)
    return {"status": "proposal", "proposal_id": proposal["id"], "count": len(new),
            "minutes": int(early.total_seconds() / 60), "early": True, "reason": proposal["reason"]}
