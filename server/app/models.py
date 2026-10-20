"""Validated operations shared by HTTP and offline replay."""
from datetime import datetime
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Operation(Input):
    operation_id: str = Field(min_length=8, max_length=100)
    kind: str = Field(min_length=3, max_length=60)
    payload: dict


class TaskCreate(Input):
    id: str | None = Field(default=None, pattern=r"^[a-zA-Z0-9-]{1,80}$")
    title: str = Field(min_length=1, max_length=200)
    outcome_criteria: str = Field(min_length=1, max_length=2000)
    project_id: str | None = Field(default=None, pattern=r"^[a-zA-Z0-9-]{1,80}$")
    remaining_minutes: int = Field(ge=1, le=100000)
    min_chunk_minutes: int = Field(default=15, ge=5, le=480)
    splittable: bool = True
    priority: int = Field(default=2, ge=1, le=3)
    deadline: datetime | None = None
    dependency_ids: list[str] = Field(default_factory=list, max_length=30)

    @field_validator("deadline")
    @classmethod
    def aware(cls, value):
        if value is not None and value.tzinfo is None:
            raise ValueError("截止时间必须包含时区")
        return value


class TaskUpdate(Input):
    id: str
    version: int = Field(ge=1)
    title: str | None = Field(default=None, min_length=1, max_length=200)
    outcome_criteria: str | None = Field(default=None, min_length=1, max_length=2000)
    remaining_minutes: int | None = Field(default=None, ge=0, le=100000)
    priority: int | None = Field(default=None, ge=1, le=3)
    state: Literal["ready", "cancelled", "review"] | None = None
    deadline: datetime | None = None
    project_id: str | None = Field(default=None, pattern=r"^[a-zA-Z0-9-]{1,80}$")

    _aware_deadline = field_validator("deadline")(TaskCreate.aware.__func__)

    @model_validator(mode="after")
    def explicit_nulls(self):
        if any(getattr(self, key) is None for key in self.model_fields_set - {"deadline", "project_id"}):
            raise ValueError("任务字段不能显式清空；截止时间和分类可清除")
        return self


class BlockCreate(Input):
    id: str | None = Field(default=None, pattern=r"^[a-zA-Z0-9-]{1,80}$")
    task_id: str | None = None
    title: str = Field(default="保护时段", min_length=1, max_length=200)
    start_at: datetime
    end_at: datetime
    timezone: str = "America/Los_Angeles"
    kind: Literal["flexible", "fixed", "protected", "check"] = "flexible"
    resource_id: str | None = Field(default=None, max_length=100)

    @model_validator(mode="after")
    def valid_interval(self):
        if self.start_at.tzinfo is None or self.end_at.tzinfo is None:
            raise ValueError("时间必须包含时区")
        if self.end_at <= self.start_at or (self.end_at - self.start_at).total_seconds() > 86400:
            raise ValueError("结束时间须晚于开始，且单段不超过一天")
        try:
            ZoneInfo(self.timezone)
        except (ZoneInfoNotFoundError, ValueError):
            raise ValueError("未知时区") from None
        if self.task_id is None and self.kind != "protected":
            raise ValueError("工作时间块需要任务")
        return self


class BlockMove(Input):
    id: str
    version: int = Field(ge=1)
    start_at: datetime
    end_at: datetime
    allow_fixed: bool = False

    @model_validator(mode="after")
    def valid_interval(self):
        if self.start_at.tzinfo is None or self.end_at.tzinfo is None or self.end_at <= self.start_at:
            raise ValueError("时间区间无效或缺少时区")
        if (self.end_at - self.start_at).total_seconds() > 86400:
            raise ValueError("单段不超过一天")
        return self


class SessionStart(Input):
    block_id: str
    id: str | None = Field(default=None, pattern=r"^[a-zA-Z0-9-]{1,80}$")
    occurred_at: datetime | None = None
    mode: Literal["keep_duration", "keep_end"] = "keep_duration"
    defer_adjustment: bool = False


class BlockStatus(Input):
    """Withdraw one planned block, or put a withdrawn future block back."""
    id: str
    version: int = Field(ge=1)


class SessionAction(Input):
    id: str
    occurred_at: datetime | None = None
    defer_adjustment: bool = False


class SessionExtend(SessionAction):
    minutes: int = Field(ge=5, le=120)


class FeedbackCreate(Input):
    session_id: str | None = None
    block_id: str | None = None
    choice: Literal["done", "partial", "waiting", "interrupted", "not_started"]
    outcome_text: str = Field(default="", max_length=4000)
    remaining_minutes: int | None = Field(default=None, ge=1, le=100000)
    check_at: datetime | None = None

    @model_validator(mode="after")
    def required_details(self):
        if self.choice in ("partial", "interrupted") and self.remaining_minutes is None:
            raise ValueError("部分完成或被打断需要填写剩余投入")
        if self.choice == "waiting" and (self.check_at is None or self.check_at.tzinfo is None):
            raise ValueError("等待结果需要包含时区的检查时间")
        if self.session_id is None and (self.choice != "not_started" or self.block_id is None):
            raise ValueError("请先开始并结束本次投入，或记录尚未开始")
        return self


class ReviewSave(Input):
    date: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    text: str = Field(min_length=1, max_length=10000)

    @field_validator("date")
    @classmethod
    def calendar_date(cls, value):
        from datetime import date
        date.fromisoformat(value)
        return value


class SettingsUpdate(Input):
    auto_daily_review: bool | None = None
    auto_adjust: bool | None = None
    timezone: str | None = None
    day_start: str | None = Field(default=None, pattern=r"^([01]\d|2[0-3]):[0-5]\d$")
    day_end: str | None = Field(default=None, pattern=r"^([01]\d|2[0-3]):[0-5]\d$")
    daily_review_time: str | None = Field(default=None, pattern=r"^([01]\d|2[0-3]):[0-5]\d$")

    @field_validator("timezone")
    @classmethod
    def valid_zone(cls, value):
        if value is not None:
            try:
                ZoneInfo(value)
            except (ValueError, ZoneInfoNotFoundError):
                raise ValueError("未知时区") from None
        return value

    @model_validator(mode="after")
    def explicit_nulls(self):
        if any(getattr(self, key) is None for key in self.model_fields_set):
            raise ValueError("设置字段不能清空")
        return self


class WaitingResolve(Input):
    id: str
    resolution: Literal["done", "ready"]
    outcome_text: str = Field(default="", max_length=4000)
    remaining_minutes: int | None = Field(default=None, ge=1, le=100000)

    @model_validator(mode="after")
    def remaining_when_ready(self):
        if self.resolution == "ready" and self.remaining_minutes is None:
            raise ValueError("继续投入需要填写剩余工作量")
        return self


class WaitingSnooze(Input):
    id: str
    check_at: datetime
    version: int | None = Field(default=None, ge=1)

    @field_validator("check_at")
    @classmethod
    def aware(cls, value):
        if value.tzinfo is None:
            raise ValueError("检查时间需要包含时区")
        return value


class PlanRequest(Input):
    task_id: str
    from_at: datetime
    until_at: datetime

    @model_validator(mode="after")
    def interval(self):
        if self.from_at.tzinfo is None or self.until_at.tzinfo is None:
            raise ValueError("排程范围需要时区")
        seconds = (self.until_at - self.from_at).total_seconds()
        if not 0 < seconds <= 31 * 86400:
            raise ValueError("请选择最多 31 天的有效排程范围")
        return self


class PlanAction(Input):
    proposal_id: str


class ProjectCreate(Input):
    id: str | None = Field(default=None, pattern=r"^[a-zA-Z0-9-]{1,80}$")
    name: str = Field(min_length=1, max_length=30)


class ProjectUpdate(Input):
    id: str
    name: str | None = Field(default=None, min_length=1, max_length=30)
    archived: bool | None = None


class SleepLog(Input):
    """Create or replace one night (or nap). An open entry has no woke_at yet."""
    id: str = Field(pattern=r"^[a-zA-Z0-9-]{1,80}$")
    slept_at: datetime
    woke_at: datetime | None = None
    quality: int | None = Field(default=None, ge=1, le=5)
    note: str = Field(default="", max_length=500)

    @model_validator(mode="after")
    def valid_night(self):
        if self.slept_at.tzinfo is None or (self.woke_at is not None and self.woke_at.tzinfo is None):
            raise ValueError("睡眠时间需要包含时区")
        if self.woke_at is not None:
            hours = (self.woke_at - self.slept_at).total_seconds() / 3600
            if hours <= 0 or hours > 20:
                raise ValueError("醒来时间要晚于入睡时间，且一次睡眠不超过 20 小时")
        return self


class SleepDelete(Input):
    id: str


class PairConfirm(Input):
    code: str = Field(pattern=r"^[A-Z2-9]{8}$")
    name: str = Field(min_length=1, max_length=80)


class MemorySave(Input):
    id: str = Field(pattern=r"^[a-zA-Z0-9-]{1,80}$")
    text: str = Field(min_length=1, max_length=1000)
    source: Literal["user", "assistant"] = "user"


class MemoryDelete(Input):
    id: str


class MaterialAdd(Input):
    id: str = Field(pattern=r"^[a-zA-Z0-9-]{1,80}$")
    name: str = Field(min_length=1, max_length=200)
    date: str
    description: str = Field(default='', max_length=2000)
    external_allowed: bool
    sha256: str = Field(pattern=r'^[0-9a-f]{64}$')
    characters: int = Field(ge=1, le=60000)


class MaterialSummary(Input):
    id: str
    summary: str = Field(min_length=1, max_length=6000)


class ReviewAnalysis(Input):
    id: str = Field(pattern=r'^[a-zA-Z0-9-]{8,80}$')
    date: str
    text: str = Field(min_length=1, max_length=12000)
    material_ids: list[str] = Field(max_length=10)
    sources: list[dict] = Field(max_length=10)
    model: str = Field(max_length=200)
    human_review_id: str


MODELS = {
    'material.add': MaterialAdd, 'material.summary': MaterialSummary, 'material.delete': MemoryDelete,
    'review.analysis': ReviewAnalysis,
    "memory.save": MemorySave, "memory.delete": MemoryDelete,
    "task.create": TaskCreate, "task.update": TaskUpdate,
    "block.create": BlockCreate, "block.move": BlockMove,
    "block.cancel": BlockStatus, "block.restore": BlockStatus,
    "session.start": SessionStart, "session.pause": SessionAction,
    "session.resume": SessionAction, "session.end": SessionAction,
    "session.extend": SessionExtend,
    "feedback.create": FeedbackCreate, "review.save": ReviewSave,
    "settings.update": SettingsUpdate,
    "plan.apply": PlanAction, "plan.undo": PlanAction,
    "waiting.resolve": WaitingResolve,
    "waiting.snooze": WaitingSnooze,
    "project.create": ProjectCreate, "project.update": ProjectUpdate,
    "sleep.log": SleepLog, "sleep.delete": SleepDelete,
}
