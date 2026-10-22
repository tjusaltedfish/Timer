"""Account administration from the server console (v2, P1).

Examples::

    python -m app.admin user list
    python -m app.admin user add --username shidi --display-name 师弟
    python -m app.admin user reset-password --username me
    python -m app.admin user disable --username shidi

The data directory follows the server (``PLANNER_DATA_DIR`` or the default
``%USERPROFILE%\\TimePlanner\\data``).  Passwords are read from a prompt unless
``--password`` is given, so they do not land in shell history by default.
"""
from __future__ import annotations

import argparse
import getpass
import os
import sys
from pathlib import Path

from . import auth, releases
from .store import Store


def _prompt_password(confirm: bool = False) -> str:
    first = getpass.getpass("新密码（至少 10 位）: ")
    if confirm:
        if getpass.getpass("再输一次: ") != first:
            print("两次输入不一致。", file=sys.stderr)
            raise SystemExit(2)
    return first


def _directory() -> Path:
    return Path(os.environ.get("PLANNER_DATA_DIR") or releases.default_data_dir())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="admin", description="瞬时 v2 账号管理")
    sub = parser.add_subparsers(dest="command", required=True)
    users = sub.add_parser("user", help="账号操作")
    actions = users.add_subparsers(dest="action", required=True)

    add = actions.add_parser("add", help="新增一个账号")
    add.add_argument("--username", required=True)
    add.add_argument("--password")
    add.add_argument("--display-name", default="")
    add.add_argument("--timezone", default="Asia/Shanghai")
    add.add_argument("--role", choices=("member", "admin"), default="member")

    reset = actions.add_parser("reset-password", help="重设密码（用于忘记密码/首次登录主账号）")
    reset.add_argument("--username", required=True)
    reset.add_argument("--password")

    for name in ("disable", "enable", "promote"):
        action = actions.add_parser(name, help={"disable": "停用账号", "enable": "恢复账号",
                                               "promote": "提升为管理员"}[name])
        action.add_argument("--username", required=True)

    actions.add_parser("list", help="列出账号")

    args = parser.parse_args(argv)
    store = Store(_directory())

    with store.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        if args.action == "list":
            for row in conn.execute("SELECT * FROM users ORDER BY created_at"):
                print(f"{row['username']:<16} {row['display_name']:<12} {row['role']:<7}"
                      f" {row['status']:<9} {row['created_at']}")
        elif args.action == "add":
            password = args.password or _prompt_password(confirm=True)
            user = auth.create_user(
                conn,
                username=args.username,
                password=password,
                display_name=args.display_name,
                timezone_name=args.timezone,
                role=args.role,
            )
            store.save(conn, store.initial_state(user["timezone"]), user["id"])
            print(f"已创建 {user['username']}（{user['display_name']}，{user['role']}），"
                  f"时区 {user['timezone']}。")
        elif args.action == "reset-password":
            row = auth.find_user(conn, args.username)
            if row is None:
                print("没有这个账号。", file=sys.stderr)
                return 1
            password = args.password or _prompt_password(confirm=True)
            auth.validate_password(password)
            conn.execute(
                "UPDATE users SET password_hash = ? WHERE id = ?",
                (auth.hash_password(password), row["id"]),
            )
            conn.execute("UPDATE users SET last_login_at = NULL WHERE id = ?", (row["id"],))
            print(f"已重设 {row['username']} 的密码；该账号已登录的设备仍然有效，可到设置里逐一移除。")
        elif args.action in ("disable", "enable"):
            row = auth.find_user(conn, args.username)
            if row is None:
                print("没有这个账号。", file=sys.stderr)
                return 1
            if row["id"] == store.owner_id and args.action == "disable":
                print("不能停用主账号。", file=sys.stderr)
                return 1
            status = "disabled" if args.action == "disable" else "active"
            conn.execute("UPDATE users SET status = ? WHERE id = ?", (status, row["id"]))
            if status == "disabled":
                conn.execute("UPDATE devices SET revoked = 1 WHERE user_id = ?", (row["id"],))
            print(f"{row['username']} 现在是 {status}。")
        elif args.action == "promote":
            row = auth.find_user(conn, args.username)
            if row is None:
                print("没有这个账号。", file=sys.stderr)
                return 1
            conn.execute("UPDATE users SET role = 'admin' WHERE id = ?", (row["id"],))
            print(f"{row['username']} 现在是管理员。")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
