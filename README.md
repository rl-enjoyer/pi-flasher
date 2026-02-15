# flight-tracker-flasher

Flash a micro SD card with Raspberry Pi OS Lite (Bookworm) pre-configured for the [flight-display](https://github.com/rl-enjoyer/flight-display) project. No monitor, keyboard, or manual setup needed.

## Requirements

- macOS with `diskutil`, `dd`, `openssl`, `curl` (or `wget`)
- `xz` (for `.img.xz` decompression — `brew install xz`)
- Root privileges (`sudo`)

## Usage

```bash
sudo ./flash.sh
```

The script will prompt for:

| Prompt | Description |
|--------|-------------|
| WiFi SSID | Your wireless network name |
| WiFi password | Your wireless network password |
| Latitude | Decimal degrees (e.g. `39.5259`) |
| Longitude | Decimal degrees (e.g. `-76.4352`) |
| Hostname | Defaults to `flight-tracker` |
| Username | Defaults to `pi` |
| Password | Password for the Pi user account |
| Target device | The SD card disk (e.g. `/dev/disk4`) |

### Options

```
--image PATH         Use a local OS image instead of downloading
                     Supports: .img, .img.xz, .img.gz, .zip
--dry-run            Run through prompts without flashing (no sudo required)
--ssid SSID          WiFi network name
--wifi-password PASS WiFi password
--lat VALUE          Latitude in decimal degrees
--lon VALUE          Longitude in decimal degrees
--hostname NAME      Pi hostname (default: flight-tracker)
--username NAME      Pi username (default: pi)
--password PASS      Pi user password
--device PATH        Target device (e.g. /dev/disk4)
--yes, -y            Skip the erase confirmation prompt
--help, -h           Show help message
```

All flags are optional. Missing values will be prompted for interactively.

### Examples

```bash
# Interactive — prompts for everything
sudo ./flash.sh

# Fully non-interactive
sudo ./flash.sh --ssid MyWifi --wifi-password secret \
  --lat 39.5 --lon -76.4 --password pass123 \
  --device /dev/disk4 --yes

# Use a local image file
sudo ./flash.sh --image ~/Downloads/2024-11-19-raspios-bookworm-armhf-lite.img.xz

# Dry run — test without flashing
./flash.sh --dry-run --ssid MyWifi --wifi-password secret \
  --lat 39.5 --lon -76.4 --password pass123 \
  --device /dev/disk4 --yes
```

## What it does

1. **Downloads** Raspberry Pi OS Lite (32-bit, armhf) — cached in `~/.cache/flight-tracker-flasher/`
2. **Flashes** the image to the SD card using `dd` (via raw device `/dev/rdiskN` for speed)
3. **Configures the boot partition**: enables SSH, sets up user credentials, creates a first-run script that configures WiFi on first boot

## Boot sequence

The Pi goes through three boots after you insert the card:

| Boot | What happens |
|------|-------------|
| 1st | `firstrun.sh` sets hostname, timezone, WiFi, SSH, disables onboard audio, creates setup service. Reboots. |
| 2nd | Setup service runs with network: installs packages, clones repo, builds dependencies, creates flight-tracker service. Reboots. |
| 3rd | Flight tracker starts normally. |

Total time from first power-on to running: ~5–10 minutes (depending on network speed and Pi model).

## After flashing

```bash
ssh pi@flight-tracker.local
```

You can monitor the second-stage setup progress:

```bash
ssh pi@flight-tracker.local
sudo journalctl -fu flight-tracker-setup.service
# or
sudo tail -f /var/log/flight-tracker-setup.log
```
