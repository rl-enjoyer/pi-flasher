#!/usr/bin/env bash
#
# flight-tracker-flasher — Flash an SD card with Raspberry Pi OS Lite
# pre-configured for the flight-tracker-led project.
#
# Usage: sudo ./flash.sh [--image /path/to/image] [--help]
#
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-2024-11-19/2024-11-19-raspios-bookworm-armhf-lite.img.xz"
CACHE_DIR="${HOME}/.cache/flight-tracker-flasher"
MOUNT_BOOT=""
MOUNT_ROOT=""
IMAGE_ARG=""

# ── Helpers ──────────────────────────────────────────────────────────────────

cleanup() {
    set +e
    [[ -n "$MOUNT_BOOT" && -d "$MOUNT_BOOT" ]] && umount "$MOUNT_BOOT" 2>/dev/null && rmdir "$MOUNT_BOOT" 2>/dev/null
    [[ -n "$MOUNT_ROOT" && -d "$MOUNT_ROOT" ]] && umount "$MOUNT_ROOT" 2>/dev/null && rmdir "$MOUNT_ROOT" 2>/dev/null
    set -e
}
trap cleanup EXIT

die() { echo "Error: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Flight Tracker SD Flasher

Usage: sudo ./flash.sh [OPTIONS]

Options:
  --image PATH    Use a local image file instead of downloading
                  Supports: .img, .img.xz, .img.gz, .zip
  --help          Show this help message

The tool will prompt for WiFi credentials, GPS coordinates, and target
SD card device interactively.
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

# ── Parse args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            [[ -z "${2:-}" ]] && die "--image requires a path argument"
            IMAGE_ARG="$2"; shift 2 ;;
        --help|-h)
            usage ;;
        *)
            die "Unknown option: $1" ;;
    esac
done

# ── Preflight checks ────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && die "This script must be run as root (sudo)."

for cmd in dd mount umount lsblk openssl mktemp; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

if [[ -z "$IMAGE_ARG" ]]; then
    command -v curl &>/dev/null || command -v wget &>/dev/null || die "curl or wget is required for downloading"
fi

# ── User prompts ─────────────────────────────────────────────────────────────

echo "Flight Tracker SD Flasher"
echo "─────────────────────────"

prompt       WIFI_SSID     "WiFi SSID"
prompt_secret WIFI_PASS    "WiFi password"
prompt       LATITUDE      "Latitude (decimal degrees)"
prompt       LONGITUDE     "Longitude (decimal degrees)"
prompt       HOSTNAME      "Hostname"       "flight-tracker"
prompt       USERNAME      "Username"        "pi"
prompt_secret USER_PASS    "Password"

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

echo "Available disks:"

# Get root device to exclude it
ROOT_DEV=$(lsblk -npo PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)
[[ -z "$ROOT_DEV" ]] && ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' 2>/dev/null || true)

DISK_LIST=()
while IFS= read -r line; do
    dev=$(echo "$line" | awk '{print $1}')
    # Skip the root device
    [[ "$dev" == "$ROOT_DEV" ]] && continue
    size=$(echo "$line" | awk '{print $2}')
    model=$(echo "$line" | awk '{$1=""; $2=""; $NF=""; print}' | xargs)
    DISK_LIST+=("$dev")
    printf "  %-12s %-8s %s\n" "$dev" "$size" "$model"
done < <(lsblk -dpno NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -E 'usb|mmc' || true)

if [[ ${#DISK_LIST[@]} -eq 0 ]]; then
    die "No removable disks found. Insert an SD card and try again."
fi

echo ""
DEFAULT_DEV="${DISK_LIST[0]}"
prompt TARGET_DEV "Target device" "$DEFAULT_DEV"

# Verify the selected device exists and is in our list
[[ -b "$TARGET_DEV" ]] || die "$TARGET_DEV is not a valid block device"

found=false
for d in "${DISK_LIST[@]}"; do
    [[ "$d" == "$TARGET_DEV" ]] && found=true && break
done
$found || die "$TARGET_DEV is not in the list of removable disks"

echo ""
echo "WARNING: ALL DATA on $TARGET_DEV will be erased!"
read -rp "Continue? [y/N]: " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 1; }

echo ""

# ── Step 1: Get the image ───────────────────────────────────────────────────

echo "[1/4] Downloading Raspberry Pi OS Lite (Bookworm)..."

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
        command -v xzcat &>/dev/null || die "xzcat is required for .xz images (install xz-utils)"
        DECOMPRESS="xzcat"
        ;;
    *.img.gz)
        command -v gunzip &>/dev/null || die "gunzip is required for .gz images"
        DECOMPRESS="gunzip -c"
        ;;
    *.zip)
        command -v unzip &>/dev/null || die "unzip is required for .zip images"
        # Extract the .img filename from the zip
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

echo "[2/4] Flashing to $TARGET_DEV..."

# Unmount any existing partitions on the target
for part in "${TARGET_DEV}"*; do
    mountpoint -q "$part" 2>/dev/null && umount "$part" 2>/dev/null || true
done

$DECOMPRESS "$IMAGE_FILE" | dd of="$TARGET_DEV" bs=4M oflag=sync status=progress 2>&1

sync
echo "  Flash complete."

# Re-read partition table
partprobe "$TARGET_DEV" 2>/dev/null || true
sleep 2

# ── Determine partition names ────────────────────────────────────────────────

# Handle both /dev/sdX1 and /dev/mmcblkXp1 naming schemes
if [[ "$TARGET_DEV" =~ [0-9]$ ]]; then
    PART1="${TARGET_DEV}p1"
    PART2="${TARGET_DEV}p2"
else
    PART1="${TARGET_DEV}1"
    PART2="${TARGET_DEV}2"
fi

[[ -b "$PART1" ]] || die "Boot partition $PART1 not found"
[[ -b "$PART2" ]] || die "Root partition $PART2 not found"

# ── Step 3: Configure boot partition ─────────────────────────────────────────

echo "[3/4] Configuring boot partition..."

MOUNT_BOOT=$(mktemp -d /tmp/ftf-boot.XXXXXX)
mount "$PART1" "$MOUNT_BOOT"

# Enable SSH
touch "$MOUNT_BOOT/ssh"

# Create userconf.txt with hashed password
PASS_HASH=$(openssl passwd -6 "$USER_PASS")
echo "${USERNAME}:${PASS_HASH}" > "$MOUNT_BOOT/userconf.txt"

# Detect timezone from host
HOST_TZ=$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")

# Disable onboard audio in config.txt
if [[ -f "$MOUNT_BOOT/config.txt" ]]; then
    if grep -q '^dtparam=audio=on' "$MOUNT_BOOT/config.txt"; then
        sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$MOUNT_BOOT/config.txt"
    elif ! grep -q '^dtparam=audio=' "$MOUNT_BOOT/config.txt"; then
        echo "dtparam=audio=off" >> "$MOUNT_BOOT/config.txt"
    fi
fi

# Create firstrun.sh
cat > "$MOUNT_BOOT/firstrun.sh" <<'FIRSTRUN_OUTER'
#!/bin/bash
set -e

# ── Set hostname ─────────────────────────────────────────────────────────────
FIRSTRUN_OUTER

cat >> "$MOUNT_BOOT/firstrun.sh" <<FIRSTRUN_VARS
CONF_HOSTNAME="${HOSTNAME}"
CONF_TIMEZONE="${HOST_TZ}"
CONF_LATITUDE="${LATITUDE}"
CONF_LONGITUDE="${LONGITUDE}"
FIRSTRUN_VARS

cat >> "$MOUNT_BOOT/firstrun.sh" <<'FIRSTRUN_BODY'

echo "$CONF_HOSTNAME" > /etc/hostname
sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$CONF_HOSTNAME/" /etc/hosts

# ── Set timezone ─────────────────────────────────────────────────────────────
ln -sf "/usr/share/zoneinfo/$CONF_TIMEZONE" /etc/localtime
echo "$CONF_TIMEZONE" > /etc/timezone

# ── Unblock WiFi ─────────────────────────────────────────────────────────────
rfkill unblock wifi 2>/dev/null || true

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
    build-essential

# ── Clone flight-tracker-led ─────────────────────────────────────────────────
if [[ ! -d /opt/flight-tracker-led ]]; then
    git clone https://github.com/nolanlawson/flight-tracker-led.git /opt/flight-tracker-led
fi
cd /opt/flight-tracker-led

# ── Build rpi-rgb-led-matrix ─────────────────────────────────────────────────
if [[ -d lib/rpi-rgb-led-matrix ]]; then
    cd lib/rpi-rgb-led-matrix
    make build-python PYTHON=$(command -v python3)
    cd ../..
fi

# ── Python dependencies ──────────────────────────────────────────────────────
pip3 install --break-system-packages -r requirements.txt 2>/dev/null || \
    pip3 install -r requirements.txt

SETUP_EOF

# Append the coordinate config (uses outer variables)
cat >> /opt/flight-tracker-setup.sh <<SETUP_COORDS
# ── Write config_local.py ─────────────────────────────────────────────────
cat > /opt/flight-tracker-led/config_local.py <<PYEOF
LATITUDE = ${CONF_LATITUDE}
LONGITUDE = ${CONF_LONGITUDE}
PYEOF
SETUP_COORDS

cat >> /opt/flight-tracker-setup.sh <<'SETUP_EOF2'

# ── Create flight-tracker systemd service ─────────────────────────────────
cat > /etc/systemd/system/flight-tracker.service <<SVCEOF
[Unit]
Description=Flight Tracker LED Display
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/flight-tracker-led
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
echo "=== Rebooting... ==="
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

chmod +x "$MOUNT_BOOT/firstrun.sh"

# Append firstrun trigger to cmdline.txt
CMDLINE_FILE="$MOUNT_BOOT/cmdline.txt"
if [[ -f "$CMDLINE_FILE" ]]; then
    # Remove trailing newline, append on same line
    EXISTING=$(tr -d '\n' < "$CMDLINE_FILE")
    echo "${EXISTING} systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target" > "$CMDLINE_FILE"
else
    die "cmdline.txt not found on boot partition"
fi

umount "$MOUNT_BOOT"
echo "  Boot partition configured."

# ── Step 4: Configure root filesystem ────────────────────────────────────────

echo "[4/4] Configuring root filesystem..."

MOUNT_ROOT=$(mktemp -d /tmp/ftf-root.XXXXXX)
mount "$PART2" "$MOUNT_ROOT"

# Create NetworkManager connection for WiFi
NM_DIR="$MOUNT_ROOT/etc/NetworkManager/system-connections"
mkdir -p "$NM_DIR"

cat > "$NM_DIR/wifi.nmconnection" <<NMEOF
[connection]
id=${WIFI_SSID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PASS}

[ipv4]
method=auto

[ipv6]
method=auto
NMEOF

chmod 600 "$NM_DIR/wifi.nmconnection"
chown root:root "$NM_DIR/wifi.nmconnection"

umount "$MOUNT_ROOT"
echo "  Root filesystem configured."

# ── Cleanup ──────────────────────────────────────────────────────────────────

sync

# Clear mount vars so trap doesn't try to unmount again
MOUNT_BOOT=""
MOUNT_ROOT=""

echo ""
echo "Done! Insert the SD card into your Pi and power on."
echo "The flight tracker will start automatically after first boot."
echo "SSH: ssh ${USERNAME}@${HOSTNAME}.local"
