"""State transitions are deterministic and executed inside a storage transaction."""
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from .models import MODELS


class DomainError(Exception):
    def __init__(self, message, code="CONFLICT", status=409):
        self.message, self.code, self.status = message, code, status


def identifier():
    return str(uuid4())


def parse(value):
    return datetime.fromisoformat(value)


def stamp(value):
    return value.astimezone(timezone.utc).isoformat()


def find(state, collection, key):
    item = next((item for item in state[collection] if item["id"] == key), None)
    if item is None:
        raise DomainError("记录不存在", "NOT_FOUND", 404)
    return item


def check_version(item, version):
    if item["version"] != version:
        raise DomainError("这条记录已被另一台设备更新，请同步后重试", "STALE_VERSION")


def validate_block(state, block, exclude_id=None):
    if block.get("task_id"):
        task = find(state, "tasks", block["task_id"])
        if task["state"] in ("done", "cancelled"):
            raise DomainError("任务已经结束，请先显式重新打开")
        if task.get("deadline") and parse(block["end_at"]) > parse(task["deadline"]):
            raise DomainError("安排超过任务截止时间")
        for dependency in task["dependency_ids"]:
            before = find(state, "tasks", dependency)
            if before["state"] != "done":
                previous = [b for b in state["blocks"] if b.get("task_id") == dependency and b["status"] == "scheduled"]
                if not previous or max(parse(b["end_at"]) for b in previous) > parse(block["start_at"]):
                    raise DomainError("请先安排或完成前置任务")
    for other in state["blocks"]:
        if other["id"] == exclude_id or other["status"] != "scheduled":
            continue
        if parse(block["start_at"]) < parse(other["end_at"]) and parse(block["end_at"]) > parse(other["start_at"]):
            raise DomainError(f"与「{other['title']}」的时间冲突", "TIME_CONFLICT")


def event_time(value, now, minimum=None):
    if value is None:
        return now
    value = parse(value) if isinstance(value, str) else value
    if value.tzinfo is None or value > now + timedelta(minutes=5):
        raise DomainError("执行时间缺少时区或处于未来", "INVALID_TIME", 422)
    if minimum is not None and value < parse(minimum):
        raise DomainError("执行事件的时间早于前一次记录", "INVALID_TIME", 422)
    return value


def close_interval(session, at):
    if session["intervals"] and session["intervals"][-1]["end_at"] is None:
        session["intervals"][-1]["end_at"] = stamp(at)


def apply(state, operation, device_id, now):
    kind = operation.kind
    if kind not in MODELS:
        raise DomainError("不支持的操作", "UNKNOWN_OPERATION", 422)
    data = MODELS[kind].model_validate(operation.payload).model_dump(mode="json", exclude_unset=True)
    # Defaults are needed on creation, but omitted PATCH fields must remain untouched.
    if kind in ("task.create", "block.create", "feedback.create"):
        data = MODELS[kind].model_validate(operation.payload).model_dump(mode="json")
    if kind == "task.create":
        entity = {**data, "id": data.get("id") or identifier(), "state": "ready", "version": 1, "created_at": stamp(now)}
        if any(t["id"] == entity["id"] for t in state["tasks"]):
            raise DomainError("任务标识已经存在")
        for key in entity["dependency_ids"]:
            find(state, "tasks", key)
            if key == entity["id"]:
                raise DomainError("任务不能依赖自身", status=422)
        state["tasks"].append(entity)
    elif kind == "task.update":
        entity = find(state, "tasks", data.pop("id"))
        check_version(entity, data.pop("version"))
        if "state" in data and any(s["task_id"] == entity["id"] and s["state"] in ("running", "paused") for s in state["sessions"]):
            raise DomainError("请先结束当前投入")
        if data.get("title") is None and "title" in data or data.get("outcome_criteria") is None and "outcome_criteria" in data:
            raise DomainError("标题和完成标准不能为空", status=422)
        entity.update(data)
        entity["version"] += 1
        if entity["state"] == "cancelled":
            for block in state["blocks"]:
                if block.get("task_id") == entity["id"] and block["status"] == "scheduled":
                    block["status"] = "cancelled"
                    block["version"] += 1
    elif kind == "block.create":
        entity = {**data, "id": data.get("id") or identifier(), "version": 1, "status": "scheduled"}
        if entity["task_id"]:
            entity["title"] = find(state, "tasks", entity["task_id"])["title"]
        entity["start_at"], entity["end_at"] = stamp(parse(data["start_at"])), stamp(parse(data["end_at"]))
        if any(b["id"] == entity["id"] for b in state["blocks"]):
            raise DomainError("时间块标识已经存在")
        validate_block(state, entity)
        state["blocks"].append(entity)
    elif kind == "block.move":
        entity = find(state, "blocks", data["id"])
        check_version(entity, data["version"])
        if entity["kind"] in ("fixed", "protected") and not data.get("allow_fixed"):
            raise DomainError("固定或保护时段需要明确手动编辑")
        if any(s["block_id"] == entity["id"] for s in state["sessions"]) or entity["status"] != "scheduled":
            raise DomainError("已有执行记录，不能改写过去的安排")
        candidate = {**entity, "start_at": stamp(parse(data["start_at"])), "end_at": stamp(parse(data["end_at"]))}
        validate_block(state, candidate, entity["id"])
        entity.update(candidate)
        entity["version"] += 1
    elif kind == "session.start":
        block = find(state, "blocks", data["block_id"])
        task = find(state, "tasks", block["task_id"])
        if block["status"] != "scheduled" or task["state"] in ("done", "cancelled"):
            raise DomainError("这段安排已经结束")
        for key in task["dependency_ids"]:
            if find(state, "tasks", key)["state"] != "done":
                raise DomainError("前置任务尚未完成")
        if any(s["state"] in ("running", "paused") for s in state["sessions"]):
            raise DomainError("已有正在进行的投入，请先结束它", "ACTIVE_SESSION")
        if any(s["block_id"] == block["id"] for s in state["sessions"]):
            raise DomainError("该时间段已有执行记录，请安排下一段")
        at = event_time(data.get("occurred_at"), now)
        duration = parse(block["end_at"]) - parse(block["start_at"])
        entity = {"id": data.get("id") or identifier(), "block_id": block["id"], "task_id": task["id"], "device_id": device_id,
                  "state": "running", "actual_start_at": stamp(at), "actual_end_at": None,
                  "expected_end_at": stamp(at + duration), "last_event_at": stamp(at),
                  "intervals": [{"start_at": stamp(at), "end_at": None}], "version": 1}
        if any(s["id"] == entity["id"] for s in state["sessions"]):
            raise DomainError("执行标识已经存在")
        state["sessions"].append(entity)
        task["state"] = "in_progress"
        task["version"] += 1
    elif kind.startswith("session."):
        entity = find(state, "sessions", data["id"])
        at = event_time(data.get("occurred_at"), now, entity["last_event_at"])
        allowed = {"session.pause": {"running"}, "session.resume": {"paused"}, "session.end": {"running", "paused"}}
        if entity["state"] not in allowed[kind]:
            raise DomainError("当前执行状态不允许这项操作", "INVALID_TRANSITION")
        if kind == "session.pause":
            close_interval(entity, at)
            entity["paused_at"] = stamp(at)
            entity["state"] = "paused"
        elif kind == "session.resume":
            pause = at - parse(entity["paused_at"])
            entity["expected_end_at"] = stamp(parse(entity["expected_end_at"]) + pause)
            entity["intervals"].append({"start_at": stamp(at), "end_at": None})
            entity["state"] = "running"
        else:
            close_interval(entity, at)
            entity["actual_end_at"] = stamp(at)
            entity["state"] = "awaiting_feedback"
        entity["last_event_at"] = stamp(at)
        entity["version"] += 1
    elif kind == "feedback.create":
        session = find(state, "sessions", data["session_id"]) if data["session_id"] else None
        block = find(state, "blocks", session["block_id"] if session else data["block_id"])
        task = find(state, "tasks", block["task_id"])
        if session and session["state"] != "awaiting_feedback":
            raise DomainError("请先结束本次投入，再提交结果")
        if not session and any(s["block_id"] == block["id"] for s in state["sessions"]):
            raise DomainError("这段已有执行记录，请从执行记录反馈")
        entity = {**data, "id": identifier(), "task_id": task["id"], "block_id": block["id"], "created_at": stamp(now), "device_id": device_id}
        if session:
            session["state"] = "closed"
            session["version"] += 1
        block["status"] = "skipped" if data["choice"] == "not_started" else "completed"
        block["version"] += 1
        task["state"] = {"done": "done", "waiting": "waiting"}.get(data["choice"], "ready")
        task["version"] += 1
        if data["choice"] == "done":
            task["remaining_minutes"] = 0
            for future in state["blocks"]:
                if future.get("task_id") == task["id"] and future["status"] == "scheduled":
                    future["status"] = "cancelled"
                    future["version"] += 1
        elif data["choice"] == "partial":
            task["remaining_minutes"] = data["remaining_minutes"]
        elif data["choice"] == "waiting":
            if parse(data["check_at"]) <= now:
                raise DomainError("请选择未来的结果检查时间", "INVALID_CHECK_TIME", 422)
            state["waiting_checks"].append({"id": identifier(), "task_id": task["id"], "check_at": stamp(parse(data["check_at"])), "resolved_at": None})
        state["feedbacks"].append(entity)
    elif kind == "review.save":
        existing = next((r for r in state["reviews"] if r["date"] == data["date"]), None)
        entity = {"id": identifier(), **data, "version": (existing["version"] + 1) if existing else 1,
                  "created_at": stamp(now), "archive_status": "pending"}
        state["reviews"].append(entity)
        state["jobs"].append({"id": identifier(), "kind": "archive", "review_id": entity["id"], "status": "pending", "attempts": 0})
    elif kind == "settings.update":
        entity = state["settings"]
        candidate = {**entity, **data}
        if candidate["day_start"] >= candidate["day_end"]:
            raise DomainError("日程结束时间必须晚于开始时间", status=422)
        entity.update(candidate)
    elif kind == "plan.apply":
        from .planning import apply_plan
        entity = apply_plan(state, data["proposal_id"], now)
    elif kind == "plan.undo":
        from .planning import undo_plan
        entity = undo_plan(state, data["proposal_id"])
    else:
        raise DomainError("不支持的操作", status=422)
    return entity
