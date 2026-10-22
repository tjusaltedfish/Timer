"""Per-user state and the operation log (v2 repository).

Every JSON operation of a v2 request is applied to exactly one user's
document through ``BEGIN IMMEDIATE`` (see ``main.mutate``), so the revision a
client read is still current when the change lands.  The legacy ``document``
row mirrors the owner's state so v1 backups and tooling keep working.
"""
from __future__ import annotations

import json
from datetime import datetime

from .domain import DomainError, apply
from .models import Operation
from .store import digest, encode, utcnow


class Repository:
    def __init__(self, store):
        self.store = store

    def read(self, conn, user_id: str) -> dict:
        row = conn.execute("SELECT body FROM user_state WHERE user_id = ?", (user_id,)).fetchone()
        if row is None:  # repaired on the fly instead of failing the request
            return self.store.state(conn, user_id)
        return json.loads(row["body"])

    def write(self, conn, user_id: str, state: dict, now: datetime | None = None) -> None:
        self.store.save(conn, state, user_id)

    def apply(
        self, conn, user_id: str, device_id: str, operation: Operation, now: datetime | None = None
    ) -> dict:
        now = now or utcnow()
        request_hash = digest(encode(operation.model_dump()))
        prior = conn.execute("SELECT * FROM operations WHERE id = ?", (operation.operation_id,)).fetchone()
        if prior is not None:
            owner_of_prior = prior["user_id"] or self.store.owner_id
            if (
                owner_of_prior != user_id
                or prior["device_id"] != device_id
                or prior["request_hash"] != request_hash
            ):
                raise DomainError("操作编号已被其他内容使用", "OPERATION_ID_REUSED", 409)
            return json.loads(prior["response"])
        state = self.read(conn, user_id)
        entity = apply(state, operation, device_id, now)
        state["revision"] += 1
        result = {
            "revision": state["revision"],
            "operation_id": operation.operation_id,
            "entity": entity,
        }
        self.write(conn, user_id, state, now)
        conn.execute(
            "INSERT INTO operations(id, device_id, user_id, request_hash, response)"
            " VALUES(?,?,?,?,?)",
            (operation.operation_id, device_id, user_id, request_hash, encode(result)),
        )
        self.store.record_event(
            conn, user_id, state["revision"], device_id, operation.kind, operation.payload, now
        )
        return result
