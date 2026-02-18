#!/usr/bin/env bash
#
# flight-tracker-flasher — Flash an SD card with Raspberry Pi OS Lite
# pre-configured for the flight-tracker-led project.
#
# Designed for macOS. Uses diskutil for disk management and avoids
# mounting the ext4 root partition (not natively supported on macOS).
#
# Usage: sudo ./flash.sh [OPTIONS]
#
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

IMAGE_URL_LITE="https://downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-2024-11-19/2024-11-19-raspios-bookworm-armhf-lite.img.xz"
IMAGE_URL_DESKTOP="https://downloads.raspberrypi.com/raspios_armhf/images/raspios_armhf-2024-11-19/2024-11-19-raspios-bookworm-armhf.img.xz"
IMAGE_URL="$IMAGE_URL_LITE"
CACHE_DIR="${HOME}/.cache/flight-tracker-flasher"
BOOT_MOUNT=""
TARGET_DEV=""
IMAGE_ARG=""
DRY_RUN=false
USE_DESKTOP=false
WIFI_SSID=""
WIFI_PASS=""
LATITUDE=""
LONGITUDE=""
PI_HOSTNAME=""
USERNAME=""
USER_PASS=""
SKIP_CONFIRM=false

# ── Helpers ──────────────────────────────────────────────────────────────────

cleanup() {
    set +e
    if [[ -n "$BOOT_MOUNT" ]] && ! $DRY_RUN; then
        diskutil unmount "$BOOT_MOUNT" 2>/dev/null
    fi
    set -e
}
trap cleanup EXIT

die() { echo "Error: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Flight Tracker SD Flasher (macOS)

Usage: sudo ./flash.sh [OPTIONS]

Options:
  --image PATH         Use a local image file instead of downloading
                       Supports: .img, .img.xz, .img.gz, .zip
  --dry-run            Run through prompts and disk detection without
                       flashing or modifying anything (no sudo required)
  --ssid SSID          WiFi network name
  --wifi-password PASS WiFi password
  --lat VALUE          Latitude in decimal degrees
  --lon VALUE          Longitude in decimal degrees
  --hostname NAME      Pi hostname (default: flight-tracker)
  --username NAME      Pi username (default: pi)
  --password PASS      Pi user password
  --desktop            Use Pi OS with Desktop instead of Lite (enables HDMI output)
  --device PATH        Target device (e.g. /dev/disk4)
  --yes, -y            Skip the erase confirmation prompt
  --help, -h           Show this help message

When all required values are provided via flags, the script runs fully
non-interactively. Missing values will be prompted for interactively.
EOF
    exit 0
}

prompt() {
    local var="$1" prompt_text="$2" default="${3:-}"
    if [[ -n "$default" ]]; then
        read -rp "$prompt_text [$default]: " value
        printf -v "$var" '%s' "${value:-$default}"
    else
        while true; do
            read -rp "$prompt_text: " value
            [[ -n "$value" ]] && break
            echo "  Value cannot be empty."
        done
        printf -v "$var" '%s' "$value"
    fi
}

prompt_secret() {
    local var="$1" prompt_text="$2"
    while true; do
        read -rsp "$prompt_text: " value
        echo
        [[ -n "$value" ]] && break
        echo "  Value cannot be empty."
    done
    printf -v "$var" '%s' "$value"
}

# Hash a password using SHA-512 crypt format.
# macOS LibreSSL may not support `openssl passwd -6`, so fall back to Python.
hash_password() {
    local pass="$1"
    local hash
    hash=$(openssl passwd -6 "$pass" 2>/dev/null) && { echo "$hash"; return; }
    hash=$(python3 -c "import crypt; print(crypt.crypt('$pass', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null) && { echo "$hash"; return; }
    die "Cannot hash password: neither 'openssl passwd -6' nor Python crypt module available"
}

# ── Parse args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            [[ -z "${2:-}" ]] && die "--image requires a path argument"
            IMAGE_ARG="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --desktop)
            USE_DESKTOP=true; shift ;;
        --ssid)
            [[ -z "${2:-}" ]] && die "--ssid requires a value"
            WIFI_SSID="$2"; shift 2 ;;
        --wifi-password)
            [[ -z "${2:-}" ]] && die "--wifi-password requires a value"
            WIFI_PASS="$2"; shift 2 ;;
        --lat)
            [[ -z "${2:-}" ]] && die "--lat requires a value"
            LATITUDE="$2"; shift 2 ;;
        --lon)
            [[ -z "${2:-}" ]] && die "--lon requires a value"
            LONGITUDE="$2"; shift 2 ;;
        --hostname)
            [[ -z "${2:-}" ]] && die "--hostname requires a value"
            PI_HOSTNAME="$2"; shift 2 ;;
        --username)
            [[ -z "${2:-}" ]] && die "--username requires a value"
            USERNAME="$2"; shift 2 ;;
        --password)
            [[ -z "${2:-}" ]] && die "--password requires a value"
            USER_PASS="$2"; shift 2 ;;
        --device)
            [[ -z "${2:-}" ]] && die "--device requires a value"
            TARGET_DEV="$2"; shift 2 ;;
        --yes|-y)
            SKIP_CONFIRM=true; shift ;;
        --help|-h)
            usage ;;
        *)
            die "Unknown option: $1" ;;
    esac
done

# ── Select OS variant ──────────────────────────────────────────────────────

if $USE_DESKTOP; then
    IMAGE_URL="$IMAGE_URL_DESKTOP"
fi

# ── Preflight checks ────────────────────────────────────────────────────────

if ! $DRY_RUN; then
    [[ $EUID -ne 0 ]] && die "This script must be run as root (sudo)."
fi
[[ "$(uname)" == "Darwin" ]] || die "This script is designed for macOS."

for cmd in dd diskutil openssl mktemp; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

if [[ -z "$IMAGE_ARG" ]]; then
    command -v curl &>/dev/null || command -v wget &>/dev/null || die "curl or wget is required for downloading"
fi

# ── User prompts ─────────────────────────────────────────────────────────────

echo "Flight Tracker SD Flasher"
echo "─────────────────────────"

[[ -z "$WIFI_SSID" ]]    && prompt       WIFI_SSID     "WiFi SSID"
[[ -z "$WIFI_PASS" ]]    && prompt_secret WIFI_PASS     "WiFi password"
[[ -z "$LATITUDE" ]]     && prompt       LATITUDE      "Latitude (decimal degrees)"
[[ -z "$LONGITUDE" ]]    && prompt       LONGITUDE     "Longitude (decimal degrees)"
[[ -z "$PI_HOSTNAME" ]]  && prompt       PI_HOSTNAME   "Hostname"       "flight-tracker"
[[ -z "$PI_HOSTNAME" ]]  && PI_HOSTNAME="flight-tracker"
[[ -z "$USERNAME" ]]     && prompt       USERNAME      "Username"        "pi"
[[ -z "$USERNAME" ]]     && USERNAME="pi"
[[ -z "$USER_PASS" ]]    && prompt_secret USER_PASS     "Password"

echo ""

# ── Validate coordinates ────────────────────────────────────────────────────

validate_coord() {
    local val="$1" name="$2" min="$3" max="$4"
    if ! [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        die "$name must be a decimal number (got: $val)"
    fi
    if (( $(echo "$val < $min" | bc -l) )) || (( $(echo "$val > $max" | bc -l) )); then
        die "$name must be between $min and $max (got: $val)"
    fi
}

validate_coord "$LATITUDE"  "Latitude"  -90  90
validate_coord "$LONGITUDE" "Longitude" -180 180

# ── Device selection ─────────────────────────────────────────────────────────

# Build list of candidate disks (physical disks that aren't the boot volume)
# Uses both external disks and non-boot internal disks (for built-in SD readers)
# Identify the boot disk and its physical store so we never offer them as targets
BOOT_DISK=$(diskutil info / 2>/dev/null | awk -F: '/Part of Whole/{gsub(/^[ \t]+/,"",$2); print "/dev/"$2}')
BOOT_PHYS=$(diskutil list 2>/dev/null | awk -v bd="${BOOT_DISK#/dev/}" '
    /^\/dev\/disk[0-9]+/ { cur=$1 }
    /Apple_APFS.*Container/ && index($0, "Container " bd) > 0 { print cur }
' | head -1)

build_disk_list() {
    DISK_LIST=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^(/dev/disk[0-9]+) ]]; then
            local dev="${BASH_REMATCH[1]}"
            [[ "$dev" == "$BOOT_DISK" ]] && continue
            [[ -n "$BOOT_PHYS" && "$dev" == "$BOOT_PHYS" ]] && continue
            # Skip synthesized/virtual disks
            local dtype
            dtype=$(diskutil info "$dev" 2>/dev/null | awk -F: '/Virtual/{gsub(/^[ \t]+/,"",$2); print $2}')
            [[ "$dtype" == "Yes" ]] && continue
            DISK_LIST+=("$dev")
        fi
    done < <(diskutil list 2>/dev/null)
}

if [[ -n "$TARGET_DEV" ]]; then
    # Validate that the provided device is not the boot disk
    if ! $DRY_RUN; then
        build_disk_list
        found=false
        for d in "${DISK_LIST[@]+"${DISK_LIST[@]}"}"; do
            [[ "$d" == "$TARGET_DEV" ]] && found=true && break
        done
        $found || die "$TARGET_DEV is not a valid target disk (must be a non-boot physical disk)"
    fi
else
    echo "Available disks:"

    if ! $DRY_RUN; then
        build_disk_list
    fi

    if [[ ${#DISK_LIST[@]} -eq 0 ]]; then
        die "No target disks found. Insert an SD card and try again."
    fi

    for dev in "${DISK_LIST[@]}"; do
        size=$(diskutil info "$dev" 2>/dev/null | awk -F: '/Disk Size/{gsub(/^[ \t]+/,"",$2); print $2}' | head -1)
        name=$(diskutil info "$dev" 2>/dev/null | awk -F: '/Media Name/{gsub(/^[ \t]+/,"",$2); print $2}' | head -1)
        printf "  %-14s %-24s %s\n" "$dev" "${size:-unknown}" "${name:-}"
    done

    echo ""
    DEFAULT_DEV="${DISK_LIST[0]}"
    prompt TARGET_DEV "Target device" "$DEFAULT_DEV"

    # Verify the selected device is in our list
    found=false
    for d in "${DISK_LIST[@]+"${DISK_LIST[@]}"}"; do
        [[ "$d" == "$TARGET_DEV" ]] && found=true && break
    done
    $found || die "$TARGET_DEV is not in the list of available disks"
fi

# Use raw device for faster dd
RAW_DEV="${TARGET_DEV/disk/rdisk}"

echo ""
if ! $SKIP_CONFIRM; then
    echo "WARNING: ALL DATA on $TARGET_DEV will be erased!"
    read -rp "Continue? [y/N]: " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Aborted."; exit 1; }
fi

echo ""

# ── Step 1: Get the image ───────────────────────────────────────────────────

if $USE_DESKTOP; then
    OS_VARIANT="Desktop"
else
    OS_VARIANT="Lite"
fi

echo "[1/3] Downloading Raspberry Pi OS $OS_VARIANT (Bookworm)..."

if [[ -n "$IMAGE_ARG" ]]; then
    [[ -f "$IMAGE_ARG" ]] || die "Image file not found: $IMAGE_ARG"
    IMAGE_FILE="$IMAGE_ARG"
    echo "  Using local image: $IMAGE_FILE"
else
    mkdir -p "$CACHE_DIR"
    IMAGE_FILE="$CACHE_DIR/$(basename "$IMAGE_URL")"
    if [[ -f "$IMAGE_FILE" ]]; then
        echo "  Using cached image: $IMAGE_FILE"
    else
        echo "  Downloading to $IMAGE_FILE ..."
        if command -v curl &>/dev/null; then
            curl -fL --progress-bar -o "$IMAGE_FILE.part" "$IMAGE_URL"
        else
            wget --show-progress -O "$IMAGE_FILE.part" "$IMAGE_URL"
        fi
        mv "$IMAGE_FILE.part" "$IMAGE_FILE"
    fi
fi

# Determine decompression command based on extension
case "$IMAGE_FILE" in
    *.img.xz)
        command -v xzcat &>/dev/null || die "xzcat is required for .xz images (brew install xz)"
        DECOMPRESS="xzcat"
        ;;
    *.img.gz)
        command -v gunzip &>/dev/null || die "gunzip is required for .gz images"
        DECOMPRESS="gunzip -c"
        ;;
    *.zip)
        command -v unzip &>/dev/null || die "unzip is required for .zip images"
        IMG_NAME=$(unzip -l "$IMAGE_FILE" | grep '\.img$' | awk '{print $NF}' | head -1)
        [[ -n "$IMG_NAME" ]] || die "No .img file found inside zip"
        DECOMPRESS="unzip -p"
        ;;
    *.img)
        DECOMPRESS="cat"
        ;;
    *)
        die "Unsupported image format: $IMAGE_FILE"
        ;;
esac

# ── Step 2: Flash ────────────────────────────────────────────────────────────

echo "[2/3] Flashing to $TARGET_DEV (raw: $RAW_DEV)..."

if $DRY_RUN; then
    echo "  [dry-run] Would run: diskutil unmountDisk $TARGET_DEV"
    echo "  [dry-run] Would run: $DECOMPRESS $IMAGE_FILE | dd of=$RAW_DEV bs=1m"
    echo "  [dry-run] Skipping flash."
    BOOT_MOUNT="/Volumes/bootfs (dry-run)"
    echo "  [dry-run] Boot partition would be mounted (skipping)"
else
    # Unmount all volumes on the target disk
    diskutil unmountDisk "$TARGET_DEV" 2>/dev/null || true

    $DECOMPRESS "$IMAGE_FILE" | dd of="$RAW_DEV" bs=1m 2>&1

    sync
    echo "  Flash complete."

    # Give macOS time to recognize the new partition table
    sleep 3

    # Mount the disk so we can access the boot partition
    diskutil mountDisk "$TARGET_DEV" 2>/dev/null || true
    sleep 2

    # ── Find the boot partition mount point ──────────────────────────────────
    PART1="${TARGET_DEV}s1"

    BOOT_MOUNT=$(diskutil info "$PART1" 2>/dev/null | awk -F: '/Mount Point/{gsub(/^[ \t]+/,"",$2); print $2}')

    if [[ -z "$BOOT_MOUNT" || "$BOOT_MOUNT" == "" ]]; then
        diskutil mount "$PART1" 2>/dev/null || true
        sleep 1
        BOOT_MOUNT=$(diskutil info "$PART1" 2>/dev/null | awk -F: '/Mount Point/{gsub(/^[ \t]+/,"",$2); print $2}')
    fi

    [[ -d "$BOOT_MOUNT" ]] || die "Could not find boot partition mount point for $PART1"
    echo "  Boot partition mounted at: $BOOT_MOUNT"
fi

# ── Step 3: Configure boot partition ─────────────────────────────────────────

echo "[3/3] Configuring boot partition..."

if $DRY_RUN; then
    PASS_HASH=$(hash_password "$USER_PASS")
    HOST_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo "UTC")
    echo "  [dry-run] Would write: $BOOT_MOUNT/ssh (enable SSH)"
    echo "  [dry-run] Would write: $BOOT_MOUNT/userconf.txt (${USERNAME}:<hash>)"
    echo "  [dry-run] Would modify: $BOOT_MOUNT/config.txt (disable onboard audio)"
    echo "  [dry-run] Would write: $BOOT_MOUNT/firstrun.sh (first-boot setup script)"
    echo "  [dry-run]   Hostname: $PI_HOSTNAME"
    echo "  [dry-run]   Timezone: $HOST_TZ"
    echo "  [dry-run]   WiFi SSID: $WIFI_SSID"
    echo "  [dry-run]   Latitude: $LATITUDE"
    echo "  [dry-run]   Longitude: $LONGITUDE"
    echo "  [dry-run]   OS variant: $OS_VARIANT"
    echo "  [dry-run] Would write: /opt/matrix_log.py (LED matrix status logger)"
    echo "  [dry-run]   Status messages at: Matrix OK, Installing deps, Config written, Setup done, Starting tracker"
    echo "  [dry-run] Would modify: $BOOT_MOUNT/cmdline.txt (add firstrun trigger)"
    echo ""
    echo "  [dry-run] Would run: diskutil unmount $BOOT_MOUNT"
    echo "  [dry-run] Would run: diskutil eject $TARGET_DEV"
    echo ""
    echo "Done! (dry run — no changes were made)"
    exit 0
fi

# Enable SSH
touch "$BOOT_MOUNT/ssh"

# Create userconf.txt with hashed password
PASS_HASH=$(hash_password "$USER_PASS")
echo "${USERNAME}:${PASS_HASH}" > "$BOOT_MOUNT/userconf.txt"

# Detect timezone from host
HOST_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo "UTC")

# Disable onboard audio in config.txt
if [[ -f "$BOOT_MOUNT/config.txt" ]]; then
    if grep -q '^dtparam=audio=on' "$BOOT_MOUNT/config.txt"; then
        sed -i '' 's/^dtparam=audio=on/dtparam=audio=off/' "$BOOT_MOUNT/config.txt"
    elif ! grep -q '^dtparam=audio=' "$BOOT_MOUNT/config.txt"; then
        echo "dtparam=audio=off" >> "$BOOT_MOUNT/config.txt"
    fi
fi

# Create firstrun.sh — variables section (expanded now)
cat > "$BOOT_MOUNT/firstrun.sh" <<'FIRSTRUN_OUTER'
#!/bin/bash
set -e

FIRSTRUN_OUTER

cat >> "$BOOT_MOUNT/firstrun.sh" <<FIRSTRUN_VARS
CONF_HOSTNAME="${PI_HOSTNAME}"
CONF_TIMEZONE="${HOST_TZ}"
CONF_LATITUDE="${LATITUDE}"
CONF_LONGITUDE="${LONGITUDE}"
CONF_WIFI_SSID="${WIFI_SSID}"
CONF_WIFI_PASS="${WIFI_PASS}"
FIRSTRUN_VARS

# Create firstrun.sh — body section (literal, no expansion)
cat >> "$BOOT_MOUNT/firstrun.sh" <<'FIRSTRUN_BODY'

# ── Set hostname ─────────────────────────────────────────────────────────────
echo "$CONF_HOSTNAME" > /etc/hostname
sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$CONF_HOSTNAME/" /etc/hosts

# ── Set timezone ─────────────────────────────────────────────────────────────
ln -sf "/usr/share/zoneinfo/$CONF_TIMEZONE" /etc/localtime
echo "$CONF_TIMEZONE" > /etc/timezone

# ── Set WiFi regulatory domain ────────────────────────────────────────────────
# The radio won't transmit without a country code set
if [ -f /etc/default/crda ]; then
    sed -i 's/^REGDOMAIN=.*/REGDOMAIN=US/' /etc/default/crda
else
    echo 'REGDOMAIN=US' > /etc/default/crda
fi
iw reg set US 2>/dev/null || true

# ── Unblock WiFi ─────────────────────────────────────────────────────────────
rfkill unblock wifi 2>/dev/null || true

# ── Configure WiFi via NetworkManager ────────────────────────────────────────
NM_DIR="/etc/NetworkManager/system-connections"
mkdir -p "$NM_DIR"

cat > "$NM_DIR/wifi.nmconnection" <<NMEOF
[connection]
id=${CONF_WIFI_SSID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${CONF_WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${CONF_WIFI_PASS}

[ipv4]
method=auto

[ipv6]
method=auto
NMEOF

chmod 600 "$NM_DIR/wifi.nmconnection"

# ── Restart NetworkManager to pick up the new connection ─────────────────────
systemctl restart NetworkManager 2>/dev/null || true
# Give NM a moment, then explicitly bring up the connection
sleep 2
nmcli connection up "${CONF_WIFI_SSID}" 2>/dev/null || true

# ── Create the second-stage setup script ─────────────────────────────────────
cat > /opt/flight-tracker-setup.sh <<'SETUP_EOF'
#!/bin/bash
set -e
exec > /var/log/flight-tracker-setup.log 2>&1
echo "=== Flight tracker setup started at $(date) ==="

# Wait for network (up to 60s)
for i in $(seq 1 60); do
    if ping -c1 -W2 google.com &>/dev/null; then
        echo "Network is up."
        break
    fi
    echo "Waiting for network... ($i/60)"
    sleep 1
done

# ── Install packages ─────────────────────────────────────────────────────────
apt-get update
apt-get install -y git python3-pip python3-venv python3-dev \
    libfreetype6-dev libjpeg-dev zlib1g-dev \
    build-essential cython3

# ── Clone flight-tracker-led ─────────────────────────────────────────────────
if [[ ! -d /opt/flight-tracker-led ]]; then
    git clone https://github.com/rl-enjoyer/flight-display.git /opt/flight-tracker-led
fi
cd /opt/flight-tracker-led

# ── Build rpi-rgb-led-matrix ─────────────────────────────────────────────────
RGB_MATRIX_DIR="/opt/rpi-rgb-led-matrix"
if [[ ! -d "$RGB_MATRIX_DIR" ]]; then
    git clone https://github.com/hzeller/rpi-rgb-led-matrix.git "$RGB_MATRIX_DIR"
fi
cd "$RGB_MATRIX_DIR"
make build-python PYTHON=$(command -v python3)
make install-python PYTHON=$(command -v python3)
cd /opt/flight-tracker-led

# ── Create matrix_log.py for boot status messages ────────────────────────
cat > /opt/matrix_log.py <<'MATLOG'
#!/usr/bin/env python3
"""Display a short status message on the LED matrix and exit."""
import sys
sys.path.append("/opt/rpi-rgb-led-matrix/bindings/python")
from rgbmatrix import RGBMatrix, RGBMatrixOptions
from PIL import Image, ImageDraw, ImageFont

msg = " ".join(sys.argv[1:]) or "OK"

options = RGBMatrixOptions()
options.rows = 32
options.cols = 64
options.chain_length = 1
options.hardware_mapping = "adafruit-hat"
options.gpio_slowdown = 2
options.brightness = 60
options.pwm_bits = 7
options.drop_privileges = False

matrix = RGBMatrix(options=options)
img = Image.new("RGB", (64, 32), (0, 0, 0))
draw = ImageDraw.Draw(img)

font_path = "/opt/rpi-rgb-led-matrix/fonts/5x8.bdf"
try:
    font = ImageFont.load(font_path)
except Exception:
    font = ImageFont.load_default()

# Word-wrap into lines of ~12 chars (64px / 5px per char)
words, lines, cur = msg.split(), [], ""
for w in words:
    test = f"{cur} {w}".strip() if cur else w
    if len(test) <= 12:
        cur = test
    else:
        if cur: lines.append(cur)
        cur = w
if cur: lines.append(cur)

for i, line in enumerate(lines[:4]):
    draw.text((1, i * 8), line, font=font, fill=(0, 180, 255))

matrix.SetImage(img)
MATLOG
chmod +x /opt/matrix_log.py

python3 /opt/matrix_log.py "Matrix OK"

python3 /opt/matrix_log.py "Installing deps..."
# ── Python dependencies ──────────────────────────────────────────────────────
pip3 install --break-system-packages -r requirements.txt 2>/dev/null || \
    pip3 install -r requirements.txt

SETUP_EOF

# Append the coordinate config (uses outer variables)
cat >> /opt/flight-tracker-setup.sh <<SETUP_COORDS
# ── Write config_local.py ─────────────────────────────────────────────────
cat > /opt/flight-tracker-led/config_local.py <<PYEOF
HOME_LAT = ${CONF_LATITUDE}
HOME_LON = ${CONF_LONGITUDE}
PYEOF
SETUP_COORDS

cat >> /opt/flight-tracker-setup.sh <<'SETUP_EOF2'

python3 /opt/matrix_log.py "Config written"

# ── Create flight-tracker systemd service ─────────────────────────────────
cat > /etc/systemd/system/flight-tracker.service <<SVCEOF
[Unit]
Description=Flight Tracker LED Display
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/flight-tracker-led
ExecStartPre=/usr/bin/python3 /opt/matrix_log.py "Starting tracker..."
ExecStart=/usr/bin/python3 main.py
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable flight-tracker.service

# ── Disable the setup service (one-shot, don't run again) ────────────────
systemctl disable flight-tracker-setup.service

echo "=== Flight tracker setup complete at $(date) ==="
python3 /opt/matrix_log.py "Setup done! Rebooting..."
echo "=== Rebooting... ==="
sleep 2
reboot
SETUP_EOF2

chmod +x /opt/flight-tracker-setup.sh

# ── Create one-shot systemd service for second-stage setup ───────────────────
cat > /etc/systemd/system/flight-tracker-setup.service <<'SETUPSVC'
[Unit]
Description=Flight Tracker First-Boot Setup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/flight-tracker-setup.sh

[Install]
WantedBy=multi-user.target
SETUPSVC

systemctl enable flight-tracker-setup.service

# ── Remove firstrun from cmdline.txt so it doesn't re-run ───────────────────
if [ -f /boot/firmware/cmdline.txt ]; then
    sed -i 's| systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target||' /boot/firmware/cmdline.txt
fi

FIRSTRUN_BODY

chmod +x "$BOOT_MOUNT/firstrun.sh"

# Append firstrun trigger to cmdline.txt
CMDLINE_FILE="$BOOT_MOUNT/cmdline.txt"
if [[ -f "$CMDLINE_FILE" ]]; then
    # Remove trailing newline, append on same line
    EXISTING=$(tr -d '\n' < "$CMDLINE_FILE")
    echo "${EXISTING} systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target" > "$CMDLINE_FILE"
else
    die "cmdline.txt not found on boot partition"
fi

# ── Cleanup ──────────────────────────────────────────────────────────────────

sync
diskutil unmount "$BOOT_MOUNT" 2>/dev/null || true
BOOT_MOUNT=""
diskutil eject "$TARGET_DEV" 2>/dev/null || true

echo ""
echo "Done! Insert the SD card into your Pi and power on."
echo "The flight tracker will start automatically after first boot."
echo "SSH: ssh ${USERNAME}@${PI_HOSTNAME}.local"
