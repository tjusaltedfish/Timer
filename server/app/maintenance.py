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



PROPOSAL_KEEP = 20
FEEDBACK_KEEP = 200
REVIEW_KEEP = 100
EVENT_KEEP = 5000
OPERATION_KEEP = 20000
NOTIFY_KEEP = 5000  # dedupe rows only matter for a few days of events


def compact(store, now, user_id=None):
    """Trim history that is kept for display, not for correctness.

    The single-document state grows with proposals, feedbacks and reviews, and
    the shared operations table only exists for idempotent replay (seconds).
    Both are trimmed here so a long-lived install does not keep paying for
    every message ever sent.
    """
    user_id = user_id or store.owner_id
    removed = {"proposals": 0, "feedbacks": 0, "reviews": 0, "events": 0, "operations": 0, "notifications": 0}
    with store.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        state = store.state(conn, user_id)
        changed = False
        for key, keep in (("proposals", PROPOSAL_KEEP), ("feedbacks", FEEDBACK_KEEP),
                          ("reviews", REVIEW_KEEP)):
            items = state.get(key) or []
            if len(items) > keep:
                removed[key] = len(items) - keep
                del items[:-keep]
                changed = True
        if changed:
            store.save(conn, state, user_id)
        extra = conn.execute("SELECT COUNT(*) FROM user_events WHERE user_id=?",
                             (user_id,)).fetchone()[0] - EVENT_KEEP
        if extra > 0:
            conn.execute(
                "DELETE FROM user_events WHERE user_id=? AND revision IN "
                "(SELECT revision FROM user_events WHERE user_id=? ORDER BY revision ASC LIMIT ?)",
                (user_id, user_id, extra),
            )
            removed["events"] = extra
        over = conn.execute("SELECT COUNT(*) FROM operations").fetchone()[0] - OPERATION_KEEP
        if over > 0:
            conn.execute(
                "DELETE FROM operations WHERE id IN (SELECT id FROM operations ORDER BY rowid ASC LIMIT ?)",
                (over,),
            )
            removed["operations"] = over
        stale = conn.execute("SELECT COUNT(*) FROM notification_refs").fetchone()[0] - NOTIFY_KEEP
        if stale > 0:
            conn.execute(
                "DELETE FROM notification_refs WHERE rowid IN "
                "(SELECT rowid FROM notification_refs ORDER BY rowid ASC LIMIT ?)",
                (stale,),
            )
            removed["notifications"] = stale
    return removed


def compact_all(store, now):
    with store.connect() as conn:
        users = [row["id"] for row in conn.execute("SELECT id FROM users WHERE status='active'")]
    totals = {}
    for user_id in users:
        for key, value in compact(store, now, user_id).items():
            totals[key] = totals.get(key, 0) + value
    return totals
