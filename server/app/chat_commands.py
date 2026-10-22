"""通道无关的「用聊天指挥日程」大脑。

微信和 QQ 只是两条管道，说的是同一套话：绑定之后发「今天」「完成了」「撤销」，
或者直接说想安排什么。所有日程写入都经过 AssistantService，绑定的是哪个通道
只是记在操作的 device 字段上，业务语义完全一致。
"""
import re
from datetime import timedelta
from zoneinfo import ZoneInfo

from .domain import DomainError, parse

HELP = ("我是你的瞬时助手。\n"
        "· 直接说想安排什么，比如「明晚八点学两小时算法」\n"
        "· 「今天」查看今天的安排\n"
        "· 我会直接改好日程，不对就回复「撤销」\n"
        "· 到点后可回复「完成了」或「再给我15分钟」\n"
        "· 提前结束时我会问要不要把后面的安排提前，回「提前」即可\n"
        "· 「今日总结：……」保存原文，「记住：……」保存偏好\n"
        "· 「取消 某某」「把午饭挪到一点」也可以直接说")

COMMAND = re.compile(r"(完成了?|结束并完成|再给我(?:15|30)分钟|续时(?:15|30)分钟)(?:\s+([0-9a-fA-F]{6}))?")
REVIEW = re.compile(r"今日总结[：:]\s*(.{1,10000})", re.S)
UNDO = re.compile(r"^(撤销|撤回|undo)\s*([0-9a-fA-F]{4})?$", re.IGNORECASE)
CONFIRM = re.compile(r"^(确认|照办|照此办理|办|好的?|可以|ok)\s*([0-9a-fA-F]{4})?$", re.IGNORECASE)
DISMISS = re.compile(r"^(不必|算了|不用了?|放下)\s*([0-9a-fA-F]{4})?$")
EARLY = re.compile(r"^提前\s*([0-9a-fA-F]{4})?$")


def split_text(text, size):
    """Split at line breaks so each part fits one message; long lines are cut hard."""
    parts, current = [], ""
    for line in text.split("\n"):
        while len(line) > size:
            if current:
                parts.append(current)
                current = ""
            parts.append(line[:size])
            line = line[size:]
        candidate = f"{current}\n{line}" if current else line
        if len(candidate) > size:
            parts.append(current)
            current = line
        else:
            current = candidate
    if current or not parts:
        parts.append(current)
    return parts


class ChatCommands:
    """把一句话变成一次回复。device 只影响记账和幂等前缀，不影响语义。"""

    def __init__(self, store, clock, assistant, device):
        self.store, self.clock, self.assistant, self.device = store, clock, assistant, device

    async def reply(self, text, request_id=None):
        """Reply text for one bound-user message."""
        compact = text.strip()
        command = COMMAND.fullmatch(compact)
        review = REVIEW.fullmatch(compact)
        operation_id = f"{self.device}-command:{request_id}" if request_id else None
        if operation_id:
            with self.store.connect() as conn:
                previous = conn.execute('SELECT response FROM operations WHERE id=?', (operation_id,)).fetchone()
            if previous:
                return '这条反馈已经记录，日程已同步。'
        if review:
            day = self.clock().astimezone(ZoneInfo(self.store.state()['settings']['timezone'])).date().isoformat()
            self.assistant.apply_operation('review.save', {'date': day, 'text': review.group(1)}, self.device, operation_id)
            return '今日原文已保留并安排电脑归档。材料复盘可在瞬时的回顾页生成。'
        if command:
            return self.finish(command, request_id, operation_id)
        if compact in ("帮助", "help", "?", "？"):
            return HELP
        if compact in ("今天", "今日", "今天的安排"):
            return self.today_summary()
        if compact in ('记忆', '你记住了什么'):
            memories = self.store.state().get('memories', [])
            return '\n'.join(['你明确让我记住的事：', *[m['text'] for m in memories]]) if memories else '目前还没有保存的长期偏好。'
        undo = UNDO.match(compact)
        if undo:
            return self.undo(undo.group(2))
        early = EARLY.match(compact)
        if early:
            answer = self.apply_early(early.group(1), operation_id)
            if answer is not None:
                return answer
        match = CONFIRM.match(compact) or DISMISS.match(compact)
        if match:
            answer = self.decide(bool(CONFIRM.match(compact)), match.group(2))
            if answer is not None:
                return answer
        try:
            rows = await self.assistant.converse(compact, request_id=request_id, device_id=self.device)
        except DomainError as error:
            if error.code == "ASSISTANT_NOT_CONFIGURED":
                return "模型服务还没在电脑上配置好，我暂时只能回答「今天」「帮助」。"
            return error.message
        return self.render(rows[-1])

    def finish(self, command, request_id, operation_id):
        """「完成了」「再给我15分钟」这类到点反馈。"""
        from .maintenance import expire_due
        expire_due(self.store, self.clock())
        state = self.store.state()
        candidates = [s for s in state['sessions'] if s['state'] in ('running', 'paused', 'awaiting_feedback')]
        if command.group(2):
            candidates = [s for s in candidates if s['id'].startswith(command.group(2).lower())]
        if len(candidates) != 1:
            return '请说明是哪一段，或打开瞬时选择待回话的任务。'
        session = candidates[0]
        if command.group(1).startswith(('再给我', '续时')):
            minutes = int(re.search(r'15|30', command.group(1)).group())
            try:
                changed = self.assistant.apply_operation('session.extend', {'id': session['id'], 'minutes': minutes}, self.device, operation_id)['entity']
                end = parse(changed['expected_end_at']).astimezone(ZoneInfo(state['settings']['timezone']))
                adjustment = changed.get('adjustment', {}).get('status')
                tail = '后续弹性安排已顺延。' if adjustment == 'applied' else '后续有冲突或需要确认，请到瞬时查看调整。' if adjustment in ('proposal', 'blocked') else ''
                return f'已增加 {minutes} 分钟，预计 {end:%H:%M} 收尾。{tail}'
            except DomainError as error:
                return error.message
        if session['state'] in ('running', 'paused'):
            self.assistant.apply_operation('session.end', {'id': session['id']}, self.device, f'{self.device}-end:{request_id}' if request_id else None)
        self.assistant.apply_operation('feedback.create', {'session_id': session['id'], 'choice': 'done',
                                                          'outcome_text': f'用户在{self.channel_name}确认完成'}, self.device, operation_id)
        return '已记录完成，相关追问已停止。'

    @property
    def channel_name(self):
        return 'QQ' if self.device == 'qq' else '微信'

    def render(self, reply):
        """把模型的一条回复排成一条消息：执行过的改动 + 等你确认的拟办。"""
        lines = [reply["text"]]
        for draft in reply["drafts"]:
            code = draft["id"][:4].upper()
            if draft["status"] == "applied":
                lines += [f"· {line}" for line in draft["lines"]]
                if draft["undoable"]:
                    lines.append(f"不对的话回复「撤销 {code}」。")
            elif draft["status"] == "pending":
                lines += ["", f"【拟办 {code}】{draft['summary']}", *(f"· {line}" for line in draft["lines"]),
                          f"回复「确认 {code}」照此办理，「不必 {code}」放下。"]
        return "\n".join(lines)

    def undo(self, code):
        with self.store.connect() as conn:
            rows = conn.execute("SELECT d.id, d.summary, d.created_at FROM assistant_drafts d JOIN assistant_undo u "
                                "ON u.draft_id=d.id WHERE d.status='applied' ORDER BY d.created_at DESC").fetchall()
        if code:
            matches = [r for r in rows if r["id"][:4].lower() == code.lower()]
        else:  # A bare "撤销" means the assistant's latest change, if it is recent.
            matches = [r for r in rows[:1] if parse(r["created_at"]) >= self.clock() - timedelta(minutes=30)]
        if len(matches) != 1:
            return "没有找到可以撤销的这条改动，可能已经撤销过了。请到瞬时的助手页查看。"
        try:
            self.assistant.undo_draft(matches[0]["id"], self.device)
        except DomainError as error:
            return error.message
        return f"已撤销：{matches[0]['summary']}。"

    def apply_early(self, code, operation_id=None):
        """Apply a pending pull-earlier proposal created after an early end."""
        state = self.store.state()
        now = self.clock()
        drafts = [p for p in state.get('proposals', [])
                  if p['status'] == 'draft' and p.get('kind') == 'early'
                  and p.get('base_revision') == state['revision'] and parse(p['expires_at']) > now]
        if code:
            drafts = [p for p in drafts if p['id'][:4].lower() == code.lower()]
        if not drafts:
            return '现在没有可以提前的安排，可能已经处理过或日程有变。到瞬时里看看当前安排吧。'
        if len(drafts) > 1:
            codes = '、'.join(p['id'][:4].upper() for p in drafts)
            return f'有几份提前建议在等你：{codes}。请带上编号，比如「提前 {drafts[0]["id"][:4].upper()}」。'
        proposal = drafts[0]
        try:
            self.assistant.apply_operation('plan.apply', {'proposal_id': proposal['id']}, self.device, operation_id)
        except DomainError as error:
            return error.message
        first = proposal['new_blocks'][0]
        zone = ZoneInfo(state['settings']['timezone'])
        start, end = parse(first['start_at']).astimezone(zone), parse(first['end_at']).astimezone(zone)
        return f"已提前：{first['title']} 改到 {start:%H:%M}–{end:%H:%M}。"

    def decide(self, accept, code):
        with self.store.connect() as conn:
            rows = conn.execute("SELECT id, summary, created_at FROM assistant_drafts WHERE status='pending' "
                                "ORDER BY created_at DESC").fetchall()
        if code:
            matches = [r for r in rows if r["id"][:4].lower() == code.lower()]
        else:  # A bare "确认" only counts when exactly one recent draft is waiting.
            recent = self.clock() - timedelta(minutes=30)
            matches = [r for r in rows if parse(r["created_at"]) >= recent]
            if not matches:
                return None  # Just a casual "好"; let the assistant answer it.
            if len(matches) > 1:
                codes = "、".join(r["id"][:4].upper() for r in matches)
                return f"现在有几条拟办在等你：{codes}。请带上编号，比如「确认 {matches[0]['id'][:4].upper()}」。"
        if not matches:
            return "没有找到等你确认的这条拟办，可能已经处理过或过期了。"
        if len(matches) > 1:
            return "这个编号对应了不止一条拟办，请到 App 的助手页确认。"
        draft = matches[0]
        try:
            if accept:
                self.assistant.apply_draft(draft["id"], self.device)
                return f"已照此办理：{draft['summary']}。"
            self.assistant.dismiss_draft(draft["id"])
            return f"好，放下了：{draft['summary']}。"
        except DomainError as error:
            return f"没能执行：{error.message}"

    def today_summary(self):
        state = self.store.state()
        zone = ZoneInfo(state["settings"]["timezone"])
        now = self.clock().astimezone(zone)
        blocks = sorted((b for b in state["blocks"] if b["status"] in ("scheduled", "completed", "skipped")
                         and parse(b["start_at"]).astimezone(zone).date() == now.date()),
                        key=lambda b: b["start_at"])
        if not blocks:
            return f"{now:%m月%d日}还没有安排。想做什么，直接告诉我。"
        marks = {"completed": "✓ ", "skipped": "· 未开始 "}
        lines = [f"{now:%m月%d日}的安排："]
        for block in blocks:
            start = parse(block["start_at"]).astimezone(zone)
            end = parse(block["end_at"]).astimezone(zone)
            lines.append(f"{marks.get(block['status'], '')}{start:%H:%M}–{end:%H:%M} {block['title']}")
        return "\n".join(lines)
