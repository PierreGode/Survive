#!/usr/bin/env python3
"""
Survive web dashboard — a tiny, dependency-free status page for the Survive
self-healing watchdog.

Serves:
  GET /              the dashboard (web/index.html)
  GET /api/status    everything the dashboard shows, as JSON

Pure Python standard library (http.server). Reads Survive's own state files
and cheap system metrics; it never changes anything (read-only).

Config via environment:
  SURVIVE_WEB_HOST   bind address (default 0.0.0.0)
  SURVIVE_WEB_PORT   bind port    (default 8099)
  SURVIVE_CONFIG     survive.conf (default /etc/survive/survive.conf)
"""

import json
import os
import re
import shutil
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("SURVIVE_WEB_HOST", "0.0.0.0")
PORT = int(os.environ.get("SURVIVE_WEB_PORT", "8099"))
CONFIG = os.environ.get("SURVIVE_CONFIG", "/etc/survive/survive.conf")
STATE_DIR = "/var/lib/survive"
RUN_DIR = "/run/survive"
WEB_DIR = os.environ.get("SURVIVE_WEB_DIR", os.path.dirname(os.path.abspath(__file__)))

START_TIME = time.time()


def sh(cmd, timeout=5):
    """Run a command, return stdout (str) or '' on any failure."""
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        ).stdout
    except Exception:
        return ""


def read_file(path):
    try:
        with open(path) as fh:
            return fh.read()
    except Exception:
        return ""


def uptime_seconds():
    try:
        return float(read_file("/proc/uptime").split()[0])
    except Exception:
        return 0.0


def load_config():
    cfg = {}
    for line in read_file(CONFIG).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        cfg[key.strip()] = val.strip().strip('"').strip("'")
    return cfg


def read_state():
    state = {}
    for line in read_file(os.path.join(RUN_DIR, "state")).splitlines():
        key, _, val = line.partition("=")
        state[key.strip()] = val.strip()
    return state


def read_events(limit=40):
    lines = [l for l in read_file(os.path.join(STATE_DIR, "events.log")).splitlines() if l.strip()]
    out = []
    pat = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \[(\w+)\] (.*)$")
    for line in lines[-limit:]:
        m = pat.match(line)
        if m:
            out.append({"time": m.group(1), "level": m.group(2), "msg": m.group(3)})
        else:
            out.append({"time": "", "level": "info", "msg": line})
    out.reverse()
    return out


def mem_info():
    info = {}
    for line in read_file("/proc/meminfo").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].rstrip(":") in ("MemTotal", "MemAvailable"):
            info[parts[0].rstrip(":")] = int(parts[1])  # kB
    total = info.get("MemTotal", 0)
    avail = info.get("MemAvailable", 0)
    used = total - avail
    return {
        "total_mb": round(total / 1024),
        "used_mb": round(used / 1024),
        "avail_mb": round(avail / 1024),
        "used_pct": round(used * 100 / total, 1) if total else 0,
    }


_prev_cpu = {"t": None, "idle": 0, "total": 0}


def cpu_percent():
    try:
        parts = read_file("/proc/stat").splitlines()[0].split()[1:]
        nums = list(map(int, parts))
        idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
        total = sum(nums)
        prev = _prev_cpu
        pct = 0.0
        if prev["t"] is not None:
            dt = total - prev["total"]
            di = idle - prev["idle"]
            if dt > 0:
                pct = round((1 - di / dt) * 100, 1)
        _prev_cpu["idle"], _prev_cpu["total"], _prev_cpu["t"] = idle, total, time.time()
        return pct
    except Exception:
        return 0.0


def cpu_temp():
    raw = read_file("/sys/class/thermal/thermal_zone0/temp").strip()
    try:
        return round(int(raw) / 1000.0, 1)
    except Exception:
        return None


def throttle_info():
    out = sh(["vcgencmd", "get_throttled"]).strip()
    m = re.search(r"throttled=(0x[0-9a-fA-F]+)", out)
    if not m:
        return {"raw": None, "flags": []}
    val = int(m.group(1), 16)
    bits = [
        (0x1, "Under-voltage NOW", True),
        (0x2, "ARM freq capped NOW", True),
        (0x4, "Throttled NOW", True),
        (0x8, "Soft temp limit NOW", True),
        (0x10000, "Under-voltage occurred", False),
        (0x20000, "ARM freq capped occurred", False),
        (0x40000, "Throttled occurred", False),
        (0x80000, "Soft temp limit occurred", False),
    ]
    flags = [{"label": lbl, "now": now} for mask, lbl, now in bits if val & mask]
    return {"raw": m.group(1), "flags": flags}


def disk_info():
    try:
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        used = total - free
        return {
            "total_gb": round(total / 1e9, 1),
            "used_gb": round(used / 1e9, 1),
            "used_pct": round(used * 100 / total, 1) if total else 0,
        }
    except Exception:
        return {"total_gb": 0, "used_gb": 0, "used_pct": 0}


def service_active(unit):
    return sh(["systemctl", "is-active", unit]).strip() or "unknown"


def crashloops(cfg):
    threshold = int(cfg.get("CRASHLOOP_THRESHOLD", "15") or "15")
    units = []
    for line in read_file(os.path.join(RUN_DIR, "restarts")).splitlines():
        parts = line.split()
        if len(parts) >= 2:
            try:
                n = int(parts[1])
            except ValueError:
                continue
            if n > 0:
                units.append({"unit": parts[0], "restarts": n, "looping": n >= threshold})
    units.sort(key=lambda u: u["restarts"], reverse=True)
    return {"threshold": threshold, "units": units[:12], "count": len(units)}


_cache = {"ports": (0, None)}


def listening_ports():
    now = time.time()
    ts, data = _cache["ports"]
    if data is not None and now - ts < 8:
        return data
    rows = {}
    for line in sh(["ss", "-tlnpH"]).splitlines():
        cols = line.split()
        if len(cols) < 4:
            continue
        local = cols[3]
        m = re.search(r":(\d+)$", local)
        if not m:
            continue
        port = int(m.group(1))
        proc = ""
        pm = re.search(r'\("([^"]+)"', line)
        if pm:
            proc = pm.group(1)
        # prefer a 0.0.0.0/:: binding label; dedupe by port
        if port not in rows or local.startswith("0.0.0.0") or local.startswith("*"):
            rows[port] = {"port": port, "proc": proc}
    ports = sorted(rows.values(), key=lambda r: r["port"])

    docker = []
    if shutil.which("docker"):
        out = sh(["docker", "ps", "--format", "{{.Names}}|{{.Ports}}|{{.Status}}"], timeout=6)
        for line in out.splitlines():
            parts = line.split("|")
            if len(parts) >= 2:
                published = re.findall(r":(\d+)->", parts[1])
                docker.append({
                    "name": parts[0],
                    "ports": sorted(set(int(p) for p in published)),
                    "status": parts[2] if len(parts) > 2 else "",
                })
    data = {"ports": ports, "docker": docker}
    _cache["ports"] = (now, data)
    return data


def build_status():
    cfg = load_config()
    state = read_state()
    up = uptime_seconds()

    def dur(key):
        try:
            v = int(state.get(key, "0") or "0")
            return (int(up) - v) if v > 0 else 0
        except ValueError:
            return 0

    fail_since = int(state.get("FAIL_SINCE", "0") or "0")
    faults = state.get("LAST_FAULTS", "").strip()
    if fail_since > 0:
        overall = "failing"
    elif service_active("survive.service") == "active":
        overall = "healthy"
    else:
        overall = "unknown"

    reboot_count = read_file(os.path.join(STATE_DIR, "reboot_count")).strip()
    watched = [u for u in (cfg.get("WATCH_SERVICES", "").split()) if u]

    version = sh(["survive", "version"]).strip() or "?"

    return {
        "ts": int(time.time()),
        "hostname": socket.gethostname(),
        "survive": {
            "service": service_active("survive.service"),
            "version": version,
            "overall": overall,
            "faults": faults.split() if faults else [],
            "failing_for": dur("FAIL_SINCE"),
            "healthy_for": dur("HEALTHY_SINCE"),
            "action_step": int(state.get("ACTION_STEP", "0") or "0"),
            "reboot_count": int(reboot_count) if reboot_count.isdigit() else 0,
            "reboot_enabled": cfg.get("ENABLE_REBOOT", "true").lower() == "true",
            "grace_period": int(cfg.get("GRACE_PERIOD", "300") or "300"),
            "reboot_after": int(cfg.get("REBOOT_AFTER", "600") or "600"),
        },
        "system": {
            "uptime": int(up),
            "loadavg": read_file("/proc/loadavg").split()[:3],
            "cpu_pct": cpu_percent(),
            "cpu_temp": cpu_temp(),
            "mem": mem_info(),
            "disk": disk_info(),
            "throttle": throttle_info(),
            "ncpu": os.cpu_count(),
        },
        "crashloop": crashloops(cfg),
        "services": [
            {"unit": u, "state": service_active(u)}
            for u in (["survive.service"] + watched)
        ],
        "network": listening_ports(),
        "events": read_events(),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # keep the journal quiet

    def _send(self, code, body, ctype):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/api/status"):
            try:
                body = json.dumps(build_status())
            except Exception as e:
                self._send(500, json.dumps({"error": str(e)}), "application/json")
                return
            self._send(200, body, "application/json")
        elif self.path in ("/", "/index.html"):
            html = read_file(os.path.join(WEB_DIR, "index.html"))
            if html:
                self._send(200, html, "text/html; charset=utf-8")
            else:
                self._send(404, "index.html not found", "text/plain")
        elif self.path == "/healthz":
            self._send(200, "ok", "text/plain")
        else:
            self._send(404, "not found", "text/plain")

    do_HEAD = do_GET


def main():
    cpu_percent()  # prime the CPU sampler
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Survive web dashboard on http://{HOST}:{PORT}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
