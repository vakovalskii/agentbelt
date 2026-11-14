"""Windows backend for agentbelt: WezTerm instead of iTerm2.

iTerm2 gives agentbelt the active pane, its tty and a way to open/focus tabs. On Windows the
same comes from `wezterm cli` (list panes, focused pane, spawn, split, activate) and from
process data via psutil:

- every process started inside a WezTerm pane inherits WEZTERM_PANE=<pane id>, so a running
  Claude/Codex/pi process is matched to its pane through its environment;
- the pane id plays the role of the tty in the pages: "wez<id>" (the Sessions page only
  compares and sends this string back, it never parses it).

Commands run in PowerShell, so the proxy prefix uses `$env:` assignments.
"""
import asyncio
import json
import os
import shutil
import subprocess
import urllib.parse

try:
    import psutil
except ImportError:  # agentbelt still serves pages; agent detection is off
    psutil = None

PANE_PREFIX = "wez"
CREATE_NO_WINDOW = 0x08000000


def wezterm_exe() -> str:
    found = shutil.which("wezterm")
    if found:
        return found
    for p in (r"C:\Program Files\WezTerm\wezterm.exe", os.path.expandvars(r"%LOCALAPPDATA%\Programs\WezTerm\wezterm.exe")):
        if os.path.isfile(p):
            return p
    return "wezterm"


def gui_socket() -> str | None:
    """Socket of the running WezTerm window process (gui-sock-<pid>). Without it `wezterm cli`
    falls back to a background mux server, which it may even start itself, and then sees
    none of the panes on screen."""
    d = os.path.join(os.path.expanduser("~"), ".local", "share", "wezterm")
    try:
        socks = [os.path.join(d, n) for n in os.listdir(d) if n.startswith("gui-sock-")]
    except OSError:
        return None
    alive = []
    for s in socks:
        pid = s.rsplit("-", 1)[-1]
        if pid.isdigit() and (psutil is None or psutil.pid_exists(int(pid))):
            alive.append(s)
    return max(alive, key=os.path.getmtime) if alive else None


def cli(*args: str, timeout: float = 5) -> tuple[int, str]:
    sock = gui_socket()
    if not sock:
        return 1, "WezTerm is not running"
    env = dict(os.environ, WEZTERM_UNIX_SOCKET=sock)
    try:
        r = subprocess.run([wezterm_exe(), "cli", "--no-auto-start", *args], capture_output=True, text=True,
                           timeout=timeout, encoding="utf-8", errors="replace", creationflags=CREATE_NO_WINDOW, env=env)
        return r.returncode, r.stdout if r.returncode == 0 else r.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


async def acli(*args: str, timeout: float = 5) -> tuple[int, str]:
    return await asyncio.to_thread(cli, *args, timeout=timeout)


def pane_tag(pane_id) -> str:
    return f"{PANE_PREFIX}{pane_id}"


def pane_from_tag(tag: str) -> int | None:
    if tag.startswith(PANE_PREFIX) and tag[len(PANE_PREFIX):].isdigit():
        return int(tag[len(PANE_PREFIX):])
    return None


def cwd_from_url(url: str | None) -> str | None:
    """file:///C:/Users/user/ → C:\\Users\\user (WezTerm reports cwd as a file URL)."""
    if not url:
        return None
    u = urllib.parse.urlsplit(url)
    path = urllib.parse.unquote(u.path if u.scheme == "file" else url)
    if len(path) > 2 and path[0] == "/" and path[2] == ":":
        path = path[1:]
    path = path.replace("/", "\\").rstrip("\\") or path
    if len(path) == 2 and path[1] == ":":
        path += "\\"
    return path if os.path.isdir(path) else None


async def list_panes() -> list[dict]:
    rc, out = await acli("list", "--format", "json")
    if rc != 0:
        return []
    try:
        return json.loads(out)
    except ValueError:
        return []


async def focused_pane_id(panes: list[dict] | None = None) -> int | None:
    rc, out = await acli("list-clients", "--format", "json")
    if rc == 0:
        try:
            clients = json.loads(out)
            ids = [c.get("focused_pane_id") for c in clients if c.get("focused_pane_id") is not None]
            if ids:
                return int(ids[0])
        except ValueError:
            pass
    for p in panes or []:
        if p.get("is_active"):
            return int(p["pane_id"])
    return None


def process_pane(pid: int) -> int | None:
    """WEZTERM_PANE of a process, i.e. the pane it runs in."""
    if psutil is None:
        return None
    try:
        v = psutil.Process(int(pid)).environ().get("WEZTERM_PANE")
    except (psutil.Error, OSError, ValueError):
        return None
    return int(v) if v and v.isdigit() else None


def _claude_sessions(claude_dir: str) -> list[dict]:
    out = []
    sdir = os.path.join(claude_dir, "sessions")
    try:
        names = os.listdir(sdir)
    except OSError:
        return out
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(sdir, n), encoding="utf-8") as f:
                d = json.load(f)
            pid = int(d["pid"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if psutil is not None and not psutil.pid_exists(pid):
            continue
        out.append(d)
    return out


def agent_in_pane(claude_dir: str, pane_id: int | None) -> dict | None:
    """Claude running in the pane: its session metadata (same shape as on macOS)."""
    if pane_id is None:
        return None
    for d in _claude_sessions(claude_dir):
        if process_pane(d["pid"]) == pane_id:
            return {"pid": d.get("pid"), "sid": d.get("sessionId"), "cwd": d.get("cwd"),
                    "name": d.get("name"), "status": d.get("status")}
    return None


def active_agents(claude_dir: str) -> list[dict]:
    """Running Claude (session metadata) and Codex/pi/omp (process list); tty = pane tag."""
    claude: dict[str, dict] = {}
    for d in _claude_sessions(claude_dir):
        a = {"tool": "claude", "pid": d["pid"], "id": d.get("sessionId"), "dir": d.get("cwd", ""),
             "name": d.get("name", ""), "status": d.get("status", ""), "since": d.get("startedAt", 0)}
        k = a["id"] or f"pid:{a['pid']}"
        if k not in claude or (a["since"] or 0) > (claude[k]["since"] or 0):
            claude[k] = a
    out = list(claude.values())
    known = {int(a["pid"]) for a in out}
    if psutil is not None:
        # Claude writes sessions/<pid>.json a moment after start (after the folder-trust
        # prompt); until then the bare process still shows up, without a session id.
        for p in psutil.process_iter(["pid", "name"]):
            try:
                if (p.info.get("name") or "").lower() in ("claude.exe", "claude") and p.pid not in known:
                    out.append({"tool": "claude", "pid": p.pid, "id": "", "dir": p.cwd(), "name": "",
                                "status": "starting", "since": int(p.create_time() * 1000)})
            except (psutil.Error, OSError):
                continue
        for p in psutil.process_iter(["pid", "name", "cmdline"]):
            try:
                cmd = p.info.get("cmdline") or []
                joined = " ".join(cmd)
                # native exe (codex.exe) or a node script (node ...\codex\bin\codex.js)
                stems = [os.path.basename(c).lower().rsplit(".", 1)[0] for c in cmd[:2]]
                tool = next((t for t in ("codex", "pi", "omp") if t in stems), None)
                if not tool or "app-server" in joined:
                    continue
                out.append({"tool": tool, "pid": p.pid, "id": "", "dir": p.cwd(), "name": "", "status": "", "since": 0})
            except (psutil.Error, OSError):
                continue
    for a in out:
        pane = process_pane(a["pid"])
        a["tty"] = pane_tag(pane) if pane is not None else ""
    return out


async def activate(tag: str) -> str:
    pane = pane_from_tag(tag)
    if pane is None:
        return "bad pane"
    rc, out = await acli("activate-pane", "--pane-id", str(pane))
    return "ok" if rc == 0 else f"wezterm: {out.strip()[:200]}"


def shell_argv(command: str) -> list[str]:
    """PowerShell that runs `command` (if any) and stays open, like a terminal tab would."""
    shell = "pwsh.exe" if shutil.which("pwsh") else "powershell.exe"
    return [shell, "-NoLogo", "-NoExit"] + (["-Command", command] if command else [])


def ps_quote(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


async def spawn(cwd: str, command: str, new_window: bool) -> str:
    """New tab (or window) in WezTerm running `command` in PowerShell; the shell stays open."""
    args = ["spawn"]
    if new_window:
        args.append("--new-window")
    if cwd:
        args += ["--cwd", cwd]
    args += ["--", *shell_argv(command)]
    rc, out = await acli(*args, timeout=10)
    if rc != 0:
        return f"wezterm: {out.strip()[:200]}"
    pane = out.strip()
    if pane.isdigit():
        await acli("activate-pane", "--pane-id", pane)
    return "ok"


async def split(pane_id: int, cwd: str, command: str) -> int | None:
    args = ["split-pane", "--pane-id", str(pane_id), "--right"]
    if cwd:
        args += ["--cwd", cwd]
    args += ["--", *shell_argv(command)]
    rc, out = await acli(*args, timeout=10)
    return int(out.strip()) if rc == 0 and out.strip().isdigit() else None


async def set_tab_title(pane_id: int, title: str):
    await acli("set-tab-title", "--pane-id", str(pane_id), title)


async def capture(claude_dir: str, only_window: int | None = None) -> list[dict]:
    """Windows → tabs → panes in the TermDeck snapshot format used on macOS."""
    panes = await list_panes()
    tabs: dict[tuple, dict] = {}
    sessions = _claude_sessions(claude_dir)
    by_pane = {}
    for d in sessions:
        p = process_pane(d["pid"])
        if p is not None:
            by_pane[p] = d
    for p in panes:
        if only_window is not None and p.get("window_id") != only_window:
            continue
        key = (p.get("window_id"), p.get("tab_id"))
        t = tabs.setdefault(key, {"title": p.get("tab_title") or "", "split": "vertical", "panes": []})
        d = by_pane.get(p.get("pane_id"))
        if d and d.get("cwd"):
            t["panes"].append({"cwd": d["cwd"], "session_id": d.get("sessionId"), "agent": "claude"})
        else:
            cwd = cwd_from_url(p.get("cwd"))
            if cwd:
                t["panes"].append({"cwd": cwd, "session_id": None, "agent": ""})
    out = []
    for t in tabs.values():
        if not t["panes"]:
            continue
        if not t["title"]:
            t["title"] = os.path.basename(t["panes"][0]["cwd"].rstrip("\\/")) or "~"
        t["title"] = t["title"][:60]
        out.append(t)
    return out
