# flight-tracker-flasher

Flash a micro SD card with Raspberry Pi OS Lite (Bookworm) pre-configured for the [flight-tracker-led](https://github.com/nolanlawson/flight-tracker-led) project. No monitor, keyboard, or manual setup needed.

## Requirements

- Linux host with `dd`, `mount`, `lsblk`, `openssl`, `curl` (or `wget`)
- `xz-utils` (for `.img.xz` decompression)
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
| Target device | The SD card block device (e.g. `/dev/sdb`) |

### Options

```
--image PATH    Use a local OS image instead of downloading
                Supports: .img, .img.xz, .img.gz, .zip
--help          Show help message
```

### Examples

```bash
# Download and flash (image is cached for future runs)
sudo ./flash.sh

# Use a local image file
sudo ./flash.sh --image ~/Downloads/2024-11-19-raspios-bookworm-armhf-lite.img.xz
```

## What it does

1. **Downloads** Raspberry Pi OS Lite (32-bit, armhf) — cached in `~/.cache/flight-tracker-flasher/`
2. **Flashes** the image to the SD card using `dd`
3. **Configures the boot partition**: enables SSH, sets up user credentials, creates a first-run script
4. **Configures the root filesystem**: writes WiFi credentials for NetworkManager

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
