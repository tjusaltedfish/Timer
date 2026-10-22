"""把「该由哪条通道把提醒送出去」收在一个地方。

QQ 绑定好之后它就是主通道（用户要的就是这个）；在那之前微信继续负责，
所以切换不需要改 proactive.py / weekly.py 一行代码 —— 它们只会看到
一个和通道长得一样的对象。
"""


class RoutedChannel:
    def __init__(self, wechat, qq):
        self.wechat, self.qq = wechat, qq

    @property
    def active(self):
        conf = self.qq.settings.load()
        return self.qq if conf["bound_openid"] else self.wechat

    @property
    def settings(self):
        return self.active.settings

    def _enqueue(self, conn, openid, text, now, key=None, not_before=None, expires_at=None):
        return self.active._enqueue(conn, openid, text, now, key=key, not_before=not_before,
                                    expires_at=expires_at)

    def enqueue(self, text, key=None, not_before=None, expires_at=None):
        return self.active.enqueue(text, key=key, not_before=not_before, expires_at=expires_at)

    def enqueue_to(self, openid, text, key=None, not_before=None, expires_at=None):
        """WeChat follower addressed by openid (single-account legacy path)."""
        channel = getattr(self, "wechat", None)
        if channel is None or not hasattr(channel, "enqueue_to"):
            raise AttributeError("enqueue_to requires a WeChat channel")
        return channel.enqueue_to(openid, text, key=key, not_before=not_before, expires_at=expires_at)

    def send_to(self, channel, openid, text, key=None, not_before=None, expires_at=None):
        """Address one person on the channel they actually bound (wechat or qq)."""
        target = self.wechat if channel == "wechat" else self.qq
        if not hasattr(target, "enqueue_to"):
            raise AttributeError(f"{channel} channel cannot address one person")
        return target.enqueue_to(openid, text, key=key, not_before=not_before, expires_at=expires_at)
