from __future__ import annotations

import csv
import json
import os
import re
import subprocess
import time
from collections import deque
from datetime import datetime
from pathlib import Path
from typing import Any

CAPTURE_INTERFACE = os.environ.get("CAPTURE_INTERFACE", "mon1")
AUTHORIZED_BSSID = os.environ.get("AUTHORIZED_BSSID", "").lower()

DATA_DIR = Path.home() / "pineapplexpress" / "data"
OUTPUT_FILE = DATA_DIR / "live_packets.json"
TEMP_FILE = DATA_DIR / "live_packets.json.tmp"

MAX_PACKETS = 250
WRITE_INTERVAL_SECONDS = 0.75

BSSID_PATTERN = re.compile(
    r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$",
    re.IGNORECASE,
)

packets: deque[dict[str, Any]] = deque(maxlen=MAX_PACKETS)
total_seen = 0


def classify_protocol(protocol: str, has_ip: bool) -> str:
    upper = protocol.upper()

    if "DNS" in upper:
        return "dns"
    if upper == "TCP":
        return "tcp"
    if upper == "UDP":
        return "udp"
    if "ICMP" in upper:
        return "icmp"
    if "ARP" in upper:
        return "arp"
    if not has_ip:
        return "wlan"

    return "other"


def format_timestamp(epoch: str) -> str:
    try:
        return datetime.fromtimestamp(float(epoch)).astimezone().strftime(
            "%H:%M:%S.%f"
        )[:-3]
    except ValueError:
        return datetime.now().astimezone().strftime("%H:%M:%S.%f")[:-3]


def write_feed(status: str, error: str = "") -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    payload = {
        "status": status,
        "authorized_bssid": AUTHORIZED_BSSID,
        "capture_interface": CAPTURE_INTERFACE,
        "updated_at": datetime.now().astimezone().isoformat(
            timespec="seconds"
        ),
        "total_seen": total_seen,
        "error": error,
        "packets": list(packets),
    }

    TEMP_FILE.write_text(json.dumps(payload))
    TEMP_FILE.replace(OUTPUT_FILE)


def parse_line(line: str) -> dict[str, Any] | None:
    fields = next(
        csv.reader(
            [line],
            delimiter="|",
            quotechar='"',
        ),
        [],
    )

    while len(fields) < 15:
        fields.append("")

    (
        epoch,
        frame_length,
        protocol,
        ipv4_src,
        ipv4_dst,
        ipv6_src,
        ipv6_dst,
        tcp_srcport,
        tcp_dstport,
        udp_srcport,
        udp_dstport,
        wlan_src,
        wlan_dst,
        bssid,
        signal_dbm,
    ) = fields[:15]

    source_ip = ipv4_src or ipv6_src
    destination_ip = ipv4_dst or ipv6_dst

    source_endpoint = source_ip or wlan_src or "-"
    destination_endpoint = destination_ip or wlan_dst or "-"

    source_port = tcp_srcport or udp_srcport or "-"
    destination_port = tcp_dstport or udp_dstport or "-"

    has_ip = bool(source_ip or destination_ip)

    return {
        "timestamp": format_timestamp(epoch),
        "protocol": protocol or ("802.11" if not has_ip else "Unknown"),
        "category": classify_protocol(protocol, has_ip),
        "source": source_endpoint,
        "destination": destination_endpoint,
        "source_port": source_port,
        "destination_port": destination_port,
        "length": frame_length or "-",
        "signal_dbm": signal_dbm or "-",
        "bssid": bssid or AUTHORIZED_BSSID,
        "layer": "IP" if has_ip else "WLAN",
    }


def run_capture() -> None:
    global total_seen

    if not BSSID_PATTERN.fullmatch(AUTHORIZED_BSSID):
        write_feed(
            "configuration_required",
            "Set AUTHORIZED_BSSID in /etc/default/pineapplexpress-packets",
        )
        time.sleep(10)
        return

    if not Path(f"/sys/class/net/{CAPTURE_INTERFACE}").exists():
        write_feed(
            "waiting_for_monitor_interface",
            f"{CAPTURE_INTERFACE} is not active",
        )
        time.sleep(3)
        return

    command = [
        "tshark",
        "-i",
        CAPTURE_INTERFACE,
        "-n",
        "-l",
        "-o",
        "wlan.enable_decryption:TRUE",
        "-Y",
        (
            f"(wlan.bssid == {AUTHORIZED_BSSID}) || "
            f"(wlan.addr == {AUTHORIZED_BSSID})"
        ),
        "-T",
        "fields",
        "-E",
        "separator=|",
        "-E",
        "quote=d",
        "-E",
        "occurrence=f",
        "-e",
        "frame.time_epoch",
        "-e",
        "frame.len",
        "-e",
        "_ws.col.Protocol",
        "-e",
        "ip.src",
        "-e",
        "ip.dst",
        "-e",
        "ipv6.src",
        "-e",
        "ipv6.dst",
        "-e",
        "tcp.srcport",
        "-e",
        "tcp.dstport",
        "-e",
        "udp.srcport",
        "-e",
        "udp.dstport",
        "-e",
        "wlan.sa",
        "-e",
        "wlan.da",
        "-e",
        "wlan.bssid",
        "-e",
        "radiotap.dbm_antsignal",
    ]

    write_feed("capturing")

    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=None,
        text=True,
        bufsize=1,
    )

    last_write = 0.0

    assert process.stdout is not None

    for line in process.stdout:
        packet = parse_line(line.strip())

        if packet is None:
            continue

        packets.append(packet)
        total_seen += 1

        now = time.monotonic()

        if now - last_write >= WRITE_INTERVAL_SECONDS:
            write_feed("capturing")
            last_write = now

    write_feed("capture_process_stopped")


def main() -> None:
    while True:
        try:
            run_capture()
        except Exception as exc:
            write_feed("error", str(exc))
            time.sleep(3)


if __name__ == "__main__":
    main()
