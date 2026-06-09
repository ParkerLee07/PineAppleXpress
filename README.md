# PineAppleXpress

PineAppleXpress is a lightweight Raspberry Pi OS Lite wireless auditing appliance designed for authorized lab and security-assessment use. The PineAppleXpress was inspired by the Hak5 WiFi Pineapple series of devices.

## Features

- Headless Raspberry Pi OS Lite deployment
- Password-protected Flask dashboard
- Panda Wireless PAU0D external radio support
- Wireless monitor mode
- PineAppleXpress-Lab access-point mode
- Three-state radio controls: Monitor, Hotspot, and Off
- Live color-coded wireless metadata table
- Live decoded hotspot traffic table
- Rolling PCAPNG recording
- Authenticated capture download
- Lightweight design for a Raspberry Pi 4B with 2 GB RAM

## Interface Roles

| Interface | Purpose |
|---|---|
| wlan0 | Management Wi-Fi, SSH, and dashboard access |
| wlan1 | External USB adapter used for monitor mode or hotspot mode |
| eth0 | Optional future wired interface |

## Operating Modes

### Monitor Mode

Uses wlan1 as a passive wireless reconnaissance adapter.

### Hotspot Mode

Uses wlan1 to host PineAppleXpress-Lab. Devices intentionally connected to the hotspot can be inspected at the IP layer after Wi-Fi decryption occurs on the Pi.

### Off Mode

Stops capture services and leaves wlan1 idle.

## Safety

Use PineAppleXpress only on networks and devices that you own or are explicitly authorized to assess. Do not expose the control dashboard directly to the public internet.

## Installation
## Installation

The installer is currently in active development.

```bash
git clone <repository clone command>
cd PineAppleXpress
chmod +x install_pineapplexpress.sh
sudo ./install_pineapplexpress.sh
```

## License

Add your preferred open-source license before redistribution.
