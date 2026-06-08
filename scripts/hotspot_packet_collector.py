from __future__ import annotations

import csv
import json
import subprocess
import time
from collections import deque
from datetime import datetime
from pathlib import Path
from typing import Any

DATA_DIR = Path.home() / "pineapplexpress" / "data"
OUTPUT_FILE = DATA_DIR / "hotspot_packets.json"
TEMP_FILE = DATA_DIR / "hotspot_packets.json.tmp"

CAPTURE_INTERFACE = "any"
HOTSPOT_SUBNET = "10.42.50.0/24"

MAX_PACKETS = 300
WRITE_INTERVAL_SECONDS = 0.75

packets: deque[dict[str, Any]] = deque(maxlen=MAX_PACKETS)
total_seen = 0


def classify_protocol(protocol: str) -> str:
    upper = protocol.upper()

    if "DNS" in upper or "MDNS" in upper:
        return "dns"

    if "DHCP" in upper or "BOOTP" in upper:
        return "dhcp"

    if "TCP" in upper:
        return "tcp"

    if "UDP" in upper:
        return "udp"

    if "ICMP" in upper:
        return "icmp"

    if "ARP" in upper:
        return "arp"

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
        "capture_interface": CAPTURE_INTERFACE,
        "subnet": HOTSPOT_SUBNET,
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

    while len(fields) < 16:
        fields.append("")

    (
        epoch,
        protocol,
        ipv4_src,
        ipv4_dst,
        ipv6_src,
        ipv6_dst,
        tcp_srcport,
        tcp_dstport,
        udp_srcport,
        udp_dstport,
        frame_length,
        eth_src,
        eth_dst,
        dns_query,
        interface_name,
        summary,
    ) = fields[:16]

    source = ipv4_src or ipv6_src or eth_src or "-"
    destination = ipv4_dst or ipv6_dst or eth_dst or "-"

    source_port = tcp_srcport or udp_srcport or "-"
    destination_port = tcp_dstport or udp_dstport or "-"

    return {
        "timestamp": format_timestamp(epoch),
        "protocol": protocol or "Unknown",
        "category": classify_protocol(protocol),
        "source": source,
        "destination": destination,
        "source_port": source_port,
        "destination_port": destination_port,
        "length": frame_length or "-",
        "eth_src": eth_src or "-",
        "eth_dst": eth_dst or "-",
        "dns_query": dns_query or "-",
        "interface": interface_name or CAPTURE_INTERFACE,
        "summary": summary or "-",
    }


def run_capture() -> None:
    global total_seen

    command = [
        "tshark",
        "-i",
        CAPTURE_INTERFACE,
        "-n",
        "-l",
        "-f",
        f"net {HOTSPOT_SUBNET}",
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
        "frame.len",
        "-e",
        "eth.src",
        "-e",
        "eth.dst",
        "-e",
        "dns.qry.name",
        "-e",
        "frame.interface_name",
        "-e",
        "_ws.col.Info",
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
