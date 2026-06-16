#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="pineapplexpress"
APP_HOME="${PX_APP_HOME:-$HOME/$APP_NAME}"

PURGE=0

for arg in "$@"; do
    case "$arg" in
        --purge)
            PURGE=1
            ;;
        -h|--help)
            echo "Usage: ./uninstall_pineapplexpress.sh [--purge]"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            exit 1
            ;;
    esac
done

log() {
    printf '\n[+] %s\n' "$*"
}

warn() {
    printf '\n[!] %s\n' "$*" >&2
}

SERVICES=(
    pineapplexpress-dashboard.service
    pineapplexpress-packet-collector.service
    pineapplexpress-pcap-recorder.service
    pineapplexpress-hotspot-collector.service
    pineapplexpress-hotspot-pcap-recorder.service
)

log "Stopping PineAppleXpress services"

for service in "${SERVICES[@]}"; do
    sudo systemctl stop "$service" 2>/dev/null || true
    sudo systemctl disable "$service" 2>/dev/null || true
done

log "Removing PineAppleXpress systemd service files"

for service in "${SERVICES[@]}"; do
    sudo rm -f "/etc/systemd/system/$service"
done

sudo systemctl daemon-reload
sudo systemctl reset-failed >/dev/null 2>&1 || true

log "Removing PineAppleXpress mode and recorder scripts"

sudo rm -f \
    /usr/local/sbin/pineapplexpress-mode-monitor \
    /usr/local/sbin/pineapplexpress-mode-hotspot \
    /usr/local/sbin/pineapplexpress-mode-off \
    /usr/local/sbin/pineapplexpress-pcap-recorder \
    /usr/local/sbin/pineapplexpress-hotspot-pcap-recorder

log "Removing PineAppleXpress environment files"

sudo rm -f \
    /etc/default/pineapplexpress-dashboard \
    /etc/default/pineapplexpress-packets \
    /etc/default/pineapplexpress-hotspot

log "Removing PineAppleXpress NetworkManager hotspot profile"

if command -v nmcli >/dev/null 2>&1; then
    sudo nmcli connection delete PineAppleXpress-Lab >/dev/null 2>&1 || true
fi

if [[ "$PURGE" -eq 1 ]]; then
    log "Purging PineAppleXpress project directory: $APP_HOME"
    rm -rf "$APP_HOME"
else
    warn "Project files were not deleted."
    echo "To delete them too, run:"
    echo "  ./uninstall_pineapplexpress.sh --purge"
fi

log "PineAppleXpress uninstall complete"
