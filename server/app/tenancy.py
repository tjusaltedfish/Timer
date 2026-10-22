"""Tenancy guards: who owns the data a request may touch.

The v1 desktop token and pairing code map to the owner account, so every
request still carries exactly one ``user_id``.  The assistant / channel
routes remain owner-only until P2 gives each account its own channel
identity; the guards below keep that temporary restriction explicit instead
of letting one account read another's data through an old endpoint.
"""
from __future__ import annotations

from .domain import DomainError


def user_id(store, device: dict) -> str:
    """Owner fallback keeps legacy tokens working before they are re-issued."""
    return device.get("user_id") or store.owner_id


def is_owner(store, device: dict) -> bool:
    return user_id(store, device) == store.owner_id


def require_owner(store, device: dict) -> None:
    if not is_owner(store, device):
        raise DomainError("这个接口暂时只对主账号开放", "OWNER_ONLY", 403)


def require_admin(store, device: dict) -> None:
    user = device.get("user_role") or ("admin" if is_owner(store, device) else "member")
    if user != "admin":
        raise DomainError("需要管理员账号", "ADMIN_ONLY", 403)
