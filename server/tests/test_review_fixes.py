"""Regressions for the 2026-10-24 review: who gets pushed, when, and through what."""
import os
import subprocess
import sys
import tempfile
from datetime import timedelta
from pathlib import Path

from app import releases
from app.proactive import Proactive
from test_proactive_multiuser import world, operation, queued, OWNER_OPENID, MEMBER_OPENID  # noqa: F401
from test_assistant import client, model, configure, send, NOW  # noqa: F401


def unbind_all(app, user_id):
    with app.state.store.connect() as conn:
        conn.execute("DELETE FROM channel_identities WHERE user_id=?", (user_id,))


def test_owner_legacy_binding_is_ignored_once_that_handle_belongs_to_an_account(world):
    """The live symptom: the old owner account's 「今日收尾」 reached the person who
    had since bound the same WeChat to their own account."""
    app, owner, member, wechat, owner_id, member_id = world
    unbind_all(app, owner_id)
    settings = app.state.wechat.settings
    settings.save({**settings.load(), "bound_openid": MEMBER_OPENID})  # the v1 file still names it
    operation(owner, "task.create", id="owner-task", title="秋招准备", outcome_criteria="投完", remaining_minutes=60)
    operation(member, "task.create", id="member-task", title="具身智能", outcome_criteria="跑通", remaining_minutes=60)
    since = len(queued(app))
    app.state.proactive.tick()
    rows = queued(app, since)
    assert any("具身智能" in r["text"] for r in rows)
    assert not any("秋招准备" in r["text"] for r in rows)


def test_account_that_binds_later_still_gets_its_receipts(world):
    app, owner, member, wechat, owner_id, member_id = world
    unbind_all(app, member_id)
    for index in range(6):  # the owner's legacy log runs well ahead of the member's own
        operation(owner, "task.create", id=f"owner-{index}", title=f"主账号事{index}", outcome_criteria="好", remaining_minutes=30)
    operation(member, "task.create", id="member-old", title="旧事", outcome_criteria="好", remaining_minutes=30)
    app.state.proactive.tick()  # member has no chat yet
    with app.state.store.connect() as conn:
        app.state.wechat.identities.bind(conn, "wechat", MEMBER_OPENID, member_id, "师弟")
    operation(member, "task.create", id="member-new", title="新事", outcome_criteria="好", remaining_minutes=30)
    since = len(queued(app))
    app.state.proactive.tick()
    texts = [r["text"] for r in queued(app, since) if r["openid"] == MEMBER_OPENID]
    assert any("待办已添加" in t and "新事" in t for t in texts)
    assert not any("旧事" in t for t in texts)


def test_startup_repairs_a_cursor_left_past_the_accounts_own_events(world):
    app, owner, member, wechat, owner_id, member_id = world
    operation(member, "task.create", id="member-task", title="事", outcome_criteria="好", remaining_minutes=30)
    with app.state.store.connect() as conn:
        conn.execute("INSERT OR REPLACE INTO notification_cursors VALUES(?,999)", (member_id,))
    Proactive(app.state.store, app.state.proactive.channel, app.state.proactive.clock)
    with app.state.store.connect() as conn:
        assert conn.execute("SELECT revision FROM notification_cursors WHERE user_id=?",
                            (member_id,)).fetchone()[0] == 1


def test_each_chat_has_its_own_push_switch(world):
    app, owner, member, wechat, owner_id, member_id = world
    unbind_all(app, member_id)
    with app.state.store.connect() as conn:
        app.state.qq.identities.bind(conn, "qq", "qq-member", member_id, "师弟")
    settings = app.state.wechat.settings
    settings.save({**settings.load(), "proactive_enabled": False})
    operation(owner, "task.create", id="owner-task", title="秋招准备", outcome_criteria="投完", remaining_minutes=60)
    operation(member, "task.create", id="member-task", title="具身智能", outcome_criteria="跑通", remaining_minutes=60)
    since = len(queued(app))
    app.state.proactive.tick()
    assert queued(app, since) == []  # WeChat is muted
    with app.state.store.connect() as conn:
        qq_rows = [row[0] for row in conn.execute("SELECT text FROM qq_outbox")]
    assert any("具身智能" in text for text in qq_rows)  # QQ still speaks


def test_phone_package_is_not_recompressed(client, tmp_path):
    apk = tmp_path / "app.apk"
    apk.write_bytes(os.urandom(256 * 1024))
    releases.publish(client.app.state.store.directory, apk, "9.9.9+99", False)
    response = client.get("/api/v1/app/download", headers={"Accept-Encoding": "gzip"})
    assert response.status_code == 200
    assert "content-encoding" not in response.headers
    assert response.headers["content-length"] == str(256 * 1024)


def test_importing_the_server_does_not_open_a_database():
    folder = tempfile.mkdtemp(prefix="shunshi-import-")
    server = Path(__file__).resolve().parents[1]
    env = {**os.environ, "PLANNER_DATA_DIR": folder}
    subprocess.run([sys.executable, "-c", "import app.main"], cwd=server, env=env, check=True)
    assert os.listdir(folder) == []


def test_auto_review_runs_again_when_material_is_added_later(client, model):
    configure(client)
    send(client, "review.save", date="2026-10-19", text="今天做了偏压分析。")
    evening = NOW + timedelta(hours=13)  # 22:00 in Los Angeles, after the 21:30 review time
    client.app.state.assistant.clock = lambda: evening
    model.replies.append((200, "做成了：偏压分析。"))
    client.portal.call(client.app.state.materials.generate_due)
    upload = client.post("/api/v1/materials/upload", params={"name": "notes.md", "day": "2026-10-19",
                         "description": "实验记录"}, content="偏压升高，侧壁角度需复核。".encode())
    assert upload.status_code == 200, upload.text
    model.replies += [(200, "要点：侧壁角度待复核。[第1行]"), (200, "做成了：偏压分析；学到了：侧壁角度待复核。")]
    client.portal.call(client.app.state.materials.generate_due)
    analyses = client.get("/api/v1/snapshot").json()["analyses"]
    assert len(analyses) == 2 and analyses[-1]["material_ids"] == [upload.json()["id"]]


def wechat_said(app, openid, at):
    with app.state.store.connect() as conn:
        conn.execute("INSERT INTO wechat_inbox(id,dedup_key,openid,kind,content,received_at,status) "
                     "VALUES(?,?,?,?,?,?,?)", (os.urandom(8).hex(), os.urandom(8).hex(), openid, "text", "1",
                                               at.isoformat(), "handled"))


def bind_qq_too(app, user_id):
    with app.state.store.connect() as conn:
        app.state.qq.identities.bind(conn, "qq", "qq-" + user_id[:6], user_id, "QQ")


def qq_texts(app):
    with app.state.store.connect() as conn:
        return [row[0] for row in conn.execute("SELECT text FROM qq_outbox")]


def test_closed_wechat_window_without_template_falls_back_to_qq(world):
    app, owner, member, wechat, owner_id, member_id = world
    from test_proactive_multiuser import NOW as WORLD_NOW
    wechat_said(app, MEMBER_OPENID, WORLD_NOW - timedelta(hours=50))
    bind_qq_too(app, member_id)
    operation(member, "task.create", id="member-task", title="具身智能", outcome_criteria="跑通", remaining_minutes=60)
    since = len(queued(app))
    app.state.proactive.tick()
    assert not any("具身智能" in r["text"] for r in queued(app, since))
    assert any("具身智能" in text for text in qq_texts(app))


def test_open_wechat_window_or_a_template_keeps_wechat_first(world):
    app, owner, member, wechat, owner_id, member_id = world
    from test_proactive_multiuser import NOW as WORLD_NOW
    bind_qq_too(app, member_id)
    wechat_said(app, MEMBER_OPENID, WORLD_NOW - timedelta(hours=2))
    with app.state.store.connect() as conn:
        assert app.state.proactive._target(conn, member_id) == ("wechat", MEMBER_OPENID)
    with app.state.store.connect() as conn:
        conn.execute("DELETE FROM wechat_inbox")
    settings = app.state.wechat.settings
    settings.save({**settings.load(), "template_id": "tmpl-123"})
    with app.state.store.connect() as conn:
        assert app.state.proactive._target(conn, member_id) == ("wechat", MEMBER_OPENID)


def test_wechat_only_person_is_nudged_once_before_the_window_closes(world):
    app, owner, member, wechat, owner_id, member_id = world
    from test_proactive_multiuser import NOW as WORLD_NOW
    wechat_said(app, MEMBER_OPENID, WORLD_NOW - timedelta(hours=45))
    since = len(queued(app))
    app.state.proactive.tick()
    app.state.proactive.tick()
    nudges = [r for r in queued(app, since) if "提醒通道快到期了" in r["text"]]
    assert len(nudges) == 1 and nudges[0]["openid"] == MEMBER_OPENID
    wechat_said(app, MEMBER_OPENID, WORLD_NOW - timedelta(minutes=5))  # they replied
    assert not app.state.proactive.valid(nudges[0]["dedup_key"])


def test_weekly_brief_follows_the_same_channel_choice(world):
    app, owner, member, wechat, owner_id, member_id = world
    from test_proactive_multiuser import NOW as WORLD_NOW
    wechat_said(app, MEMBER_OPENID, WORLD_NOW - timedelta(days=3))
    bind_qq_too(app, member_id)
    sunday = WORLD_NOW + timedelta(days=5, hours=20, minutes=30)  # Sunday 20:30 in Shanghai (member)
    app.state.weekly.clock = lambda: sunday
    app.state.proactive.clock = lambda: sunday
    owner.portal.call(app.state.weekly.run_due)
    assert any("本周简报" in text for text in qq_texts(app))
