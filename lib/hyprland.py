import json
import os
import socket


def socket_path() -> str:
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    if not sig:
        return ""
    base = os.path.join("/run/user", str(os.getuid()), "hypr", sig)
    path = os.path.join(base, ".socket.sock")
    return path if os.path.exists(path) else ""


def command(request: str) -> str:
    """Send a raw request to the command socket; return the response."""
    path = socket_path()
    if not path:
        return ""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
        s.sendall(request.encode())
        s.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks).decode(errors="replace")
    except OSError as e:
        print("hyprland socket failed: %s" % e, flush=True)
        return ""
    finally:
        s.close()


def clients() -> list:
    data = command("j/clients")
    if not data:
        return []
    try:
        return json.loads(data)
    except json.JSONDecodeError:
        return []


def eval_lua(lua: str) -> str:
    return command("eval " + lua)


def register_workspace_rule(rule_name: str, class_hint: str, workspace: str) -> str:
    q = chr(34)
    lua = ("hl.window_rule({ name = " + q + "laya-ws-" + rule_name + "-" + class_hint
            + q + ", match = { class = " + q + class_hint + q + " }, workspace = "
            + q + workspace + q + " })")
    return eval_lua(lua)


def move_windows(class_hint: str, workspace: str) -> int:
    moved = 0
    for c in clients():
        if str(c.get("class", "")).lower() == class_hint:
            command("dispatch movetoworkspacesilent " + workspace)
            moved += 1
    return moved
