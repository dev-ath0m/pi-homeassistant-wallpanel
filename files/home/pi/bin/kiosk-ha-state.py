#!/usr/bin/env python3
"""Inspect/repair the kiosk page via Chromium's localhost debug port.

No arguments: print the WallPanel screensaver state as seen by the page,
using the page's own HA session (no token needed):
  off         screensaver off (HA motion control), black screen is expected
  on          screensaver on and a slideshow image is loaded
  on-noimage  screensaver on but no image loaded (WallPanel gave up fetching
              its media list, e.g. after a dropped HA websocket)
--reload: reload the page, then switch the boolean back on (WallPanel resets
it to off on every page load), so the slideshow starts again.

Exit codes: 0 ok, 2 debug port/page unreachable, 3 page did not answer in time
(hung renderer), 4 page up but state not available yet.
"""
import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.parse
import urllib.request

ENTITY = "input_boolean.wallpanel_screensaver_local"
PORT = 9222
TIMEOUT = 10

STATE_EXPR = (
    '(()=>{const h=document.querySelector("home-assistant");'
    f'const s=h&&h.hass&&h.hass.states["{ENTITY}"];if(!s)return "unavailable";'
    'if(s.state!=="on")return s.state;'
    'const m=h.shadowRoot&&h.shadowRoot.children[0]&&h.shadowRoot.children[0].shadowRoot;'
    'const w=m&&m.querySelector("wallpanel-view");'
    'const ok=w&&w.shadowRoot&&[...w.shadowRoot.querySelectorAll("img")].some(i=>i.naturalWidth>0);'
    'return ok?"on":"on-noimage"})()'
)
TURN_ON_EXPR = (
    '(async()=>{await document.querySelector("home-assistant").hass.callService('
    f'"input_boolean","turn_on",{{entity_id:"{ENTITY}"}});return "ok"}})()'
)


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def read_message(sock):
    data = b""
    while True:
        b1, b2 = recv_exact(sock, 2)
        fin, opcode, length = b1 & 0x80, b1 & 0x0F, b2 & 0x7F
        if length == 126:
            length = struct.unpack(">H", recv_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack(">Q", recv_exact(sock, 8))[0]
        payload = recv_exact(sock, length)
        if opcode == 8:
            raise ConnectionError("closed")
        if opcode in (1, 2, 0):
            data += payload
            if fin:
                return data


def send_text(sock, text):
    payload = text.encode()
    mask = os.urandom(4)
    n = len(payload)
    if n < 126:
        header = struct.pack(">BB", 0x81, 0x80 | n)
    elif n < 65536:
        header = struct.pack(">BBH", 0x81, 0x80 | 126, n)
    else:
        header = struct.pack(">BBQ", 0x81, 0x80 | 127, n)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(header + mask + masked)


def cdp(method, params):
    """Run one DevTools command on the kiosk page and return its result dict."""
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json", timeout=3) as r:
        tabs = json.load(r)
    page = next((t for t in tabs if t.get("type") == "page"), None)
    if page is None:
        raise LookupError("no page")
    url = urllib.parse.urlparse(page["webSocketDebuggerUrl"])
    sock = socket.create_connection((url.hostname, url.port), timeout=TIMEOUT)
    sock.settimeout(TIMEOUT)
    with sock:
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall(
            (
                f"GET {url.path} HTTP/1.1\r\nHost: {url.hostname}:{url.port}\r\n"
                f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += sock.recv(1024)
        if b" 101 " not in resp.split(b"\r\n", 1)[0]:
            raise LookupError("handshake failed")
        send_text(sock, json.dumps({"id": 1, "method": method, "params": params}))
        while True:
            msg = json.loads(read_message(sock))
            if msg.get("id") == 1:
                return msg.get("result", {})


def evaluate(expr, await_promise=False):
    res = cdp(
        "Runtime.evaluate",
        {"expression": expr, "returnByValue": True, "awaitPromise": await_promise},
    )
    return res.get("result", {}).get("value")


def reload_and_restore():
    cdp("Page.reload", {})
    time.sleep(5)
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            if evaluate(STATE_EXPR) in ("on", "off", "on-noimage"):
                break
        except (OSError, ValueError, LookupError):
            pass
        time.sleep(2)
    else:
        return 3
    time.sleep(8)  # WallPanel resets the boolean to off during its own startup
    evaluate(TURN_ON_EXPR, await_promise=True)
    return 0


def main():
    try:
        if "--reload" in sys.argv:
            return reload_and_restore()
        state = evaluate(STATE_EXPR)
    except socket.timeout:
        return 3
    except (OSError, ValueError, LookupError):
        return 2
    if state in ("on", "off", "on-noimage"):
        print(state)
        return 0
    return 4


if __name__ == "__main__":
    sys.exit(main())
