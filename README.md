# PineAppleXpress

PineAppleXpress is a lightweight Raspberry Pi OS Lite wireless-auditing appliance designed for authorized lab and security-assessment use.

It is inspired by the Hak5 WiFi Pineapple series of devices, but is built as an educational, self-hosted Raspberry Pi project focused on wireless visibility, controlled hotspot testing, packet metadata, and local capture management.

## Features

* Headless Raspberry Pi OS Lite deployment
* Password-protected Flask dashboard
* Panda Wireless PAU0D external radio support
* Wireless monitor mode
* `PineAppleXpress-Lab` access-point mode
* Three-state radio controls:

  * Monitor
  * Hotspot
  * Off
* Live color-coded wireless metadata table
* Live decoded hotspot traffic table
* Rolling PCAPNG recording
* Authenticated capture download
* Lightweight design for Raspberry Pi hardware

## Interface Roles

| Interface | Purpose                                                    |
| --------- | ---------------------------------------------------------- |
| `wlan0`   | Management Wi-Fi, SSH, and dashboard access                |
| `wlan1`   | External USB adapter used for monitor mode or hotspot mode |
| `eth0`    | Optional wired interface                                   |

## Operating Modes

### Monitor Mode

Monitor mode uses `wlan1` as a passive wireless reconnaissance adapter for authorized wireless observation. It can collect packet metadata and rolling PCAPNG files for later review.

### Hotspot Mode

Hotspot mode uses `wlan1` to host the `PineAppleXpress-Lab` access point. Devices intentionally connected to the hotspot can be inspected at the IP layer after Wi-Fi decryption occurs on the Pi.

### Off Mode

Off mode stops capture services and leaves `wlan1` idle while preserving management access through `wlan0`.

## Installation

Run the bootstrap installer:

```bash
curl -fsSL https://raw.githubusercontent.com/ParkerLee07/PineAppleXpress/main/install_pineapplexpress.sh | bash
```

Or clone the repository manually:

```bash
git clone https://github.com/ParkerLee07/PineAppleXpress.git
cd PineAppleXpress
chmod +x install_pineapplexpress.sh
./install_pineapplexpress.sh
```

The installer will:

* Download PineAppleXpress automatically
* Install required packages
* Create the application directory in the installing user's home folder
* Create the Python virtual environment
* Configure dashboard credentials
* Configure packet-capture defaults
* Create the `PineAppleXpress-Lab` hotspot profile
* Install radio-control scripts
* Install user-specific systemd services
* Enable the dashboard service by default

The installer does not modify `wlan0`, does not start hotspot mode automatically, and does not start monitor mode automatically.

## Dashboard

After installation, open:

```text
http://<raspberry-pi-ip>:8080
```

Check the dashboard service:

```bash
sudo systemctl status pineapplexpress-dashboard.service --no-pager
```

View dashboard logs:

```bash
sudo journalctl -u pineapplexpress-dashboard.service --no-pager -n 100
```

## Radio Controls

Enable monitor mode:

```bash
sudo /usr/local/sbin/pineapplexpress-mode-monitor
```

Enable hotspot mode:

```bash
sudo /usr/local/sbin/pineapplexpress-mode-hotspot
```

Turn the external radio off:

```bash
sudo /usr/local/sbin/pineapplexpress-mode-off
```

## Configuration

Monitor-mode defaults are stored in:

```bash
/etc/default/pineapplexpress-packets
```

Hotspot capture defaults are stored in:

```bash
/etc/default/pineapplexpress-hotspot
```

Dashboard credentials are stored in:

```bash
/etc/default/pineapplexpress-dashboard
```

## Uninstall

From the installed project directory:

```bash
cd ~/pineapplexpress
./uninstall.sh
```

This removes services, mode scripts, environment files, and the NetworkManager hotspot profile while keeping the project files.

To remove the project directory as well:

```bash
./uninstall.sh --purge
```

## Safety

Use PineAppleXpress only on networks and devices that you own or are explicitly authorized to assess.

Do not expose the dashboard directly to the public internet.

Do not use the hotspot or capture features against third-party devices or networks without permission.

## License

MIT License
