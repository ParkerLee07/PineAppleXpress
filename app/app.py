from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
from datetime import datetime
from functools import wraps
from pathlib import Path
from typing import Any, Callable

from flask import (
    Flask,
    abort,
    send_file,
    flash,
    jsonify,
    redirect,
    render_template_string,
    request,
    session,
    url_for,
)
from werkzeug.security import check_password_hash
from flask_wtf.csrf import CSRFProtect

app = Flask(__name__)

CONFIG_DIR = Path.home() / "pineapplexpress" / "config"
SECRET_FILE = CONFIG_DIR / "dashboard-secret.txt"
PASSWORD_HASH_FILE = CONFIG_DIR / "dashboard-password.hash"

if not SECRET_FILE.exists() or not PASSWORD_HASH_FILE.exists():
    raise RuntimeError(
        "Dashboard authentication files are missing. "
        "Create them before starting the service."
    )

app.secret_key = SECRET_FILE.read_text().strip()

app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
)

csrf = CSRFProtect(app)


def run_command(command: list[str]) -> str:
    """Run a fixed read-only command and safely return its output."""
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=4,
            check=False,
        )

        output = result.stdout.strip()
        if output:
            return output

        error = result.stderr.strip()
        return error if error else "No output"

    except FileNotFoundError:
        return f"Command not installed: {command[0]}"

    except subprocess.TimeoutExpired:
        return f"Command timed out: {command[0]}"

    except Exception as exc:
        return f"Unable to run command: {exc}"


def login_required(route: Callable):
    @wraps(route)
    def wrapped(*args, **kwargs):
        if not session.get("authenticated"):
            return redirect(url_for("login"))
        return route(*args, **kwargs)

    return wrapped


def bytes_to_gib(value: int) -> float:
    return round(value / (1024 ** 3), 2)


def get_memory() -> dict[str, Any]:
    values: dict[str, int] = {}

    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, raw_value = line.split(":", 1)
            values[key] = int(raw_value.strip().split()[0]) * 1024
    except Exception:
        return {
            "total_gib": 0,
            "used_gib": 0,
            "available_gib": 0,
            "percent": 0,
        }

    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", 0)
    used = max(total - available, 0)

    return {
        "total_gib": bytes_to_gib(total),
        "used_gib": bytes_to_gib(used),
        "available_gib": bytes_to_gib(available),
        "percent": round((used / total) * 100, 1) if total else 0,
    }


def get_disk() -> dict[str, Any]:
    usage = shutil.disk_usage("/")
    used = usage.total - usage.free

    return {
        "total_gib": bytes_to_gib(usage.total),
        "used_gib": bytes_to_gib(used),
        "free_gib": bytes_to_gib(usage.free),
        "percent": round((used / usage.total) * 100, 1),
    }


def get_interfaces() -> list[dict[str, Any]]:
    raw = run_command(["ip", "-j", "addr"])

    try:
        interfaces = json.loads(raw)
    except json.JSONDecodeError:
        return [
            {
                "name": "Unavailable",
                "state": "unknown",
                "addresses": [raw],
            }
        ]

    results = []

    for interface in interfaces:
        addresses = []

        for address in interface.get("addr_info", []):
            local = address.get("local")
            prefix = address.get("prefixlen")
            family = address.get("family")

            if local is not None:
                addresses.append(f"{family}: {local}/{prefix}")

        results.append(
            {
                "name": interface.get("ifname", "unknown"),
                "state": interface.get("operstate", "unknown"),
                "addresses": addresses or ["No assigned address"],
            }
        )

    return results


def get_load_average() -> dict[str, float]:
    one, five, fifteen = os.getloadavg()

    return {
        "one_minute": round(one, 2),
        "five_minutes": round(five, 2),
        "fifteen_minutes": round(fifteen, 2),
    }


def read_counter(path: Path) -> int:
    try:
        return int(path.read_text().strip())
    except (FileNotFoundError, PermissionError, ValueError):
        return 0


def get_monitor_status() -> dict[str, Any]:
    interface = "wlan1"
    interface_path = Path("/sys/class/net") / interface
    active = (
        interface_path.exists()
        and "type monitor" in run_command(["iw", "dev", interface, "info"])
    )

    return {
        "interface": interface,
        "active": active,
        "rx_packets": read_counter(
            interface_path / "statistics" / "rx_packets"
        ),
        "rx_bytes": read_counter(
            interface_path / "statistics" / "rx_bytes"
        ),
        "message": (
            "Passive monitoring active on wlan1"
            if active
            else "wlan1 is not currently in passive monitor mode"
        ),
    }


def run_control_script(script_path: str) -> tuple[bool, str]:
    allowed_scripts = {
        "/usr/local/sbin/pineapplexpress-mode-monitor",
        "/usr/local/sbin/pineapplexpress-mode-hotspot",
        "/usr/local/sbin/pineapplexpress-mode-off",
    }

    if script_path not in allowed_scripts:
        return False, "Requested control command is not allowed."

    try:
        result = subprocess.run(
            ["sudo", "-n", script_path],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

        message = (
            result.stdout.strip()
            or result.stderr.strip()
            or "Command completed."
        )

        return result.returncode == 0, message

    except subprocess.TimeoutExpired:
        return False, "Control command timed out."

    except Exception as exc:
        return False, f"Unable to run control command: {exc}"


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None

    if request.method == "POST":
        password = request.form.get("password", "")
        stored_hash = PASSWORD_HASH_FILE.read_text().strip()

        if check_password_hash(stored_hash, password):
            session.clear()
            session["authenticated"] = True
            return redirect(url_for("dashboard"))

        error = "Invalid password."

    return render_template_string(LOGIN_HTML, error=error)


@app.get("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.post("/monitor/start")
@login_required
def monitor_start():
    ok, message = run_control_script(
        "/usr/local/sbin/pineapplexpress-monitor-start"
    )

    flash(message, "success" if ok else "error")
    return redirect(url_for("dashboard"))


@app.post("/monitor/stop")
@login_required
def monitor_stop():
    ok, message = run_control_script(
        "/usr/local/sbin/pineapplexpress-monitor-stop"
    )

    flash(message, "success" if ok else "error")
    return redirect(url_for("dashboard"))


def get_radio_mode() -> dict[str, str]:
    interface = "wlan1"

    iw_info = run_command(
        ["iw", "dev", interface, "info"]
    )

    connection = run_command(
        [
            "nmcli",
            "-g",
            "GENERAL.CONNECTION",
            "device",
            "show",
            interface,
        ]
    ).strip()

    if connection == "PineAppleXpress-Lab":
        mode = "hotspot"
        detail = "Serving PineAppleXpress-Lab on wlan1"

    elif "type monitor" in iw_info:
        mode = "monitor"
        detail = "Passive wireless recon is active on wlan1"

    else:
        mode = "off"
        detail = "wlan1 is idle"

    return {
        "mode": mode,
        "interface": interface,
        "connection": connection,
        "detail": detail,
    }


@app.get("/api/radio-mode")
@login_required
def api_radio_mode():
    return jsonify(get_radio_mode())


@app.post("/mode/monitor")
@login_required
def mode_monitor():
    ok, message = run_control_script(
        "/usr/local/sbin/pineapplexpress-mode-monitor"
    )

    flash(message, "success" if ok else "error")
    return redirect(url_for("dashboard"))


@app.post("/mode/hotspot")
@login_required
def mode_hotspot():
    ok, message = run_control_script(
        "/usr/local/sbin/pineapplexpress-mode-hotspot"
    )

    flash(message, "success" if ok else "error")
    return redirect(url_for("dashboard"))


@app.post("/mode/off")
@login_required
def mode_off():
    ok, message = run_control_script(
        "/usr/local/sbin/pineapplexpress-mode-off"
    )

    flash(message, "success" if ok else "error")
    return redirect(url_for("dashboard"))


@app.get("/")
@login_required
def dashboard() -> str:
    return render_template_string(DASHBOARD_HTML)


@app.get("/api/status")
@login_required
def api_status():
    return jsonify(
        {
            "hostname": socket.gethostname(),
            "timestamp": datetime.now().astimezone().isoformat(
                timespec="seconds"
            ),
            "uptime": run_command(["uptime", "-p"]),
            "kernel": run_command(["uname", "-r"]),
            "load_average": get_load_average(),
            "memory": get_memory(),
            "disk": get_disk(),
            "interfaces": get_interfaces(),
            "wireless_radios": run_command(["iw", "dev"]),
            "rfkill": run_command(["rfkill", "list"]),
            "usb_devices": run_command(["lsusb"]),
            "monitor": get_monitor_status(),
        }
    )


PACKET_FEED_FILE = (
    Path.home()
    / "pineapplexpress"
    / "data"
    / "live_packets.json"
)


def get_packet_feed() -> dict[str, Any]:
    default = {
        "status": "collector_not_ready",
        "authorized_bssid": "",
        "capture_interface": "mon1",
        "updated_at": "",
        "total_seen": 0,
        "error": "",
        "packets": [],
    }

    try:
        data = json.loads(PACKET_FEED_FILE.read_text())

        if not isinstance(data, dict):
            return default

        return {**default, **data}

    except (FileNotFoundError, json.JSONDecodeError, PermissionError):
        return default


@app.get("/api/packets")
@login_required
def api_packets():
    return jsonify(get_packet_feed())


CAPTURE_DIR = (
    Path.home()
    / "pineapplexpress"
    / "data"
    / "captures"
)

LATEST_CAPTURE_POINTER = CAPTURE_DIR / "latest-closed.txt"


def get_latest_completed_capture() -> Path | None:
    try:
        candidate = Path(
            LATEST_CAPTURE_POINTER.read_text().strip()
        ).resolve()

        capture_dir = CAPTURE_DIR.resolve()

        if candidate.parent != capture_dir:
            return None

        if candidate.suffix.lower() != ".pcapng":
            return None

        if not candidate.is_file():
            return None

        return candidate

    except (FileNotFoundError, PermissionError, OSError):
        return None


@app.get("/captures/latest")
@login_required
def download_latest_capture():
    capture = get_latest_completed_capture()

    if capture is None:
        abort(
            404,
            description=(
                "No completed capture is available yet. "
                "Start monitoring and allow the first segment to close."
            ),
        )

    timestamp = datetime.now().astimezone().strftime(
        "%Y%m%d-%H%M%S"
    )

    return send_file(
        capture,
        as_attachment=True,
        download_name=f"pineapplexpress-{timestamp}.pcapng",
        mimetype="application/octet-stream",
        max_age=0,
    )


HOTSPOT_FEED_FILE = (
    Path.home()
    / "pineapplexpress"
    / "data"
    / "hotspot_packets.json"
)


def get_hotspot_feed() -> dict[str, Any]:
    default = {
        "status": "collector_not_ready",
        "capture_interface": "any",
        "subnet": "10.42.50.0/24",
        "updated_at": "",
        "total_seen": 0,
        "error": "",
        "packets": [],
    }

    try:
        data = json.loads(HOTSPOT_FEED_FILE.read_text())

        if not isinstance(data, dict):
            return default

        return {**default, **data}

    except (FileNotFoundError, json.JSONDecodeError, PermissionError):
        return default


@app.get("/api/hotspot-packets")
@login_required
def api_hotspot_packets():
    return jsonify(get_hotspot_feed())


@app.get("/api/health")
def api_health():
    return jsonify(
        {
            "status": "ok",
            "hostname": socket.gethostname(),
        }
    )


LOGIN_HTML = r"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport"
        content="width=device-width, initial-scale=1">
  <title>PineAppleXpress Login</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #080b0d;
      --panel: #11171b;
      --border: #26333a;
      --text: #e9f2f5;
      --muted: #9aabb2;
      --accent: #7ee787;
      --error: #ff7b72;
    }

    * {
      box-sizing: border-box;
    }

    body {
      display: grid;
      min-height: 100vh;
      margin: 0;
      place-items: center;
      background: var(--bg);
      color: var(--text);
      font-family: system-ui, sans-serif;
    }

    .card {
      width: min(92vw, 390px);
      padding: 24px;
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 12px;
    }

    h1 {
      margin-top: 0;
      letter-spacing: 0.07em;
    }

    p {
      color: var(--muted);
    }

    input, button {
      width: 100%;
      padding: 12px;
      border-radius: 7px;
      font: inherit;
    }

    input {
      margin: 12px 0;
      border: 1px solid var(--border);
      background: #0c1114;
      color: var(--text);
    }

    button {
      border: 0;
      background: var(--accent);
      color: #071008;
      cursor: pointer;
      font-weight: 700;
    }

    .error {
      color: var(--error);
    }
  </style>
</head>
<body>
  <form class="card" method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    <h1>PINEAPPLEXPRESS</h1>
    <p>Local dashboard login</p>

    {% if error %}
      <p class="error">{{ error }}</p>
    {% endif %}

    <input
      type="password"
      name="password"
      placeholder="Dashboard password"
      autocomplete="current-password"
      required
      autofocus
    >

    <button type="submit">Log in</button>
  </form>
</body>
</html>
"""


DASHBOARD_HTML = r"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport"
        content="width=device-width, initial-scale=1">
  <title>PineAppleXpress</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #080b0d;
      --panel: #11171b;
      --border: #26333a;
      --text: #e9f2f5;
      --muted: #9aabb2;
      --accent: #7ee787;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: system-ui, sans-serif;
    }

    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      padding: 22px;
      border-bottom: 1px solid var(--border);
      background: #0c1114;
    }

    h1 {
      margin: 0;
      letter-spacing: 0.08em;
    }

    a {
      color: var(--accent);
    }

    main {
      max-width: 1200px;
      margin: auto;
      padding: 20px;
    }

    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 14px;
      margin-bottom: 16px;
    }

    .card {
      padding: 16px;
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 10px;
    }

    .label {
      color: var(--muted);
      font-size: 0.82rem;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }

    .value {
      margin-top: 8px;
      color: var(--accent);
      font-size: 1.2rem;
    }

    h2 {
      margin-top: 0;
      font-size: 1.05rem;
    }

    table {
      width: 100%;
      border-collapse: collapse;
    }

    th, td {
      padding: 9px;
      border-bottom: 1px solid var(--border);
      text-align: left;
      vertical-align: top;
    }

    th {
      color: var(--muted);
    }

    pre {
      overflow-x: auto;
      white-space: pre-wrap;
      color: #c8d5da;
    }

    .status {
      margin-left: 8px;
      color: var(--accent);
      font-size: 0.9rem;
    }

    .detail {
      margin-top: 8px;
      color: var(--muted);
      font-size: 0.85rem;
    }


    .controls {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 10px;
      margin-bottom: 16px;
    }

    .controls form {
      margin: 0;
    }

    button {
      padding: 10px 14px;
      border: 0;
      border-radius: 7px;
      cursor: pointer;
      font: inherit;
      font-weight: 700;
    }

    .start {
      background: var(--accent);
      color: #071008;
    }

    .stop {
      background: #ff7b72;
      color: #170404;
    }


    .hotspot {
      background: #d29922;
      color: #160d00;
    }

    .notice {
      margin-bottom: 16px;
      padding: 12px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--panel);
    }

    .notice.success {
      color: var(--accent);
    }

    .notice.error {
      color: #ff7b72;
    }


    .packet-table-wrap {
      max-height: 470px;
      overflow: auto;
      border: 1px solid var(--border);
      border-radius: 8px;
    }

    .packet-table {
      min-width: 960px;
      font-family: ui-monospace, SFMono-Regular, monospace;
      font-size: 0.82rem;
    }

    .packet-table thead {
      position: sticky;
      top: 0;
      background: #0c1114;
    }

    .badge {
      display: inline-block;
      min-width: 62px;
      padding: 3px 7px;
      border-radius: 999px;
      text-align: center;
      font-weight: 700;
    }

    .badge.tcp {
      background: #1f6feb;
      color: white;
    }

    .badge.udp {
      background: #8957e5;
      color: white;
    }

    .badge.dns {
      background: #d29922;
      color: #080b0d;
    }

    .badge.icmp {
      background: #f85149;
      color: white;
    }

    .badge.arp {
      background: #db6d28;
      color: white;
    }

    .badge.wlan {
      background: #238636;
      color: white;
    }

    .badge.other {
      background: #57606a;
      color: white;
    }


    .badge.dhcp {
      background: #0ea5e9;
      color: white;
    }

    .hotspot-table-wrap {
      max-height: 520px;
      overflow: auto;
      border: 1px solid var(--border);
      border-radius: 8px;
    }

    .hotspot-table {
      min-width: 1180px;
      font-family: ui-monospace, SFMono-Regular, monospace;
      font-size: 0.82rem;
    }

    .hotspot-table thead {
      position: sticky;
      top: 0;
      background: #0c1114;
    }


    .download-button {
      display: inline-block;
      margin-top: 10px;
      padding: 10px 14px;
      border-radius: 7px;
      background: var(--accent);
      color: #071008;
      font-weight: 700;
      text-decoration: none;
    }
  </style>
</head>
<body>
  <header>
    <h1>
      PINEAPPLEXPRESS
      <span class="status">● ONLINE</span>
    </h1>
    <a href="/logout">Log out</a>
  </header>

  <main>
    {% with messages = get_flashed_messages(with_categories=true) %}
      {% for category, message in messages %}
        <div class="notice {{ category }}">{{ message }}</div>
      {% endfor %}
    {% endwith %}

    <div class="card controls">
      <strong>Radio Mode Controls</strong>

      <form method="post" action="/mode/monitor">
        <input
          type="hidden"
          name="csrf_token"
          value="{{ csrf_token() }}"
        >
        <button class="start" type="submit">
          Monitor Mode
        </button>
      </form>

      <form method="post" action="/mode/hotspot">
        <input
          type="hidden"
          name="csrf_token"
          value="{{ csrf_token() }}"
        >
        <button class="hotspot" type="submit">
          Hotspot Mode
        </button>
      </form>

      <form method="post" action="/mode/off">
        <input
          type="hidden"
          name="csrf_token"
          value="{{ csrf_token() }}"
        >
        <button class="stop" type="submit">
          Turn Radio Off
        </button>
      </form>
    </div>

    <div class="grid">
      <div class="card">
        <div class="label">Hostname</div>
        <div class="value" id="hostname">Loading...</div>
      </div>

      <div class="card">
        <div class="label">Uptime</div>
        <div class="value" id="uptime">Loading...</div>
      </div>

      <div class="card">
        <div class="label">Memory</div>
        <div class="value" id="memory">Loading...</div>
      </div>

      <div class="card">
        <div class="label">Disk</div>
        <div class="value" id="disk">Loading...</div>
      </div>

      <div class="card">
        <div class="label">Load Average</div>
        <div class="value" id="load">Loading...</div>
      </div>

      <div class="card">
        <div class="label">Radio Mode</div>
        <div class="value" id="radio-mode">Loading...</div>
        <div class="detail" id="radio-mode-detail">Loading...</div>
      </div>

      <div class="card">
        <div class="label">Passive Monitor</div>
        <div class="value" id="monitor">Loading...</div>
        <div class="detail" id="monitor-detail">Loading...</div>
      </div>
    </div>

    <div class="card">
      <h2>Network Interfaces</h2>
      <table>
        <thead>
          <tr>
            <th>Interface</th>
            <th>State</th>
            <th>Addresses</th>
          </tr>
        </thead>
        <tbody id="interfaces"></tbody>
      </table>
    </div>

    <div class="grid" style="margin-top: 16px;">
      <div class="card">
        <h2>Wireless Radios</h2>
        <pre id="wireless">Loading...</pre>
      </div>

      <div class="card">
        <h2>RFKill Status</h2>
        <pre id="rfkill">Loading...</pre>
      </div>
    </div>

    <div class="card" style="margin-bottom: 16px;">
      <h2>Hotspot Traffic</h2>

      <div class="detail" id="hotspot-feed-status">
        Loading decoded hotspot traffic...
      </div>

      <div class="hotspot-table-wrap" style="margin-top: 12px;">
        <table class="hotspot-table">
          <thead>
            <tr>
              <th>Time</th>
              <th>Protocol</th>
              <th>Source</th>
              <th>Src Port</th>
              <th>Destination</th>
              <th>Dst Port</th>
              <th>Bytes</th>
              <th>DNS Query</th>
              <th>Interface</th>
              <th>Summary</th>
            </tr>
          </thead>
          <tbody id="hotspot-packet-table-body"></tbody>
        </table>
      </div>
    </div>

    <div class="card" style="margin-bottom: 16px;">
      <h2>Capture Export</h2>

      <div class="detail">
        Download the latest completed PCAPNG segment for analysis
        in Wireshark on another system.
      </div>

      <a
        class="download-button"
        href="/captures/latest"
      >
        Download Latest PCAPNG
      </a>
    </div>

    <div class="card" style="margin-bottom: 16px;">
      <h2>Live Authorized Packet Metadata</h2>

      <div class="detail" id="packet-feed-status">
        Loading packet collector status...
      </div>

      <div class="packet-table-wrap" style="margin-top: 12px;">
        <table class="packet-table">
          <thead>
            <tr>
              <th>Time</th>
              <th>Layer</th>
              <th>Protocol</th>
              <th>Source Endpoint</th>
              <th>Src Port</th>
              <th>Destination Endpoint</th>
              <th>Dst Port</th>
              <th>Bytes</th>
              <th>RSSI</th>
            </tr>
          </thead>
          <tbody id="packet-table-body"></tbody>
        </table>
      </div>
    </div>

    <div class="card">
      <h2>USB Devices</h2>
      <pre id="usb">Loading...</pre>
    </div>
  </main>

  <script>
    async function refreshDashboard() {
      const response = await fetch("/api/status");

      if (!response.ok) {
        window.location = "/login";
        return;
      }

      const data = await response.json();

      document.getElementById("hostname").textContent = data.hostname;
      document.getElementById("uptime").textContent = data.uptime;

      document.getElementById("memory").textContent =
        `${data.memory.used_gib} / ${data.memory.total_gib} GiB ` +
        `(${data.memory.percent}%)`;

      document.getElementById("disk").textContent =
        `${data.disk.used_gib} / ${data.disk.total_gib} GiB ` +
        `(${data.disk.percent}%)`;

      document.getElementById("load").textContent =
        `${data.load_average.one_minute}, ` +
        `${data.load_average.five_minutes}, ` +
        `${data.load_average.fifteen_minutes}`;

      document.getElementById("monitor").textContent =
        data.monitor.active
          ? `ACTIVE • ${data.monitor.rx_packets} packets`
          : "INACTIVE";

      document.getElementById("monitor-detail").textContent =
        data.monitor.active
          ? `${data.monitor.interface} • ${data.monitor.rx_bytes} bytes received`
          : "Press Start Monitor to enable passive capture";

      document.getElementById("wireless").textContent =
        data.wireless_radios;

      document.getElementById("rfkill").textContent =
        data.rfkill;

      document.getElementById("usb").textContent =
        data.usb_devices;

      const table = document.getElementById("interfaces");
      table.innerHTML = "";

      for (const iface of data.interfaces) {
        const row = document.createElement("tr");

        const name = document.createElement("td");
        name.textContent = iface.name;

        const state = document.createElement("td");
        state.textContent = iface.state;

        const addresses = document.createElement("td");
        addresses.textContent = iface.addresses.join(", ");

        row.append(name, state, addresses);
        table.appendChild(row);
      }
    }


    function makeCell(value) {
      const cell = document.createElement("td");
      cell.textContent = value ?? "-";
      return cell;
    }

    async function refreshPackets() {
      try {
        const response = await fetch("/api/packets");

        if (!response.ok) {
          window.location = "/login";
          return;
        }

        const data = await response.json();

        const status = document.getElementById("packet-feed-status");

        status.textContent =
          `${data.status} • ${data.total_seen} frames observed • ` +
          `BSSID ${data.authorized_bssid || "not configured"} • ` +
          `${data.capture_interface}`;

        if (data.error) {
          status.textContent += ` • ${data.error}`;
        }

        const body = document.getElementById("packet-table-body");
        body.innerHTML = "";

        const packets = [...data.packets].reverse();

        for (const packet of packets) {
          const row = document.createElement("tr");

          row.appendChild(makeCell(packet.timestamp));
          row.appendChild(makeCell(packet.layer));

          const protocolCell = document.createElement("td");
          const badge = document.createElement("span");

          badge.className = `badge ${packet.category || "other"}`;
          badge.textContent = packet.protocol || "Unknown";

          protocolCell.appendChild(badge);
          row.appendChild(protocolCell);

          row.appendChild(makeCell(packet.source));
          row.appendChild(makeCell(packet.source_port));
          row.appendChild(makeCell(packet.destination));
          row.appendChild(makeCell(packet.destination_port));
          row.appendChild(makeCell(packet.length));
          row.appendChild(makeCell(packet.signal_dbm));

          body.appendChild(row);
        }
      } catch (error) {
        console.error(error);
      }
    }


    function makeHotspotCell(value) {
      const cell = document.createElement("td");
      cell.textContent = value ?? "-";
      return cell;
    }

    async function refreshHotspotPackets() {
      try {
        const response = await fetch("/api/hotspot-packets");

        if (!response.ok) {
          window.location = "/login";
          return;
        }

        const data = await response.json();

        const status = document.getElementById("hotspot-feed-status");

        status.textContent =
          `${data.status} • ${data.total_seen} packets observed • ` +
          `${data.subnet} • ${data.capture_interface}`;

        if (data.error) {
          status.textContent += ` • ${data.error}`;
        }

        const body = document.getElementById(
          "hotspot-packet-table-body"
        );

        body.innerHTML = "";

        const packets = [...data.packets].reverse();

        for (const packet of packets) {
          const row = document.createElement("tr");

          row.appendChild(makeHotspotCell(packet.timestamp));

          const protocolCell = document.createElement("td");
          const badge = document.createElement("span");

          badge.className = `badge ${packet.category || "other"}`;
          badge.textContent = packet.protocol || "Unknown";

          protocolCell.appendChild(badge);
          row.appendChild(protocolCell);

          row.appendChild(makeHotspotCell(packet.source));
          row.appendChild(makeHotspotCell(packet.source_port));
          row.appendChild(makeHotspotCell(packet.destination));
          row.appendChild(makeHotspotCell(packet.destination_port));
          row.appendChild(makeHotspotCell(packet.length));
          row.appendChild(makeHotspotCell(packet.dns_query));
          row.appendChild(makeHotspotCell(packet.interface));
          row.appendChild(makeHotspotCell(packet.summary));

          body.appendChild(row);
        }
      } catch (error) {
        console.error(error);
      }
    }

    refreshHotspotPackets();
    setInterval(refreshHotspotPackets, 2000);


    async function refreshRadioMode() {
      try {
        const response = await fetch("/api/radio-mode");

        if (!response.ok) {
          window.location = "/login";
          return;
        }

        const data = await response.json();

        document.getElementById("radio-mode").textContent =
          data.mode.toUpperCase();

        document.getElementById("radio-mode-detail").textContent =
          data.detail;
      } catch (error) {
        console.error(error);
      }
    }

    refreshRadioMode();
    setInterval(refreshRadioMode, 2000);

    refreshDashboard();
    refreshPackets();

    setInterval(refreshDashboard, 5000);
    setInterval(refreshPackets, 2000);
  </script>
</body>
</html>
"""
