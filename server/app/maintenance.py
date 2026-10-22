from .domain import close_interval, parse, stamp


def expire_due(store, now, user_id=None):
    """Persist overdue segments as awaiting feedback, never as completed tasks."""
    user_id = user_id or store.owner_id
    with store.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        state = store.state(conn, user_id)
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
            store.save(conn, state, user_id)
            store.record_event(
                conn, user_id, state["revision"], "system", "session.elapsed",
                {"session_ids": affected}, now,
            )
