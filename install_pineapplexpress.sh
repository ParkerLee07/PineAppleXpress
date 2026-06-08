#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# PineAppleXpress Installer
# Raspberry Pi OS Lite / Debian-based systems
#
# Run from the root of the PineAppleXpress repository:
#   chmod +x install.sh
#   ./install.sh
#
# The repository must contain:
#   app/app.py
#   scripts/packet_collector.py
#   scripts/hotspot_packet_collector.py
#
# The installer:
#   - installs packages
#   - creates /home/<user>/pineapplexpress
#   - creates a Python virtual environment
#   - generates fresh dashboard credentials
#   - configures dumpcap capture permissions
#   - creates a saved PineAppleXpress-Lab hotspot profile
#   - installs root-owned radio mode scripts
#   - installs systemd services
#   - enables only the dashboard at boot
#
# It intentionally does NOT:
#   - modify wlan0
#   - activate hotspot mode during installation
#   - activate monitor mode during installation
#   - store PMKs or wireless decryption keys
# ============================================================

log() {
    printf '\n\033[1;32m[+] %s\033[0m\n' "$*"
}

warn() {
    printf '\n\033[1;33m[!] %s\033[0m\n' "$*" >&2
}

die() {
    printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
    exit 1
}

cleanup() {
    unset DASHBOARD_PASSWORD DASHBOARD_PASSWORD_CONFIRM HOTSPOT_PASSWORD
}
trap cleanup EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -eq 0 ]]; then
    TARGET_USER="${SUDO_USER:-}"
    [[ -n "$TARGET_USER" ]] || die "Run this installer as your normal user, not as root."
else
    TARGET_USER="$(id -un)"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || die "Unable to determine home directory for $TARGET_USER."

APP_HOME="$TARGET_HOME/pineapplexpress"
APP_DIR="$APP_HOME/app"
SCRIPT_HOME="$APP_HOME/scripts"
CONFIG_DIR="$APP_HOME/config"
DATA_DIR="$APP_HOME/data"
CAPTURE_DIR="$DATA_DIR/captures"
HOTSPOT_CAPTURE_DIR="$DATA_DIR/hotspot-captures"

DASHBOARD_SERVICE="pineapplexpress-dashboard.service"
MONITOR_COLLECTOR_SERVICE="pineapplexpress-packet-collector.service"
MONITOR_RECORDER_SERVICE="pineapplexpress-pcap-recorder.service"
HOTSPOT_COLLECTOR_SERVICE="pineapplexpress-hotspot-collector.service"
HOTSPOT_RECORDER_SERVICE="pineapplexpress-hotspot-pcap-recorder.service"

required_files=(
    "$SCRIPT_DIR/app/app.py"
    "$SCRIPT_DIR/scripts/packet_collector.py"
    "$SCRIPT_DIR/scripts/hotspot_packet_collector.py"
)

for file in "${required_files[@]}"; do
    [[ -f "$file" ]] || die "Missing required repository file: $file"
done

command -v sudo >/dev/null 2>&1 || die "sudo is required."

cat <<EOF

PineAppleXpress installer
-------------------------
Repository:      $SCRIPT_DIR
Install user:    $TARGET_USER
Runtime folder:  $APP_HOME

The installer will not modify wlan0 or interrupt the current management Wi-Fi connection.
EOF

read -rp "Authorized monitor-mode BSSID (leave blank to configure later): " AUTHORIZED_BSSID
read -rp "Authorized monitor-mode channel [44]: " AUTHORIZED_CHANNEL
AUTHORIZED_CHANNEL="${AUTHORIZED_CHANNEL:-44}"

read -rsp "Create PineAppleXpress-Lab hotspot password: " HOTSPOT_PASSWORD
echo
[[ ${#HOTSPOT_PASSWORD} -ge 8 ]] || die "Hotspot password must contain at least 8 characters."

read -rsp "Create dashboard login password: " DASHBOARD_PASSWORD
echo
read -rsp "Confirm dashboard login password: " DASHBOARD_PASSWORD_CONFIRM
echo

[[ -n "$DASHBOARD_PASSWORD" ]] || die "Dashboard password cannot be empty."
[[ "$DASHBOARD_PASSWORD" == "$DASHBOARD_PASSWORD_CONFIRM" ]] || die "Dashboard passwords did not match."

log "Installing operating-system packages"
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    python3 \
    python3-venv \
    python3-pip \
    python3-setuptools \
    git \
    curl \
    jq \
    iw \
    rfkill \
    usbutils \
    iproute2 \
    network-manager \
    dnsmasq-base \
    tshark \
    libcap2-bin \
    sudo \
    util-linux

log "Creating runtime directories"
install -d -m 755 \
    "$APP_HOME" \
    "$APP_DIR" \
    "$SCRIPT_HOME" \
    "$DATA_DIR" \
    "$CAPTURE_DIR" \
    "$HOTSPOT_CAPTURE_DIR"

install -d -m 700 "$CONFIG_DIR"

log "Copying application files"
install -m 644 "$SCRIPT_DIR/app/app.py" "$APP_DIR/app.py"
install -m 755 "$SCRIPT_DIR/scripts/packet_collector.py" "$SCRIPT_HOME/packet_collector.py"
install -m 755 "$SCRIPT_DIR/scripts/hotspot_packet_collector.py" "$SCRIPT_HOME/hotspot_packet_collector.py"

log "Creating Python virtual environment"
python3 -m venv "$APP_HOME/.venv"
"$APP_HOME/.venv/bin/pip" install --upgrade pip
"$APP_HOME/.venv/bin/pip" install \
    flask \
    gunicorn \
    Flask-WTF

log "Generating fresh local dashboard credentials"
DASHBOARD_PASSWORD="$DASHBOARD_PASSWORD" \
TARGET_HOME="$TARGET_HOME" \
"$APP_HOME/.venv/bin/python" - <<'PYEOF'
from __future__ import annotations

import os
from pathlib import Path
from secrets import token_hex

from werkzeug.security import generate_password_hash

target_home = Path(os.environ["TARGET_HOME"])
config_dir = target_home / "pineapplexpress" / "config"
config_dir.mkdir(parents=True, exist_ok=True)

secret_file = config_dir / "dashboard-secret.txt"
password_hash_file = config_dir / "dashboard-password.hash"

secret_file.write_text(token_hex(32))
password_hash_file.write_text(
    generate_password_hash(os.environ["DASHBOARD_PASSWORD"])
)

secret_file.chmod(0o600)
password_hash_file.chmod(0o600)

print("[OK] Fresh dashboard secret and password hash created.")
PYEOF

log "Configuring packet-capture permissions"
sudo groupadd -f wireshark
sudo usermod -aG wireshark "$TARGET_USER"
sudo chgrp wireshark /usr/bin/dumpcap
sudo chmod 750 /usr/bin/dumpcap
sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/dumpcap

log "Writing monitor-mode configuration"
sudo tee /etc/default/pineapplexpress-packets >/dev/null <<EOF
AUTHORIZED_BSSID=$AUTHORIZED_BSSID
AUTHORIZED_CHANNEL=$AUTHORIZED_CHANNEL
CAPTURE_INTERFACE=wlan1
CAPTURE_DIR=$CAPTURE_DIR
EOF

log "Writing hotspot configuration"
sudo tee /etc/default/pineapplexpress-hotspot >/dev/null <<EOF
HOTSPOT_PROFILE=PineAppleXpress-Lab
HOTSPOT_INTERFACE=wlan1
HOTSPOT_ADDRESS=10.42.50.1/24
HOTSPOT_SUBNET=10.42.50.0/24
CAPTURE_INTERFACE=any
CAPTURE_DIR=$HOTSPOT_CAPTURE_DIR
EOF

log "Creating saved hotspot profile"
if nmcli -t -f NAME connection show | grep -Fxq "PineAppleXpress-Lab"; then
    sudo nmcli connection delete PineAppleXpress-Lab >/dev/null
fi

sudo nmcli connection add \
    type wifi \
    ifname wlan1 \
    con-name PineAppleXpress-Lab \
    autoconnect no \
    ssid PineAppleXpress-Lab \
    >/dev/null

sudo nmcli connection modify \
    PineAppleXpress-Lab \
    802-11-wireless.mode ap \
    802-11-wireless.band bg \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$HOTSPOT_PASSWORD" \
    ipv4.method shared \
    ipv4.addresses 10.42.50.1/24 \
    ipv4.never-default yes \
    ipv6.method disabled

log "Installing root-owned PCAPNG recorders"
sudo tee /usr/local/sbin/pineapplexpress-pcap-recorder >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

: "${AUTHORIZED_BSSID:?AUTHORIZED_BSSID must be configured in /etc/default/pineapplexpress-packets}"
: "${CAPTURE_INTERFACE:=wlan1}"
: "${CAPTURE_DIR:?CAPTURE_DIR is required}"

if ! [[ "$AUTHORIZED_BSSID" =~ ^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$ ]]; then
    echo "Invalid AUTHORIZED_BSSID: $AUTHORIZED_BSSID"
    exit 1
fi

mkdir -p "$CAPTURE_DIR"

FILTER="wlan addr1 $AUTHORIZED_BSSID or wlan addr2 $AUTHORIZED_BSSID or wlan addr3 $AUTHORIZED_BSSID or wlan addr4 $AUTHORIZED_BSSID"

exec /usr/bin/dumpcap \
    -i "$CAPTURE_INTERFACE" \
    -n \
    -q \
    -f "$FILTER" \
    -w "$CAPTURE_DIR/pineapplexpress.pcapng" \
    -b filesize:10240 \
    -b duration:60 \
    -b files:10 \
    -b printname:"$CAPTURE_DIR/latest-closed.txt"
EOF

sudo tee /usr/local/sbin/pineapplexpress-hotspot-pcap-recorder >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

: "${CAPTURE_INTERFACE:=any}"
: "${CAPTURE_DIR:?CAPTURE_DIR is required}"
: "${HOTSPOT_SUBNET:=10.42.50.0/24}"

mkdir -p "$CAPTURE_DIR"

exec /usr/bin/dumpcap \
    -i "$CAPTURE_INTERFACE" \
    -n \
    -q \
    -f "net $HOTSPOT_SUBNET" \
    -w "$CAPTURE_DIR/pineapplexpress-hotspot.pcapng" \
    -b filesize:10240 \
    -b duration:60 \
    -b files:10 \
    -b printname:"$CAPTURE_DIR/latest-closed.txt"
EOF

sudo chmod 755 \
    /usr/local/sbin/pineapplexpress-pcap-recorder \
    /usr/local/sbin/pineapplexpress-hotspot-pcap-recorder

sudo chown root:root \
    /usr/local/sbin/pineapplexpress-pcap-recorder \
    /usr/local/sbin/pineapplexpress-hotspot-pcap-recorder

log "Installing root-owned radio mode scripts"
sudo tee /usr/local/sbin/pineapplexpress-mode-monitor >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

IFACE="wlan1"
HOTSPOT_PROFILE="PineAppleXpress-Lab"

MONITOR_COLLECTOR="pineapplexpress-packet-collector.service"
MONITOR_RECORDER="pineapplexpress-pcap-recorder.service"
HOTSPOT_COLLECTOR="pineapplexpress-hotspot-collector.service"
HOTSPOT_RECORDER="pineapplexpress-hotspot-pcap-recorder.service"

exec 9>/run/lock/pineapplexpress-radio.lock
flock -n 9 || { echo "A radio mode change is already in progress."; exit 1; }

source /etc/default/pineapplexpress-packets

[[ -n "${AUTHORIZED_BSSID:-}" ]] || {
    echo "Monitor mode requires AUTHORIZED_BSSID in /etc/default/pineapplexpress-packets."
    exit 1
}

iw dev "$IFACE" info >/dev/null 2>&1 || {
    echo "USB wireless adapter $IFACE was not found."
    exit 1
}

systemctl stop "$HOTSPOT_RECORDER" 2>/dev/null || true
systemctl stop "$HOTSPOT_COLLECTOR" 2>/dev/null || true
nmcli connection down "$HOTSPOT_PROFILE" 2>/dev/null || true

nmcli device set "$IFACE" managed no
ip link set "$IFACE" down
iw dev "$IFACE" set type monitor
ip link set "$IFACE" up
iw dev "$IFACE" set channel "${AUTHORIZED_CHANNEL:-44}"

systemctl restart "$MONITOR_COLLECTOR"
systemctl restart "$MONITOR_RECORDER"

echo "$IFACE is active in Monitor mode on channel ${AUTHORIZED_CHANNEL:-44}."
echo "wlan0 was not modified."
EOF

sudo tee /usr/local/sbin/pineapplexpress-mode-hotspot >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

IFACE="wlan1"
HOTSPOT_PROFILE="PineAppleXpress-Lab"

MONITOR_COLLECTOR="pineapplexpress-packet-collector.service"
MONITOR_RECORDER="pineapplexpress-pcap-recorder.service"
HOTSPOT_COLLECTOR="pineapplexpress-hotspot-collector.service"
HOTSPOT_RECORDER="pineapplexpress-hotspot-pcap-recorder.service"

exec 9>/run/lock/pineapplexpress-radio.lock
flock -n 9 || { echo "A radio mode change is already in progress."; exit 1; }

iw dev "$IFACE" info >/dev/null 2>&1 || {
    echo "USB wireless adapter $IFACE was not found."
    exit 1
}

systemctl stop "$MONITOR_RECORDER" 2>/dev/null || true
systemctl stop "$MONITOR_COLLECTOR" 2>/dev/null || true

nmcli device set "$IFACE" managed no
ip link set "$IFACE" down
iw dev "$IFACE" set type managed
ip addr flush dev "$IFACE"
ip link set "$IFACE" up
nmcli device set "$IFACE" managed yes

nmcli connection up "$HOTSPOT_PROFILE" ifname "$IFACE"

systemctl restart "$HOTSPOT_COLLECTOR"
systemctl restart "$HOTSPOT_RECORDER"

echo "$IFACE is serving $HOTSPOT_PROFILE."
echo "wlan0 was not modified."
EOF

sudo tee /usr/local/sbin/pineapplexpress-mode-off >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

IFACE="wlan1"
HOTSPOT_PROFILE="PineAppleXpress-Lab"

MONITOR_COLLECTOR="pineapplexpress-packet-collector.service"
MONITOR_RECORDER="pineapplexpress-pcap-recorder.service"
HOTSPOT_COLLECTOR="pineapplexpress-hotspot-collector.service"
HOTSPOT_RECORDER="pineapplexpress-hotspot-pcap-recorder.service"

exec 9>/run/lock/pineapplexpress-radio.lock
flock -n 9 || { echo "A radio mode change is already in progress."; exit 1; }

systemctl stop "$MONITOR_RECORDER" 2>/dev/null || true
systemctl stop "$MONITOR_COLLECTOR" 2>/dev/null || true
systemctl stop "$HOTSPOT_RECORDER" 2>/dev/null || true
systemctl stop "$HOTSPOT_COLLECTOR" 2>/dev/null || true

nmcli connection down "$HOTSPOT_PROFILE" 2>/dev/null || true

if iw dev "$IFACE" info >/dev/null 2>&1; then
    nmcli device set "$IFACE" managed no
    ip link set "$IFACE" down
    iw dev "$IFACE" set type managed
    ip addr flush dev "$IFACE"
    ip link set "$IFACE" up
    nmcli device set "$IFACE" managed yes
fi

echo "$IFACE is idle."
echo "wlan0 was not modified."
EOF

sudo chmod 755 \
    /usr/local/sbin/pineapplexpress-mode-monitor \
    /usr/local/sbin/pineapplexpress-mode-hotspot \
    /usr/local/sbin/pineapplexpress-mode-off

sudo chown root:root \
    /usr/local/sbin/pineapplexpress-mode-monitor \
    /usr/local/sbin/pineapplexpress-mode-hotspot \
    /usr/local/sbin/pineapplexpress-mode-off

log "Installing systemd services"
sudo tee "/etc/systemd/system/$DASHBOARD_SERVICE" >/dev/null <<EOF
[Unit]
Description=PineAppleXpress Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_HOME/.venv/bin/gunicorn --workers 1 --bind 0.0.0.0:8080 app:app
Restart=on-failure
RestartSec=3
NoNewPrivileges=false
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee "/etc/systemd/system/$MONITOR_COLLECTOR_SERVICE" >/dev/null <<EOF
[Unit]
Description=PineAppleXpress Wireless Metadata Collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
SupplementaryGroups=wireshark
EnvironmentFile=/etc/default/pineapplexpress-packets
WorkingDirectory=$APP_HOME
ExecStart=/usr/bin/python3 $SCRIPT_HOME/packet_collector.py
Restart=always
RestartSec=3
NoNewPrivileges=false
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee "/etc/systemd/system/$MONITOR_RECORDER_SERVICE" >/dev/null <<EOF
[Unit]
Description=PineAppleXpress Wireless PCAPNG Recorder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
SupplementaryGroups=wireshark
EnvironmentFile=/etc/default/pineapplexpress-packets
ExecStart=/usr/local/sbin/pineapplexpress-pcap-recorder
Restart=on-failure
RestartSec=3
NoNewPrivileges=false
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee "/etc/systemd/system/$HOTSPOT_COLLECTOR_SERVICE" >/dev/null <<EOF
[Unit]
Description=PineAppleXpress Decoded Hotspot Traffic Collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
SupplementaryGroups=wireshark
EnvironmentFile=/etc/default/pineapplexpress-hotspot
WorkingDirectory=$APP_HOME
ExecStart=/usr/bin/python3 $SCRIPT_HOME/hotspot_packet_collector.py
Restart=always
RestartSec=3
NoNewPrivileges=false
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee "/etc/systemd/system/$HOTSPOT_RECORDER_SERVICE" >/dev/null <<EOF
[Unit]
Description=PineAppleXpress Hotspot PCAPNG Recorder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
SupplementaryGroups=wireshark
EnvironmentFile=/etc/default/pineapplexpress-hotspot
ExecStart=/usr/local/sbin/pineapplexpress-hotspot-pcap-recorder
Restart=on-failure
RestartSec=3
NoNewPrivileges=false
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

log "Installing restricted sudo policy for dashboard mode controls"
sudo tee /etc/sudoers.d/pineapplexpress-dashboard >/dev/null <<EOF
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/sbin/pineapplexpress-mode-monitor, /usr/local/sbin/pineapplexpress-mode-hotspot, /usr/local/sbin/pineapplexpress-mode-off
EOF

sudo chmod 440 /etc/sudoers.d/pineapplexpress-dashboard
sudo visudo -cf /etc/sudoers.d/pineapplexpress-dashboard

log "Reloading systemd"
sudo systemctl daemon-reload

log "Enabling dashboard at boot"
sudo systemctl enable --now "$DASHBOARD_SERVICE"

log "Keeping capture services disabled until selected from the dashboard"
sudo systemctl disable \
    "$MONITOR_COLLECTOR_SERVICE" \
    "$MONITOR_RECORDER_SERVICE" \
    "$HOTSPOT_COLLECTOR_SERVICE" \
    "$HOTSPOT_RECORDER_SERVICE" \
    >/dev/null 2>&1 || true

sudo systemctl stop \
    "$MONITOR_COLLECTOR_SERVICE" \
    "$MONITOR_RECORDER_SERVICE" \
    "$HOTSPOT_COLLECTOR_SERVICE" \
    "$HOTSPOT_RECORDER_SERVICE" \
    >/dev/null 2>&1 || true

log "Validating dashboard"
sleep 2

if curl -fsS http://127.0.0.1:8080/api/health >/dev/null; then
    echo "[OK] Dashboard health endpoint is responding."
else
    warn "Dashboard health endpoint did not respond. Inspect logs with:"
    echo "  sudo journalctl -u $DASHBOARD_SERVICE --no-pager -n 100"
fi

cat <<EOF

============================================================
PineAppleXpress installation complete
============================================================

Dashboard:
  http://pineapplexpress.local:8080

If .local name resolution does not work:
  hostname -I

Radio modes:
  Monitor Mode  -> wlan1 passive wireless recon
  Hotspot Mode  -> wlan1 serves PineAppleXpress-Lab
  Off Mode      -> wlan1 idle

Management:
  wlan0 was not modified.

Important:
  - Log out and back in once so the new wireshark group membership applies
    to your interactive shell.
  - The systemd services already receive the wireshark supplementary group.
  - If monitor mode was left unconfigured, edit:
      /etc/default/pineapplexpress-packets
  - To inspect the dashboard:
      sudo systemctl status $DASHBOARD_SERVICE --no-pager
  - To inspect logs:
      sudo journalctl -u $DASHBOARD_SERVICE --no-pager -n 100

EOF
