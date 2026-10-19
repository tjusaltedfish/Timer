from .domain import close_interval, parse, stamp
from .store import encode


def expire_due(store, now):
    """Persist overdue segments as awaiting feedback, never as completed tasks."""
    with store.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        state = store.state(conn)
        affected = []
        for session in state["sessions"]:
            if session["state"] != "running" or parse(session["expected_end_at"]) > now:
                continue
            at = parse(session["expected_end_at"])
            close_interval(session, at)
            session["state"] = "awaiting_feedback"
            session["actual_end_at"] = stamp(at)
            session["ended_by"] = "timer"
            session["version"] += 1
            affected.append(session["id"])
        if affected:
            state["revision"] += 1
            store.save(conn, state)
            conn.execute("INSERT INTO events VALUES(?,?,?,?,?)", (state["revision"], "system", "session.elapsed", encode({"session_ids": affected}), stamp(now)))
