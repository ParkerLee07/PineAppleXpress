#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# PineAppleXpress Bootstrap Installer
# Raspberry Pi OS Lite / Debian-based systems
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ParkerLee07/PineAppleXpress/main/install_pineapplexpress.sh | bash
#
# Or:
#   chmod +x install_pineapplexpress.sh
#   ./install_pineapplexpress.sh
#
# This installer:
# - downloads PineAppleXpress from GitHub automatically
# - installs dependencies
# - installs the app into the current user's home directory
# - creates a Python virtual environment
# - generates dashboard credentials
# - configures packet-capture permissions
# - creates PineAppleXpress-Lab hotspot profile
# - installs radio mode scripts
# - installs user-agnostic systemd services
# - enables only the dashboard by default
#
# It does NOT:
# - modify wlan0
# - start hotspot mode automatically
# - start monitor mode automatically
# - store wireless PMKs or decryption keys
# ============================================================

REPO_OWNER="ParkerLee07"
REPO_NAME="PineAppleXpress"
REPO_BRANCH="main"
ARCHIVE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz"

APP_NAME="pineapplexpress"

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
    unset DASHBOARD_PASSWORD DASHBOARD_PASSWORD_CONFIRM HOTSPOT_PASSWORD || true
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

if [[ "${EUID}" -eq 0 ]]; then
    TARGET_USER="${SUDO_USER:-}"
    [[ -n "$TARGET_USER" ]] || die "Run this installer as your normal user, not directly as root."
else
    TARGET_USER="$(id -un)"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || die "Unable to determine home directory for $TARGET_USER."

APP_HOME="$TARGET_HOME/$APP_NAME"
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

command -v sudo >/dev/null 2>&1 || die "sudo is required."

log "Installing base dependencies"

sudo apt update
sudo apt install -y \
    curl \
    ca-certificates \
    tar \
    python3 \
    python3-venv \
    python3-pip \
    network-manager \
    wireless-tools \
    iw \
    tcpdump \
    tshark \
    wireshark-common \
    libcap2-bin \
    iproute2 \
    net-tools \
    rfkill \
    jq

log "Downloading PineAppleXpress from GitHub"

TMP_DIR="$(mktemp -d)"
ARCHIVE_PATH="$TMP_DIR/pineapplexpress.tar.gz"
EXTRACT_DIR="$TMP_DIR/extract"

mkdir -p "$EXTRACT_DIR"

curl -fL "$ARCHIVE_URL" -o "$ARCHIVE_PATH"

tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

SOURCE_DIR="$(find "$EXTRACT_DIR" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n 1)"
[[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR" ]] || die "Failed to locate extracted PineAppleXpress source."

required_files=(
    "$SOURCE_DIR/app/app.py"
    "$SOURCE_DIR/scripts/packet_collector.py"
    "$SOURCE_DIR/scripts/hotspot_packet_collector.py"
)

for file in "${required_files[@]}"; do
    [[ -f "$file" ]] || die "Missing required repository file: $file"
done

log "Installing PineAppleXpress into $APP_HOME"

sudo mkdir -p "$APP_HOME"
sudo rsync -a --delete \
    --exclude ".git" \
    --exclude ".venv" \
    --exclude "data" \
    "$SOURCE_DIR/" "$APP_HOME/"

sudo chown -R "$TARGET_USER:$TARGET_USER" "$APP_HOME"

mkdir -p \
    "$DATA_DIR" \
    "$CAPTURE_DIR" \
    "$HOTSPOT_CAPTURE_DIR"

sudo chown -R "$TARGET_USER:$TARGET_USER" "$DATA_DIR"

log "Creating Python virtual environment"

sudo -u "$TARGET_USER" python3 -m venv "$APP_HOME/.venv"

if [[ -f "$APP_HOME/requirements.txt" ]]; then
    sudo -u "$TARGET_USER" "$APP_HOME/.venv/bin/pip" install --upgrade pip
    sudo -u "$TARGET_USER" "$APP_HOME/.venv/bin/pip" install -r "$APP_HOME/requirements.txt"
else
    sudo -u "$TARGET_USER" "$APP_HOME/.venv/bin/pip" install --upgrade pip
    sudo -u "$TARGET_USER" "$APP_HOME/.venv/bin/pip" install flask gunicorn
fi

log "Configuring dashboard credentials"

read -r -p "Dashboard username [admin]: " DASHBOARD_USERNAME
DASHBOARD_USERNAME="${DASHBOARD_USERNAME:-admin}"

while true; do
    read -r -s -p "Dashboard password: " DASHBOARD_PASSWORD
    echo
    read -r -s -p "Confirm dashboard password: " DASHBOARD_PASSWORD_CONFIRM
    echo

    if [[ -z "$DASHBOARD_PASSWORD" ]]; then
        warn "Dashboard password cannot be empty."
    elif [[ "$DASHBOARD_PASSWORD" != "$DASHBOARD_PASSWORD_CONFIRM" ]]; then
        warn "Passwords do not match."
    else
        break
    fi
done

sudo tee /etc/default/pineapplexpress-dashboard >/dev/null <<EOF
PX_DASHBOARD_USER="$DASHBOARD_USERNAME"
PX_DASHBOARD_PASSWORD="$DASHBOARD_PASSWORD"
PX_APP_HOME="$APP_HOME"
EOF

sudo chmod 600 /etc/default/pineapplexpress-dashboard
sudo chown root:root /etc/default/pineapplexpress-dashboard

log "Configuring monitor capture defaults"

read -r -p "Authorized BSSID for monitor mode, blank to configure later: " AUTHORIZED_BSSID
read -r -p "Authorized Wi-Fi channel [44]: " AUTHORIZED_CHANNEL
AUTHORIZED_CHANNEL="${AUTHORIZED_CHANNEL:-44}"

sudo tee /etc/default/pineapplexpress-packets >/dev/null <<EOF
AUTHORIZED_BSSID="$AUTHORIZED_BSSID"
AUTHORIZED_CHANNEL="$AUTHORIZED_CHANNEL"
CAPTURE_INTERFACE="wlan1"
CAPTURE_DIR="$CAPTURE_DIR"
EOF

sudo chmod 644 /etc/default/pineapplexpress-packets
sudo chown root:root /etc/default/pineapplexpress-packets

log "Configuring hotspot capture defaults"

sudo tee /etc/default/pineapplexpress-hotspot >/dev/null <<EOF
CAPTURE_INTERFACE="any"
CAPTURE_DIR="$HOTSPOT_CAPTURE_DIR"
HOTSPOT_SUBNET="10.42.50.0/24"
EOF

sudo chmod 644 /etc/default/pineapplexpress-hotspot
sudo chown root:root /etc/default/pineapplexpress-hotspot

log "Configuring dumpcap permissions"

if getent group wireshark >/dev/null 2>&1; then
    sudo usermod -aG wireshark "$TARGET_USER"
fi

if command -v dumpcap >/dev/null 2>&1; then
    sudo setcap cap_net_raw,cap_net_admin=eip "$(command -v dumpcap)" || \
        warn "Could not set dumpcap capabilities. Packet capture may require root."
fi

log "Creating PineAppleXpress-Lab hotspot profile"

while true; do
    read -r -s -p "Hotspot WPA password, minimum 8 characters: " HOTSPOT_PASSWORD
    echo

    if [[ "${#HOTSPOT_PASSWORD}" -lt 8 ]]; then
        warn "Hotspot password must be at least 8 characters."
    else
        break
    fi
done

if nmcli connection show PineAppleXpress-Lab >/dev/null 2>&1; then
    sudo nmcli connection delete PineAppleXpress-Lab >/dev/null 2>&1 || true
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

log "Installing root-owned PCAPNG recorder scripts"

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
flock -n 9 || {
    echo "A radio mode change is already in progress."
    exit 1
}

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

echo "$IFACE is active in monitor mode on channel ${AUTHORIZED_CHANNEL:-44}."
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
flock -n 9 || {
    echo "A radio mode change is already in progress."
    exit 1
}

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
flock -n 9 || {
    echo "A radio mode change is already in progress."
    exit 1
}

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

log "Installing user-agnostic systemd services"

sudo tee "/etc/systemd/system/$DASHBOARD_SERVICE" >/dev/null <<EOF
[Unit]
Description=PineAppleXpress Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
EnvironmentFile=/etc/default/pineapplexpress-dashboard
WorkingDirectory=$APP_DIR
ExecStart=$APP_HOME/.venv/bin/gunicorn --workers 1 --bind 0.0.0.0:8080 app:app
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee "/etc/systemd/system/$MONITOR_COLLECTOR_SERVICE" >/dev/null <<EOF
[Unit]
Description=PineAppleXpress Authorized Packet Metadata Collector
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
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee "/etc/systemd/system/$MONITOR_RECORDER_SERVICE" >/dev/null <<EOF
[Unit]
Description=PineAppleXpress Authorized PCAPNG Recorder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/pineapplexpress-packets
ExecStart=/usr/local/sbin/pineapplexpress-pcap-recorder
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo tee "/etc/systemd/system/$HOTSPOT_COLLECTOR_SERVICE" >/dev/null <<EOF
[Unit]
Description=PineAppleXpress Hotspot Packet Metadata Collector
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
NoNewPrivileges=true
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
EnvironmentFile=/etc/default/pineapplexpress-hotspot
ExecStart=/usr/local/sbin/pineapplexpress-hotspot-pcap-recorder
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 /etc/systemd/system/pineapplexpress*.service
sudo chown root:root /etc/systemd/system/pineapplexpress*.service

log "Reloading systemd"

sudo systemctl daemon-reload

log "Enabling dashboard service"

sudo systemctl enable "$DASHBOARD_SERVICE"
sudo systemctl restart "$DASHBOARD_SERVICE"

sudo systemctl stop \
    "$MONITOR_COLLECTOR_SERVICE" \
    "$MONITOR_RECORDER_SERVICE" \
    "$HOTSPOT_COLLECTOR_SERVICE" \
    "$HOTSPOT_RECORDER_SERVICE" \
    >/dev/null 2>&1 || true

sudo systemctl disable \
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
    warn "Dashboard health endpoint did not respond."
    echo "Inspect logs with:"
    echo "  sudo journalctl -u $DASHBOARD_SERVICE --no-pager -n 100"
fi

cat <<EOF

============================================================
PineAppleXpress installation complete
============================================================

Installed to:
  $APP_HOME

Dashboard:
  http://<raspberry-pi-ip>:8080

Dashboard username:
  $DASHBOARD_USERNAME

Services:
  Dashboard:
    sudo systemctl status $DASHBOARD_SERVICE --no-pager

  Monitor mode:
    sudo /usr/local/sbin/pineapplexpress-mode-monitor

  Hotspot mode:
    sudo /usr/local/sbin/pineapplexpress-mode-hotspot

  Off mode:
    sudo /usr/local/sbin/pineapplexpress-mode-off

Management:
  wlan0 was not modified.

Important:
  Log out and back in once so the new wireshark group membership applies
  to your interactive shell.

If monitor mode was left unconfigured, edit:
  sudo nano /etc/default/pineapplexpress-packets

To inspect dashboard logs:
  sudo journalctl -u $DASHBOARD_SERVICE --no-pager -n 100

EOF
