#!/usr/bin/env python3
"""Thử giao thức Unix socket của roost-hook (Sources/NotchHook) bằng một app Roost giả.

    swift build --product notch-hook
    python3 -I scripts/test_hook.py [đường dẫn tới notch-hook]

Mặc định dùng .build/debug/notch-hook. Không đụng tới Roost thật: mỗi ca dựng socket riêng trong /tmp
và trỏ hook tới đó bằng ROOST_HOOK_SOCKET. Điều kiện chung của mọi ca: hook luôn thoát 0, chỉ in ra
khi app trả một quyết định PermissionRequest hợp lệ (allow / deny), và không bao giờ treo quá hạn.
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ROOT, ".build/debug/notch-hook")

REQUEST = {
    "hook_event_name": "PermissionRequest",
    "session_id": "sess-A",
    "tool_name": "Bash",
    "tool_input": {"command": "npm test"},
    "permission_suggestions": [],
}


def decision(behavior, event="PermissionRequest"):
    return {"hookSpecificOutput": {"hookEventName": event, "decision": {"behavior": behavior}}}


class FakeApp:
    """App giả nghe trên socket. mode: reply | close | silent | noread."""

    def __init__(self, path, mode="reply", reply=b"", chunks=1, delay=0.0):
        self.path, self.mode, self.reply, self.chunks, self.delay = path, mode, reply, chunks, delay
        self.received = b""
        self.connections = 0
        self.stop = threading.Event()
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(4)
        self.sock.settimeout(0.1)
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.connections += 1
            self.serve(conn)

    def serve(self, conn):
        conn.settimeout(0.1)
        try:
            if self.mode == "noread":
                self.stop.wait()
                return
            while b"\n" not in self.received and not self.stop.is_set():
                try:
                    data = conn.recv(65536)
                except socket.timeout:
                    continue
                if not data:
                    return
                self.received += data
            if self.delay:
                time.sleep(self.delay)
            if self.mode == "reply":
                size = max(1, len(self.reply) // self.chunks)
                for i in range(0, len(self.reply), size):
                    conn.sendall(self.reply[i:i + size])
                    if self.chunks > 1:
                        time.sleep(0.15)
            elif self.mode == "silent":
                # Giữ kết nối cho tới khi hook tự đóng.
                while not self.stop.is_set():
                    try:
                        if not conn.recv(65536):
                            return
                    except socket.timeout:
                        continue
            # close: đóng luôn, không trả lời.
        except OSError:
            pass
        finally:
            conn.close()

    def message(self):
        line = self.received.split(b"\n", 1)[0]
        return json.loads(line) if line else None

    def close(self):
        self.stop.set()
        self.sock.close()
        self.thread.join(2)


def run_hook(sock_path, payload, timeout=2, args=(), env=None, close_stdin=True, during=None):
    full_env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE_", "ROOST_", "NOTCH_"))}
    full_env.update({"ROOST_HOOK_SOCKET": sock_path, "NOTCH_HOOK_TIMEOUT": str(timeout)})
    full_env.update(env or {})
    data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
    start = time.monotonic()
    proc = subprocess.Popen([HOOK, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=full_env)
    writer = None
    if close_stdin:
        # Ghi trong luồng riêng: payload lớn có thể chặn cho tới khi hook đọc.
        def feed():
            try:
                proc.stdin.write(data)
                proc.stdin.close()
            except OSError:
                pass
        writer = threading.Thread(target=feed, daemon=True)
        writer.start()
    else:
        proc.stdin.write(data)
        proc.stdin.flush()
    if during:
        during(proc)
    try:
        out, err = proc.communicate(timeout=timeout + 10) if close_stdin else (proc.stdout.read(), proc.stderr.read())
        proc.wait(timeout=timeout + 10)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise AssertionError("hook treo quá timeout + 10 s")
    finally:
        if not close_stdin:
            proc.stdin.close()
    return proc.returncode, out, time.monotonic() - start


class Case:
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="rh", dir="/tmp")  # sun_path tối đa 104 byte
        self.sock = os.path.join(self.dir, "claude.sock")
        self.app = None

    def serve(self, **kw):
        self.app = FakeApp(self.sock, **kw)
        return self.app

    def cleanup(self):
        if self.app:
            self.app.close()
        shutil.rmtree(self.dir, ignore_errors=True)


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


def expect_silent(code, out):
    check(code == 0, f"exit {code}, muốn 0")
    check(out == b"", f"không được in gì, nhận {out[:200]!r}")


# ---- Các ca --------------------------------------------------------------

def t_allow(c):
    reply = json.dumps(decision("allow")).encode() + b"\n"
    app = c.serve(reply=reply)
    code, out, dt = run_hook(c.sock, REQUEST)
    check(code == 0 and out == reply, f"phải in nguyên câu trả lời, nhận {out!r}")
    check(dt < 1.5, f"chậm {dt:.2f}s")
    msg = app.message()
    meta = msg["roost"]
    check(msg["tool_name"] == "Bash" and msg["tool_input"] == {"command": "npm test"}, "payload gốc phải giữ nguyên")
    check(meta["timeout"] == 2 and meta["hook_pid"] > 0 and meta["claude_pid"] == os.getpid(), f"meta sai: {meta}")
    check(len(meta["request_id"]) == 36 and "agent" not in meta, f"meta sai: {meta}")


def t_deny_with_codex_and_host(c):
    reply = json.dumps({**decision("deny"), "extra": "x"}).encode() + b"\n"
    app = c.serve(reply=reply)
    code, out, _ = run_hook(c.sock, REQUEST, args=["--codex"],
                            env={"CLAUDE_PROJECT_DIR": "/tmp/proj", "TERM_PROGRAM": "iTerm.app"})
    check(code == 0 and out == reply, f"phải in deny, nhận {out!r}")
    meta = app.message()["roost"]
    check(meta.get("agent") == "codex", "--codex phải gắn agent=codex")
    check(meta.get("project_dir") == "/tmp/proj" and meta.get("term_program") == "iTerm.app", f"meta sai: {meta}")


def t_chunked_reply(c):
    reply = json.dumps(decision("allow")).encode() + b"\n"
    c.serve(reply=reply, chunks=4)
    code, out, _ = run_hook(c.sock, REQUEST)
    check(code == 0 and out == reply, f"trả lời chia mảnh phải ghép lại, nhận {out!r}")


def t_reply_after_newline_ignored(c):
    reply = json.dumps(decision("allow")).encode()
    c.serve(reply=reply + b"\ngarbage after newline")
    code, out, _ = run_hook(c.sock, REQUEST)
    check(code == 0 and out == reply + b"\n", f"chỉ in dòng đầu, nhận {out!r}")


def t_malformed(c):
    c.serve(reply=b"{not json\n")
    expect_silent(*run_hook(c.sock, REQUEST)[:2])


def t_wrong_event(c):
    c.serve(reply=json.dumps(decision("allow", event="PreToolUse")).encode() + b"\n")
    expect_silent(*run_hook(c.sock, REQUEST)[:2])


def t_ask_behavior(c):
    c.serve(reply=json.dumps(decision("ask")).encode() + b"\n")
    expect_silent(*run_hook(c.sock, REQUEST)[:2])


def t_eof(c):
    c.serve(mode="close")
    code, out, dt = run_hook(c.sock, REQUEST)
    expect_silent(code, out)
    check(dt < 1.5, f"EOF phải thoát ngay, mất {dt:.2f}s")


def t_silent_app(c):
    c.serve(mode="silent")
    code, out, dt = run_hook(c.sock, REQUEST, timeout=2)
    expect_silent(code, out)
    check(1.8 <= dt < 3.5, f"phải chờ đúng timeout 2s, mất {dt:.2f}s")


def t_late_reply(c):
    c.serve(reply=json.dumps(decision("allow")).encode() + b"\n", delay=2.5)
    code, out, dt = run_hook(c.sock, REQUEST, timeout=1)
    expect_silent(code, out)
    check(dt < 2.5, f"quá hạn thì bỏ, mất {dt:.2f}s")


def t_stale_socket(c):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(c.sock)
    s.close()  # file socket còn, không ai nghe
    code, out, dt = run_hook(c.sock, REQUEST)
    expect_silent(code, out)
    check(dt < 1.0, f"socket cũ phải thoát ngay, mất {dt:.2f}s")


def t_no_socket(c):
    code, out, dt = run_hook(c.sock, REQUEST)
    expect_silent(code, out)
    check(dt < 1.0, f"không có socket phải thoát ngay, mất {dt:.2f}s")


def t_big_payload_not_read(c):
    c.serve(mode="noread")
    big = dict(REQUEST, tool_input={"content": "x" * (5 * 1024 * 1024)})
    code, out, dt = run_hook(c.sock, big, timeout=2)
    expect_silent(code, out)
    check(dt < 5.0, f"app không đọc payload 5 MB, hook phải bỏ trước watchdog, mất {dt:.2f}s")


def t_post_tool_use(c):
    app = c.serve(mode="noread")
    payload = {"hook_event_name": "PostToolUse", "session_id": "sess-A", "tool_name": "Bash",
               "tool_input": {"command": "ls"}, "tool_response": {"stdout": "x" * 100000}}
    code, out, dt = run_hook(c.sock, payload, timeout=30)
    expect_silent(code, out)
    check(dt < 3.5, f"PostToolUse không được chờ app, mất {dt:.2f}s")
    check(app.connections == 1, "PostToolUse phải báo app")


def t_post_tool_use_payload(c):
    app = c.serve(mode="close")
    payload = {"hook_event_name": "PostToolUse", "session_id": "sess-B", "tool_name": "Edit",
               "tool_input": {"file_path": "/tmp/a"}, "tool_response": {"big": "y" * 10000}, "cwd": "/tmp"}
    expect_silent(*run_hook(c.sock, payload)[:2])
    msg = app.message()
    check(msg == {"notch_event": "PostToolUse", "session_id": "sess-B", "tool_name": "Edit",
                  "tool_input": {"file_path": "/tmp/a"}, "cwd": "/tmp"}, f"payload phụ sai: {msg}")


def t_notification(c):
    app = c.serve(mode="close")
    payload = {"hook_event_name": "Notification", "session_id": "s", "message": "Claude needs your input",
               "notification_type": "idle_prompt"}
    expect_silent(*run_hook(c.sock, payload, env={"CLAUDE_PROJECT_DIR": "/tmp/proj"})[:2])
    msg = app.message()
    check(msg["notch_event"] == "Notification" and msg["message"] == "Claude needs your input", f"sai: {msg}")
    check(msg["notification_type"] == "idle_prompt" and msg["project_dir"] == "/tmp/proj", f"sai: {msg}")


def t_claude_killed(c):
    c.serve(mode="silent")
    claude = subprocess.Popen(["sleep", "60"])
    killed_at = []

    def kill_later(_):
        time.sleep(0.5)
        killed_at.append(time.monotonic())
        claude.kill()
        claude.wait()

    try:
        code, out, dt = run_hook(c.sock, REQUEST, timeout=20, env={"CLAUDE_PID": str(claude.pid)}, during=kill_later)
    finally:
        if claude.poll() is None:
            claude.kill()
    expect_silent(code, out)
    check(dt < 2.0, f"Claude Code chết thì hook phải thoát ngay, mất {dt:.2f}s")


def t_claude_already_dead(c):
    c.serve(mode="silent")
    dead = subprocess.Popen(["true"])
    dead.wait()
    code, out, dt = run_hook(c.sock, REQUEST, timeout=20, env={"CLAUDE_PID": str(dead.pid)})
    expect_silent(code, out)
    check(dt < 2.0, f"Claude Code đã chết thì hook không chờ, mất {dt:.2f}s")


def t_stdin_never_closed(c):
    c.serve(mode="silent")
    code, out, dt = run_hook(c.sock, b'{"hook_event_name":', timeout=1, close_stdin=False)
    expect_silent(code, out)
    check(2.5 <= dt < 5.0, f"watchdog phải cắt sau timeout + 2 s, mất {dt:.2f}s")


def t_bad_stdin(c):
    app = c.serve(mode="close")
    expect_silent(*run_hook(c.sock, b"not json")[:2])
    time.sleep(0.2)
    check(app.connections == 0, "JSON hỏng thì không được nối app")


def t_statusline(c):
    app = c.serve(mode="close")
    payload = {"session_id": "s", "rate_limits": {"five_hour": {"used_percentage": 41.6},
                                                    "seven_day": {"used_percentage": 10}}}
    code, out, dt = run_hook(c.sock, payload, args=["--statusline"])
    check(code == 0 and out == b"5h 42%  7d 10%\n", f"statusline sai: {out!r}")
    check(dt < 2.5, f"statusline chậm {dt:.2f}s")
    msg = app.message()
    check(msg["notch_event"] == "Usage" and msg["rate_limits"] == payload["rate_limits"], f"sai: {msg}")


def t_statusline_without_limits(c):
    app = c.serve(mode="close")
    code, out, _ = run_hook(c.sock, {"session_id": "s"}, args=["--statusline"])
    check(code == 0 and out == b"\n", f"statusline không có rate_limits phải in dòng trống, nhận {out!r}")
    time.sleep(0.2)
    check(app.connections == 0, "không có rate_limits thì không nối app")


def t_statusline_app_down(c):
    payload = {"rate_limits": {"five_hour": {"used_percentage": 5}}}
    code, out, dt = run_hook(c.sock, payload, args=["--statusline"])
    check(code == 0 and out == b"5h 5%\n", f"app tắt vẫn phải in statusline, nhận {out!r}")
    check(dt < 1.0, f"mất {dt:.2f}s")


CASES = [
    ("Trả lời allow hợp lệ, payload có meta", t_allow),
    ("Trả lời deny, --codex, app chủ", t_deny_with_codex_and_host),
    ("Trả lời chia nhiều mảnh", t_chunked_reply),
    ("Chỉ in dòng đầu của câu trả lời", t_reply_after_newline_ignored),
    ("Trả lời hỏng", t_malformed),
    ("Trả lời sai hookEventName", t_wrong_event),
    ("Trả lời behavior không hợp lệ", t_ask_behavior),
    ("App đóng kết nối (EOF)", t_eof),
    ("App im lặng tới hết giờ", t_silent_app),
    ("App trả lời sau hạn", t_late_reply),
    ("File socket cũ", t_stale_socket),
    ("Không có socket", t_no_socket),
    ("App không đọc payload 5 MB", t_big_payload_not_read),
    ("PostToolUse không chờ app", t_post_tool_use),
    ("PostToolUse chỉ gửi phần cần", t_post_tool_use_payload),
    ("Notification", t_notification),
    ("Claude Code bị kill giữa lúc chờ", t_claude_killed),
    ("Claude Code đã chết trước", t_claude_already_dead),
    ("stdin không đóng (watchdog)", t_stdin_never_closed),
    ("stdin không phải JSON", t_bad_stdin),
    ("--statusline", t_statusline),
    ("--statusline không có rate_limits", t_statusline_without_limits),
    ("--statusline khi app tắt", t_statusline_app_down),
]


def main():
    if not os.access(HOOK, os.X_OK):
        sys.exit(f"Không thấy hook ở {HOOK}. Chạy: swift build --product notch-hook")
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    failed = 0
    for i, (name, fn) in enumerate(CASES, 1):
        c = Case()
        start = time.monotonic()
        try:
            fn(c)
            print(f"PASS {i:2d}. {name} ({time.monotonic() - start:.2f}s)")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"FAIL {i:2d}. {name}: {e}")
        finally:
            c.cleanup()
    print(f"\n{len(CASES) - failed}/{len(CASES)} PASS")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
