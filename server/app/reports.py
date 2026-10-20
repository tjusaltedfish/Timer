"""Original text and evidence-based counts are always available without a model."""
import json
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo


def report_for(state, day, now=None):
    reviews = [r for r in state["reviews"] if r["date"] == day]
    original = reviews[-1]["text"] if reviews else "尚未填写日终回顾。"
    zone = ZoneInfo(state["settings"]["timezone"])
    midnight = datetime.fromisoformat(day).replace(tzinfo=zone).astimezone(timezone.utc)
    next_midnight = (datetime.fromisoformat(day).replace(tzinfo=zone) + timedelta(days=1)).astimezone(timezone.utc)
    now = now or datetime.now(timezone.utc)
    blocks = [b for b in state["blocks"] if datetime.fromisoformat(b['start_at']) < next_midnight and datetime.fromisoformat(b['end_at']) > midnight]
    actual_seconds, execution_count = 0, 0
    for session in state['sessions']:
        seconds = sum(max(0, (min(datetime.fromisoformat(v['end_at']) if v.get('end_at') else now, next_midnight)
                              - max(datetime.fromisoformat(v['start_at']), midnight)).total_seconds()) for v in session.get('intervals', []))
        actual_seconds += seconds
        execution_count += int(seconds > 0)
    planned_minutes = sum(max(0, (min(datetime.fromisoformat(b['end_at']), next_midnight) - max(datetime.fromisoformat(b['start_at']), midnight)).total_seconds() / 60)
                          for b in blocks if b['status'] not in ('superseded', 'cancelled'))
    feedback_by_block = {f["block_id"]: f for f in state["feedbacks"]}
    labels = {"done": "用户确认完成", "partial": "部分完成", "waiting": "等待结果", "interrupted": "被打断", "not_started": "未开始"}
    lines = [f"# {day} 日终回顾", "", "## 你的原文", "", original, "", "## 睡眠", ""]
    nights = [s for s in state.get("sleeps", []) if s.get("woke_at")
              and datetime.fromisoformat(s["woke_at"]).astimezone(zone).date().isoformat() == day]
    for night in nights:
        slept = datetime.fromisoformat(night["slept_at"]).astimezone(zone)
        woke = datetime.fromisoformat(night["woke_at"]).astimezone(zone)
        minutes = int((woke - slept).total_seconds() // 60)
        quality = f"，自评 {night['quality']}/5" if night.get("quality") else ""
        lines.append(f"- {slept:%m-%d %H:%M} 入睡，{woke:%H:%M} 醒来，共 {minutes // 60} 小时 {minutes % 60} 分{quality}")
    if not nights:
        lines.append("没有记录。")
    lines += ["", "## 计划与实际投入", "", f"计划 {int(planned_minutes)} 分钟；计时记录实际投入 {int(actual_seconds // 60)} 分钟。", "等待结果不计入实际投入；没有计时记录的完成反馈只作为用户报告。", "", "## 安排与结果", ""]
    for block in blocks:
        feedback = feedback_by_block.get(block["id"])
        status = labels[feedback["choice"]] if feedback else {"superseded": "原安排已调整", "cancelled": "已撤下"}.get(block['status'], "未确认")
        lines.append(f"- {block['title']}：{status}")
        if feedback and feedback["outcome_text"]:
            lines.append(f"  - 结果说明：{feedback['outcome_text']}")
    if not blocks:
        lines.append("当天没有安排记录。现有任务结果仍未确认。")
    lines += ["", "计时记录、用户反馈与实际交付分别保存；沉默不推定完成。", ""]
    materials = [m for m in state.get('materials', []) if m['date'] == day]
    analyses = [a for a in state.get('analyses', []) if a['date'] == day]
    if materials:
        lines += ['## 学习与实验材料', '']
        for item in materials:
            lines += [f"- {item['name']} · SHA-256 {item['sha256']}", f"  - 用户说明：{item['description']}"]
    if analyses:
        lines += ['','## AI 复盘（生成内容，依据材料核对）', '', analyses[-1]['text'], '']
    return {"actual_minutes": int(actual_seconds // 60), "planned_minutes": int(planned_minutes), "executed_sessions": execution_count, "materials": materials, "analyses": analyses, "date": day, "original": original, "markdown": "\n".join(lines), "blocks": blocks, "sleeps": nights,
            "feedbacks": [feedback_by_block[b["id"]] for b in blocks if b["id"] in feedback_by_block],
            "version": reviews[-1]["version"] if reviews else 0}


def flush_archives(store, now=None):
    with store.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        state = store.state(conn)
        changed = False
        for job in state["jobs"]:
            if job["status"] != "pending":
                continue
            review = next(r for r in state["reviews"] if r["id"] == job["review_id"])
            report = report_for(state, review["date"], now)
            folder = store.directory / "archives"
            job["attempts"] += 1
            try:
                folder.mkdir(exist_ok=True)
                for name, content in [(f"{review['date']}.md", report["markdown"]),
                                      (f"{review['date']}.json", json.dumps(report, ensure_ascii=False, indent=2))]:
                    target = folder / name
                    temporary = target.with_suffix(target.suffix + ".tmp")
                    temporary.write_text(content, encoding="utf-8")
                    temporary.replace(target)
                # Retain each submitted original even after a later revision.
                versions = folder / "versions"
                versions.mkdir(exist_ok=True)
                (versions / f"{review['date']}-v{review['version']}.json").write_text(json.dumps(review, ensure_ascii=False, indent=2), encoding="utf-8")
                job["status"] = "done"
                review["archive_status"] = "saved"
            except OSError:
                review["archive_status"] = "pending"
            changed = True
        if changed:
            store.save(conn, state)
