"""Explainable bounded rescheduling; hard constraints never become penalties."""
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

from .domain import DomainError, find, identifier, parse, stamp, validate_block


def propose(state, request, now):
    start, end = request.from_at, request.until_at
    if start < now - timedelta(minutes=1):
        raise DomainError("重排只能调整未来时间", status=422)
    target = find(state, "tasks", request.task_id)
    if target["state"] in ("done", "cancelled", "waiting"):
        raise DomainError("任务目前不需要排程，请先确认可执行状态")
    zone = ZoneInfo(state["settings"]["timezone"])
    live = [b for b in state["blocks"] if b["status"] == "scheduled"]
    used_blocks = {s["block_id"] for s in state["sessions"]}
    movable = [b for b in live if b["kind"] == "flexible" and parse(b["start_at"]) >= start
               and parse(b["end_at"]) <= end and b["id"] not in used_blocks]
    locked = [b for b in live if b not in movable]
    duration = lambda b: int((parse(b["end_at"]) - parse(b["start_at"])).total_seconds() / 60)
    reserved = sum(duration(b) for b in locked if b.get("task_id") == target["id"] and parse(b["start_at"]) >= start)
    candidates = {target["id"]: {"task": target, "minutes": max(0, target["remaining_minutes"] - reserved), "earliest": start}}
    for block in movable:
        if block["task_id"] == target["id"]:
            continue
        task = find(state, "tasks", block["task_id"])
        item = candidates.setdefault(task["id"], {"task": task, "minutes": 0, "earliest": parse(block["start_at"])})
        item["minutes"] += duration(block)
        item["earliest"] = min(item["earliest"], parse(block["start_at"]))

    def priority(item):
        task = item["task"]
        return (task["id"] != target["id"], parse(task["deadline"]) if task.get("deadline") else end,
                -task["priority"], item["earliest"])

    pending = sorted(candidates.values(), key=priority)
    results, unscheduled, processed = [], [], {}
    occupied = [(parse(b["start_at"]), parse(b["end_at"])) for b in locked]
    while pending:
        progressed = False
        for item in list(pending):
            task = item["task"]
            dependency_ends = []
            unresolved = False
            for dependency_id in task["dependency_ids"]:
                dependency = find(state, "tasks", dependency_id)
                if dependency["state"] == "done":
                    continue
                if dependency_id in candidates and dependency_id not in processed:
                    unresolved = True
                    break
                if dependency_id in processed:
                    finish = processed[dependency_id]
                    if finish is None:
                        unresolved = True
                        break
                    dependency_ends.append(finish)
                else:
                    appointments = [b for b in locked if b.get("task_id") == dependency_id]
                    if not appointments:
                        unresolved = True
                        break
                    dependency_ends.append(max(parse(b["end_at"]) for b in appointments))
            if unresolved:
                continue
            pending.remove(item)
            progressed = True
            earliest = max([start, item["earliest"], *dependency_ends])
            limit = min(end, parse(task["deadline"])) if task.get("deadline") else end
            left = item["minutes"]
            minimum = min(task["min_chunk_minutes"], left) if left else 0
            day = earliest.astimezone(zone).date()
            finish = earliest
            while left > 0 and day <= limit.astimezone(zone).date():
                day_start = datetime.combine(day, time.fromisoformat(state["settings"]["day_start"]), zone)
                day_end = datetime.combine(day, time.fromisoformat(state["settings"]["day_end"]), zone)
                position, boundary = max(earliest, day_start), min(limit, day_end)
                for a, b in sorted(occupied) + [(boundary, boundary)]:
                    if b <= position or a >= boundary and a != boundary:
                        continue
                    gap_end = min(a, boundary)
                    capacity = max(0, int((gap_end - position).total_seconds() / 60))
                    amount = min(left, capacity)
                    if amount >= minimum and (task["splittable"] or amount == left):
                        finish = position + timedelta(minutes=amount)
                        result = {"id": identifier(), "task_id": task["id"], "title": task["title"], "kind": "flexible",
                                  "start_at": stamp(position), "end_at": stamp(finish), "timezone": state["settings"]["timezone"],
                                  "duration_minutes": amount, "resource_id": None, "version": 1, "status": "scheduled"}
                        results.append(result)
                        occupied.append((position, finish))
                        left -= amount
                        position = finish
                    position = max(position, b)
                    if not left or position >= boundary:
                        break
                day += timedelta(days=1)
            processed[task["id"]] = finish if left == 0 else None
            if left:
                unscheduled.append({"task_id": task["id"], "title": task["title"], "minutes": left, "reason": "可用时间不足，或无法满足连续投入/截止要求"})
        if not progressed:
            for item in pending:
                unscheduled.append({"task_id": item["task"]["id"], "title": item["task"]["title"], "minutes": item["minutes"], "reason": "前置任务尚未安排完成或被阻塞"})
            break
    return {"id": identifier(), "base_revision": state["revision"], "expires_at": stamp(now + timedelta(minutes=15)),
            "status": "draft", "old_blocks": movable, "new_blocks": results, "unscheduled_items": unscheduled,
            "reason": "优先安排本次剩余工作，再按截止期和优先级调整未来弹性块；固定、保护和已有执行记录保留。"}


def apply_plan(state, proposal_id, now):
    proposal = find(state, "proposals", proposal_id)
    if proposal["status"] != "draft" or proposal["base_revision"] != state["revision"] or parse(proposal["expires_at"]) <= now:
        raise DomainError("预览已过期或日程已变化，请重新生成", "STALE_PROPOSAL")
    for old in proposal["old_blocks"]:
        original = find(state, "blocks", old["id"])
        original["status"] = "superseded"
        original["version"] += 1
    for block in proposal["new_blocks"]:
        validate_block(state, block)
        state["blocks"].append(dict(block))
    proposal["status"] = "applied"
    proposal["applied_revision"] = state["revision"] + 1
    return proposal


def undo_plan(state, proposal_id):
    proposal = find(state, "proposals", proposal_id)
    if proposal["status"] != "applied" or proposal["applied_revision"] != state["revision"]:
        raise DomainError("调整后已有其他变化，需重新预览才能恢复", "STALE_UNDO")
    for block in proposal["new_blocks"]:
        current = find(state, "blocks", block["id"])
        current["status"] = "cancelled"
        current["version"] += 1
    for old in proposal["old_blocks"]:
        current = find(state, "blocks", old["id"])
        current["status"] = "scheduled"
        current["version"] += 1
        validate_block(state, current, current["id"])
    proposal["status"] = "undone"
    return proposal
