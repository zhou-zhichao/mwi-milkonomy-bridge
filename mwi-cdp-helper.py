#!/usr/bin/env python3
"""CDP helper for keep-alive script - inject hooks, capture WebSocket data."""
import socket, json, urllib.request, base64, os, struct, sys, time

PORT = 9222

class CDPSession:
    """持久 CDP 连接, 支持多次调用"""
    def __init__(self, ws_url, port=PORT):
        path = ws_url.split(f":{port}", 1)[1]
        self.s = socket.create_connection(("127.0.0.1", port))
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.send(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += self.s.recv(4096)
        self.s.settimeout(15)
        self.next_id = 0

    def call(self, method, params=None):
        self.next_id += 1
        msg_id = self.next_id
        payload = json.dumps({"id": msg_id, "method": method, "params": params or {}}).encode()
        mk = os.urandom(4)
        masked = bytes(b ^ mk[i % 4] for i, b in enumerate(payload))
        frame = bytes([0x81])
        L = len(payload)
        if L < 126:
            frame += bytes([0x80 | L])
        elif L < 65536:
            frame += bytes([0x80 | 126]) + struct.pack(">H", L)
        else:
            frame += bytes([0x80 | 127]) + struct.pack(">Q", L)
        frame += mk + masked
        self.s.send(frame)
        while True:
            data = self._read_frame()
            if data is None:
                return None
            try:
                r = json.loads(data)
            except:
                continue
            if r.get("id") == msg_id:
                return r

    def _read_frame(self):
        hdr = self.s.recv(2)
        if not hdr or len(hdr) < 2:
            return None
        op = hdr[1] & 0x7F
        if op == 126:
            L = struct.unpack(">H", self.s.recv(2))[0]
        elif op == 127:
            L = struct.unpack(">Q", self.s.recv(8))[0]
        else:
            L = op
        data = b""
        while len(data) < L:
            chunk = self.s.recv(min(65536, L - len(data)))
            if not chunk:
                break
            data += chunk
        return data

    def close(self):
        try:
            self.s.close()
        except:
            pass

def ws_call(ws_url, port, method, params=None):
    """简易单次调用 (向后兼容)"""
    sess = CDPSession(ws_url, port)
    try:
        return sess.call(method, params)
    finally:
        sess.close()

def get_page_target(port=PORT):
    targets = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list").read())
    pages = [t for t in targets if t.get("type") == "page"]
    if not pages:
        # Create a new page
        urllib.request.urlopen(f"http://127.0.0.1:{port}/json/new").read()
        time.sleep(1)
        targets = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list").read())
        pages = [t for t in targets if t.get("type") == "page"]
    return pages[0]

HOOK_JS = r"""
(function() {
    var dataProperty = Object.getOwnPropertyDescriptor(MessageEvent.prototype, "data");
    if (!dataProperty || !dataProperty.get) return;
    var oriGet = dataProperty.get;
    dataProperty.get = function() {
        var socket = this.currentTarget;
        if (!(socket instanceof WebSocket)) return oriGet.call(this);
        if (!socket.url || socket.url.indexOf("milkywayidle") < 0) return oriGet.call(this);
        var message = oriGet.call(this);
        Object.defineProperty(this, "data", { value: message });
        try {
            if (typeof message === "string") {
                var msg = JSON.parse(message);
                if (msg.type === "init_character_data") {
                    window.__mwiCharData = msg;
                    window.__mwiCharDataTs = Date.now();
                }
            }
        } catch(e) {}
        return message;
    };
    Object.defineProperty(MessageEvent.prototype, "data", dataProperty);
})();
"""

cmd = sys.argv[1] if len(sys.argv) > 1 else "help"

if cmd == "inject_hook":
    page = get_page_target()
    sess = CDPSession(page["webSocketDebuggerUrl"], PORT)
    sess.call("Page.enable")
    r = sess.call("Page.addScriptToEvaluateOnNewDocument", {"source": HOOK_JS})
    sess.close()
    print(json.dumps(r))

if cmd == "inject_and_navigate":
    # 注入 hook + 立刻导航 (在同一个 session 内)
    url = sys.argv[2]
    page = get_page_target()
    sess = CDPSession(page["webSocketDebuggerUrl"], PORT)
    sess.call("Page.enable")
    r = sess.call("Page.addScriptToEvaluateOnNewDocument", {"source": HOOK_JS})
    print("hook:", json.dumps(r))
    r = sess.call("Page.navigate", {"url": url})
    print("nav:", json.dumps(r))
    sess.close()
elif cmd == "navigate":
    url = sys.argv[2]
    page = get_page_target()
    r = ws_call(page["webSocketDebuggerUrl"], PORT, "Page.navigate", {"url": url})
    print(json.dumps(r))
elif cmd == "get_char_data":
    max_age = int(sys.argv[2]) if len(sys.argv) > 2 else 60  # 默认最多接受 60 秒前的数据
    page = get_page_target()
    sess = CDPSession(page["webSocketDebuggerUrl"], PORT)
    # 检查时间戳 (新版 hook 会设置 __mwiCharDataTs)
    ts_r = sess.call("Runtime.evaluate",
                      {"expression": "window.__mwiCharDataTs || 0", "returnByValue": True})
    ts = ts_r.get("result", {}).get("result", {}).get("value", 0)
    if ts > 0:
        now_r = sess.call("Runtime.evaluate",
                           {"expression": "Date.now()", "returnByValue": True})
        now = now_r.get("result", {}).get("result", {}).get("value", 0)
        age_s = (now - ts) / 1000
        if age_s > max_age:
            print(f"char data is {age_s:.0f}s old (max {max_age}s), rejecting as stale", file=sys.stderr)
            sess.close()
            sys.exit(1)
        print(f"char data age: {age_s:.0f}s", file=sys.stderr)
    else:
        print("char data has no timestamp (legacy hook), accepting if present", file=sys.stderr)
    # 读取数据
    r = sess.call("Runtime.evaluate",
                   {"expression": "JSON.stringify(window.__mwiCharData || null)", "returnByValue": True})
    sess.close()
    val = r.get("result", {}).get("result", {}).get("value")
    if val and val != "null":
        print(val)
    else:
        sys.exit(1)
