#!/usr/bin/env bash
# =============================================================================
# RPi 5 – Ubuntu 24.04 NVMe Boot Installer
# Run this FROM the SD card (current Ubuntu 24.04 session).
# After completion, remove SD card and reboot into NVMe.
# =============================================================================

set -euo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
section() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  $*${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
}

ask() {
    local prompt="$1"
    while true; do
        echo -en "${BOLD}${YELLOW}[?]${RESET} ${prompt} ${BOLD}[y/N]${RESET} "
        read -r answer
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no|"") return 1 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

pause() {
    echo -en "${BOLD}${YELLOW}[>]${RESET} Press ENTER to continue…"
    read -r
}

# ── root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run this script as root: sudo ./rpi5-nvme-install.sh"

# ── RPi 5 check ───────────────────────────────────────────────────────────────
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown")
if ! echo "$MODEL" | grep -qi "Raspberry Pi 5"; then
    warn "This script is designed for Raspberry Pi 5."
    warn "Detected: ${MODEL}"
    ask "Continue anyway?" || exit 1
fi

# =============================================================================
clear
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   RPi 5 · Ubuntu 24.04 · NVMe Boot Installer   ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  Running on: ${BOLD}${MODEL}${RESET}"
echo
warn "This script will ERASE the NVMe drive completely."
warn "Make sure you have no important data on it."
echo
pause

# =============================================================================
# 1 · DEPENDENCIES
# =============================================================================
section "1 · Installing Dependencies"

DEPS=(rpi-eeprom wget xz-utils parted udev)
MISSING=()
for dep in "${DEPS[@]}"; do
    dpkg -l "$dep" &>/dev/null 2>&1 || MISSING+=("$dep")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    info "Installing: ${MISSING[*]}"
    apt-get update -qq
    apt-get install -y "${MISSING[@]}" -qq
    ok "Dependencies installed."
else
    ok "All dependencies already present."
fi

# =============================================================================
# 2 · EEPROM BOOTLOADER CHECK & UPDATE
# =============================================================================
section "2 · EEPROM Bootloader"
echo "  The RPi 5 needs a recent EEPROM firmware to boot from NVMe."
echo

CURRENT_EEPROM=$(rpi-eeprom-update 2>/dev/null | grep "CURRENT:" | awk '{print $2}' || echo "unknown")
LATEST_EEPROM=$(rpi-eeprom-update 2>/dev/null | grep "LATEST:"  | awk '{print $2}' || echo "unknown")

info "Current EEPROM: ${CURRENT_EEPROM}"
info "Latest EEPROM:  ${LATEST_EEPROM}"
echo

if [[ "$CURRENT_EEPROM" == "$LATEST_EEPROM" ]]; then
    ok "EEPROM is already up to date."
else
    warn "An EEPROM update is available."
    if ask "Update EEPROM firmware now? (recommended – requires reboot after)"; then
        # Use the stable release channel
        if [[ -f /etc/default/rpi-eeprom-update ]]; then
            sed -i 's/FIRMWARE_RELEASE_STATUS=.*/FIRMWARE_RELEASE_STATUS=stable/' \
                /etc/default/rpi-eeprom-update
        fi
        rpi-eeprom-update -a
        ok "EEPROM update staged."
        warn "A reboot is needed to apply the EEPROM update."
        warn "After reboot, re-run this script to continue NVMe setup."
        if ask "Reboot now to apply EEPROM update?"; then
            reboot
        else
            warn "Continuing without EEPROM update – NVMe boot may not work on older firmware."
        fi
    else
        warn "Skipping EEPROM update – NVMe boot may not work on older firmware."
    fi
fi

# =============================================================================
# 3 · DETECT NVME DRIVE
# =============================================================================
section "3 · Detect NVMe Drive"

# Refresh udev so new devices are visible
udevadm settle

NVME_DEVICES=()
while IFS= read -r dev; do
    NVME_DEVICES+=("$dev")
done < <(lsblk -d -o NAME,TYPE | awk '$2=="disk" && $1~/^nvme/ {print "/dev/"$1}')

if [[ ${#NVME_DEVICES[@]} -eq 0 ]]; then
    err "No NVMe drive detected. Check that the HAT is seated properly and the drive is connected."
fi

if [[ ${#NVME_DEVICES[@]} -eq 1 ]]; then
    NVME_DEV="${NVME_DEVICES[0]}"
    NVME_SIZE=$(lsblk -d -o SIZE "$NVME_DEV" | tail -1 | tr -d ' ')
    info "Found NVMe drive: ${BOLD}${NVME_DEV}${RESET} (${NVME_SIZE})"
    ask "Use ${NVME_DEV} (${NVME_SIZE}) as the target?" || err "Aborted by user."
else
    echo "  Multiple NVMe drives detected:"
    for i in "${!NVME_DEVICES[@]}"; do
        SIZE=$(lsblk -d -o SIZE "${NVME_DEVICES[$i]}" | tail -1 | tr -d ' ')
        echo "    $((i+1))) ${NVME_DEVICES[$i]}  (${SIZE})"
    done
    while true; do
        echo -en "${BOLD}[?]${RESET} Select drive number: "
        read -r SEL
        if [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#NVME_DEVICES[@]} )); then
            NVME_DEV="${NVME_DEVICES[$((SEL-1))]}"
            break
        fi
        echo "  Invalid selection."
    done
fi

NVME_SIZE_BYTES=$(lsblk -d -b -o SIZE "$NVME_DEV" | tail -1 | tr -d ' ')
NVME_SIZE_GB=$(( NVME_SIZE_BYTES / 1024 / 1024 / 1024 ))
ok "Target: ${NVME_DEV} (${NVME_SIZE_GB} GB)"

# Safety: make sure we're not targeting the SD card (mmcblk)
if echo "$NVME_DEV" | grep -q "mmcblk"; then
    err "Target looks like an SD/eMMC device, not NVMe. Refusing to continue."
fi

# Check nothing is mounted from the NVMe
if mount | grep -q "^${NVME_DEV}"; then
    warn "Partitions from ${NVME_DEV} are currently mounted:"
    mount | grep "^${NVME_DEV}" | awk '{print "  "$1" → "$3}'
    if ask "Unmount them now?"; then
        mount | grep "^${NVME_DEV}" | awk '{print $3}' | xargs -r umount -l
        ok "Unmounted."
    else
        err "Cannot write to a mounted drive. Aborting."
    fi
fi

# =============================================================================
# 4 · PARTITION LAYOUT
# =============================================================================
section "4 · Partition Layout"
echo "  The installer will create:"
echo "    • /dev/$(basename ${NVME_DEV})p1  – 512 MB  FAT32  (boot / firmware)"
echo "    • /dev/$(basename ${NVME_DEV})p2  – remainder  ext4  (root / Ubuntu)"
echo

# Optional: custom root size
ROOT_SIZE="max"
if ask "Use a custom root partition size instead of the full remaining disk?"; then
    while true; do
        echo -en "${BOLD}[?]${RESET} Root partition size in GB (max ${NVME_SIZE_GB}): "
        read -r ROOT_GB
        if [[ "$ROOT_GB" =~ ^[0-9]+$ ]] && (( ROOT_GB >= 4 && ROOT_GB < NVME_SIZE_GB )); then
            ROOT_SIZE="${ROOT_GB}GB"
            break
        fi
        echo "  Enter a number between 4 and $((NVME_SIZE_GB - 1))."
    done
fi

# =============================================================================
# 5 · UBUNTU IMAGE
# =============================================================================
section "5 · Ubuntu 24.04 Image"

IMAGE_FILENAME="ubuntu-24.04.4-preinstalled-server-arm64+raspi.img.xz"
IMAGE_CACHE_DIR="/var/cache/rpi-nvme-install"
IMAGE_PATH="${IMAGE_CACHE_DIR}/${IMAGE_FILENAME}"
IMAGE_EXTRACTED="${IMAGE_CACHE_DIR}/ubuntu-24.04.4-preinstalled-server-arm64+raspi.img"
SHA256_EXPECTED="790652faeb4f61ce7bb12f5cb61734595c61d3cd882915b8b5f9918106c80d37"

# Mirrors tried in order (EU first, canonical fallback)
IMAGE_URLS=(
    "https://ftp.cvut.cz/ubuntu-releases/noble/${IMAGE_FILENAME}"
    "https://mirrors.nic.cz/ubuntu-releases/noble/${IMAGE_FILENAME}"
    "https://cdimage.ubuntu.com/releases/noble/release/${IMAGE_FILENAME}"
)

mkdir -p "$IMAGE_CACHE_DIR"

echo "  Source: Ubuntu 24.04.4 LTS – preinstalled server – ARM64 (Raspberry Pi)"
echo

# ── Decide whether to download ────────────────────────────────────────────────
SKIP_DOWNLOAD=false
ALREADY_DOWNLOADED=false

if [[ -f "$IMAGE_EXTRACTED" ]]; then
    IMG_SIZE=$(du -h "$IMAGE_EXTRACTED" | cut -f1)
    info "Found existing extracted image: ${IMAGE_EXTRACTED} (${IMG_SIZE})"
    if ask "Use existing image? (No = re-download)"; then
        SKIP_DOWNLOAD=true
    else
        rm -f "$IMAGE_EXTRACTED" "$IMAGE_PATH"
    fi
elif [[ -f "$IMAGE_PATH" ]]; then
    info "Found existing compressed image: ${IMAGE_PATH}"
    if ask "Use and extract existing download? (No = re-download)"; then
        ALREADY_DOWNLOADED=true
    else
        rm -f "$IMAGE_PATH"
    fi
fi

# ── Download ──────────────────────────────────────────────────────────────────
if [[ "$SKIP_DOWNLOAD" == false && "$ALREADY_DOWNLOADED" == false ]]; then
    DOWNLOAD_OK=false
    for URL in "${IMAGE_URLS[@]}"; do
        info "Trying: ${URL}"
        if wget -4 --show-progress --timeout=30 --tries=2 -O "$IMAGE_PATH" "$URL"; then
            ok "Download complete."
            DOWNLOAD_OK=true
            break
        else
            warn "Failed. Trying next mirror…"
            rm -f "$IMAGE_PATH"
        fi
    done
    [[ "$DOWNLOAD_OK" == true ]] || err "All mirrors failed. Check internet connection and try again."
fi

# ── Verify checksum ───────────────────────────────────────────────────────────
if [[ "$SKIP_DOWNLOAD" == false ]]; then
    info "Verifying SHA256 checksum…"
    ACTUAL=$(sha256sum "$IMAGE_PATH" | awk '{print $1}')
    if [[ "$ACTUAL" == "$SHA256_EXPECTED" ]]; then
        ok "Checksum verified."
    else
        err "Checksum mismatch! Image may be corrupt. Delete ${IMAGE_PATH} and retry."
    fi

    # ── Extract ───────────────────────────────────────────────────────────────
    info "Extracting image (this takes a few minutes)…"
    xz --decompress --threads=0 "$IMAGE_PATH"   # consumes .xz, writes .img in place
    mv "${IMAGE_PATH%.xz}" "$IMAGE_EXTRACTED" 2>/dev/null || true
    ok "Image extracted: ${IMAGE_EXTRACTED}"
fi

# ── Size check ────────────────────────────────────────────────────────────────
IMG_SIZE_BYTES=$(stat -c%s "$IMAGE_EXTRACTED")
IMG_SIZE_GB=$(echo "scale=1; ${IMG_SIZE_BYTES}/1024/1024/1024" | bc)
info "Image size: ${IMG_SIZE_GB} GB"

if (( IMG_SIZE_BYTES > NVME_SIZE_BYTES )); then
    err "Image (${IMG_SIZE_GB} GB) is larger than NVMe (${NVME_SIZE_GB} GB). Cannot continue."
fi
# =============================================================================
# 6 · FLASH IMAGE TO NVME
# =============================================================================
section "6 · Flash Image to NVMe"
echo -e "  ${BOLD}${RED}WARNING: This will ERASE all data on ${NVME_DEV}!${RESET}"
echo
echo "  Source : ${IMAGE_EXTRACTED}"
echo "  Target : ${NVME_DEV}"
echo "  NVMe   : ${NVME_SIZE_GB} GB"
echo

warn "Last chance to abort before data is written."
ask "Confirm: erase ${NVME_DEV} and flash Ubuntu 24.04?" || err "Aborted by user."

info "Flashing image to ${NVME_DEV}…"
info "(This will take several minutes – do not interrupt)"

# Use dd with progress via status=progress
dd if="$IMAGE_EXTRACTED" of="$NVME_DEV" bs=4M status=progress conv=fsync oflag=direct
sync

ok "Image flashed successfully."

# Inform kernel of new partition table
partprobe "$NVME_DEV" 2>/dev/null || true
udevadm settle
sleep 2

# =============================================================================
# 7 · EXPAND ROOT PARTITION TO FILL NVME
# =============================================================================
section "7 · Expand Root Partition"
echo "  The flashed image is ~3–4 GB. Expanding root to fill the NVMe…"
echo

# Partition names: nvme0n1p1, nvme0n1p2 etc.
PART_BOOT="${NVME_DEV}p1"
PART_ROOT="${NVME_DEV}p2"

if ask "Expand root partition to fill the NVMe now?"; then
    # Get the start sector of partition 2
    ROOT_START=$(parted -s "$NVME_DEV" unit s print | awk '/^ 2/{print $2}' | tr -d 's')

    if [[ "$ROOT_SIZE" == "max" ]]; then
        END_SECTOR="100%"
    else
        # Convert GB to sectors (512 byte sectors)
        END_BYTES=$(( ${ROOT_SIZE%GB} * 1024 * 1024 * 1024 ))
        END_SECTOR=$(( ROOT_START + END_BYTES / 512 - 1 ))
    fi

    parted -s "$NVME_DEV" resizepart 2 "$END_SECTOR"
    partprobe "$NVME_DEV"
    udevadm settle
    sleep 2

    info "Resizing ext4 filesystem on ${PART_ROOT}…"
    e2fsck -f -y "$PART_ROOT" || true
    resize2fs "$PART_ROOT"
    ok "Root partition expanded."
    lsblk "$NVME_DEV"
else
    warn "Root partition not expanded. Ubuntu will use only ~3–4 GB."
    warn "You can expand later with: sudo raspi-config → Advanced → Expand Filesystem"
fi

# =============================================================================
# 8 · CONFIGURE NVME BOOT ORDER IN EEPROM
# =============================================================================
section "8 · Set EEPROM Boot Order to NVMe"
echo "  The RPi 5 EEPROM boot order controls which device is tried first."
echo "  Current EEPROM config:"
echo

rpi-eeprom-config | grep BOOT_ORDER || true
echo

echo "  Boot order codes (hex, right-to-left priority):"
echo "    0x1 = SD card"
echo "    0x4 = USB mass storage"
echo "    0x6 = NVMe"
echo "    0xf = Restart loop"
echo
echo "  Recommended: 0xf16  =  NVMe first → USB → restart"
echo "               0xf16  =  try NVMe, fallback USB, restart if all fail"
echo "               0xf61  =  SD first → USB → NVMe (safe fallback)"
echo

if ask "Set boot order to NVMe-first (0xf16)?"; then
    BOOT_ORDER="0xf16"

    # Write updated EEPROM config
    TMPCONF=$(mktemp)
    rpi-eeprom-config > "$TMPCONF"

    if grep -q "BOOT_ORDER" "$TMPCONF"; then
        sed -i "s/^BOOT_ORDER=.*/BOOT_ORDER=${BOOT_ORDER}/" "$TMPCONF"
    else
        echo "BOOT_ORDER=${BOOT_ORDER}" >> "$TMPCONF"
    fi

    rpi-eeprom-config --apply "$TMPCONF"
    rm -f "$TMPCONF"
    ok "EEPROM boot order set to ${BOOT_ORDER} (NVMe first)."
    warn "This takes effect on next boot."
else
    warn "Boot order not changed. The RPi may still boot from SD card."
    warn "You can change it later with: sudo rpi-eeprom-config --edit"
fi


# =============================================================================
# 8b · NVMe First-Boot Configuration (static IP + SSH password auth)
# =============================================================================
section "8b · First-Boot Configuration"
echo "  Mounts the NVMe root partition to configure:"
echo "    • Static IP via netplan"
echo "    • SSH password authentication via cloud-init"
echo

# Decide what to configure
DO_STATIC_IP=false
DO_SSH_PASSWORD=false

if ask "Configure a static IP on the NVMe?"; then
    DO_STATIC_IP=true
fi

if ask "Enable SSH password authentication on first boot?"; then
    DO_SSH_PASSWORD=true
    warn "Password auth is convenient but less secure."
    warn "Remember to run harden.sh after first login to lock it back down."
fi

if $DO_STATIC_IP || $DO_SSH_PASSWORD; then

    # ── Mount NVMe root ───────────────────────────────────────────────────────
    NVME_MOUNT=$(mktemp -d)
    mount "${NVME_DEV}p2" "$NVME_MOUNT" \
        || err "Could not mount NVMe root partition."

    # Also mount boot partition (needed for cloud-init user-data)
    NVME_BOOT="${NVME_MOUNT}/boot/firmware"
    mkdir -p "$NVME_BOOT"
    mount "${NVME_DEV}p1" "$NVME_BOOT" 2>/dev/null || true

    # ── Static IP ─────────────────────────────────────────────────────────────
    if $DO_STATIC_IP; then
        echo
        info "Network interfaces detected on this system:"
        while IFS= read -r iface; do
            [[ "$iface" == "lo" ]] && continue
            STATE=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
            MAC=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "??:??:??:??:??:??")
            printf "    %-12s  state: %-8s  mac: %s\n" "$iface" "$STATE" "$MAC"
        done < <(ls /sys/class/net/)
        echo
        warn "On RPi 5 with Ubuntu 24.04 the ethernet port is usually 'end0'."
        echo

        while true; do
            echo -en "${BOLD}[?]${RESET} Interface name (e.g. end0, eth0): "
            read -r NET_IFACE
            [[ -n "$NET_IFACE" ]] && break
            echo "  Cannot be empty."
        done

        while true; do
            echo -en "${BOLD}[?]${RESET} Static IP address (e.g. 192.168.1.100): "
            read -r NET_IP
            [[ "$NET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
            echo "  Invalid IP format."
        done

        while true; do
            echo -en "${BOLD}[?]${RESET} Prefix length [24]: "
            read -r NET_PREFIX
            NET_PREFIX="${NET_PREFIX:-24}"
            [[ "$NET_PREFIX" =~ ^[0-9]+$ ]] && (( NET_PREFIX >= 1 && NET_PREFIX <= 32 )) && break
            echo "  Enter a number between 1 and 32."
        done

        SUGGESTED_GW=$(echo "$NET_IP" | awk -F. '{print $1"."$2"."$3".1"}')
        while true; do
            echo -en "${BOLD}[?]${RESET} Default gateway [${SUGGESTED_GW}]: "
            read -r NET_GW
            NET_GW="${NET_GW:-$SUGGESTED_GW}"
            [[ "$NET_GW" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
            echo "  Invalid gateway format."
        done

        NET_DNS="$NET_GW"

        echo
        echo -e "  ${BOLD}Netplan summary:${RESET}"
        echo "    Interface : ${NET_IFACE}"
        echo "    IP        : ${NET_IP}/${NET_PREFIX}"
        echo "    Gateway   : ${NET_GW}"
        echo "    DNS       : ${NET_DNS} (gateway)"
        echo

        NETPLAN_DIR="${NVME_MOUNT}/etc/netplan"
        mkdir -p "$NETPLAN_DIR"

        # Disable existing DHCP configs
        for f in "${NETPLAN_DIR}"/*.yaml; do
            [[ -f "$f" ]] && mv "$f" "${f}.disabled" && \
                info "Disabled existing netplan: $(basename $f)"
        done

        cat > "${NETPLAN_DIR}/01-static.yaml" << EOF
network:
  version: 2
  ethernets:
    ${NET_IFACE}:
      dhcp4: false
      addresses:
        - ${NET_IP}/${NET_PREFIX}
      routes:
        - to: default
          via: ${NET_GW}
      nameservers:
        addresses:
          - ${NET_DNS}
EOF
        chmod 600 "${NETPLAN_DIR}/01-static.yaml"
        ok "Static IP config written: /etc/netplan/01-static.yaml"
    fi

    # ── SSH password auth via cloud-init ──────────────────────────────────────
    if $DO_SSH_PASSWORD; then
        echo
        # Set a password for the ubuntu user
        while true; do
            echo -en "${BOLD}[?]${RESET} Password for the 'ubuntu' user on first boot: "
            read -rs SSH_PASS
            echo
            echo -en "${BOLD}[?]${RESET} Confirm password: "
            read -rs SSH_PASS2
            echo
            [[ "$SSH_PASS" == "$SSH_PASS2" && -n "$SSH_PASS" ]] && break
            echo "  Passwords do not match or are empty. Try again."
        done

        # Hash the password for cloud-init (SHA-512)
        if command -v openssl &>/dev/null; then
            HASHED_PASS=$(openssl passwd -6 "$SSH_PASS")
        elif command -v python3 &>/dev/null; then
            HASHED_PASS=$(python3 -c "import crypt,getpass; print(crypt.crypt('${SSH_PASS}', crypt.mksalt(crypt.METHOD_SHA512)))")
        else
            err "Cannot hash password: neither openssl nor python3 found."
        fi

        # Write cloud-init user-data to the boot partition
        USERDATA="${NVME_BOOT}/user-data"

        # Backup existing user-data
        [[ -f "$USERDATA" ]] && cp "$USERDATA" "${USERDATA}.bak" && \
            info "Backed up existing user-data to user-data.bak"

        cat > "$USERDATA" << EOF
#cloud-config

# Enable SSH password authentication
ssh_pwauth: true

# Set password for default ubuntu user
users:
  - name: ubuntu
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: ${HASHED_PASS}

# Allow password login (overrides Ubuntu's default deny)
chpasswd:
  expire: false
EOF
        ok "cloud-init user-data written: SSH password auth enabled."
        info "Login on first boot: ubuntu / <your password>"
    fi

    # ── Unmount ───────────────────────────────────────────────────────────────
    umount "$NVME_BOOT" 2>/dev/null || true
    umount "$NVME_MOUNT" 2>/dev/null || true
    rmdir "$NVME_MOUNT"

else
    skip "First-boot configuration"
fi

# =============================================================================
# 9 · VERIFY
# =============================================================================
section "9 · Verification"

echo "  Partition layout on ${NVME_DEV}:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$NVME_DEV"
echo

# Mount and spot-check the NVMe root
MOUNT_POINT=$(mktemp -d)
MOUNT_BOOT="${MOUNT_POINT}/boot/firmware"

info "Mounting NVMe root for verification…"
mount "$PART_ROOT" "$MOUNT_POINT"
mount "$PART_BOOT" "$MOUNT_BOOT" 2>/dev/null || \
    mount "${NVME_DEV}p1" "${MOUNT_POINT}/boot" 2>/dev/null || true

echo
echo "  NVMe root contents (spot check):"
ls "$MOUNT_POINT" | tr '\n' '  '
echo

if [[ -f "${MOUNT_POINT}/etc/os-release" ]]; then
    echo
    info "OS on NVMe:"
    grep PRETTY_NAME "${MOUNT_POINT}/etc/os-release" | sed 's/PRETTY_NAME=/  /'
    ok "Ubuntu installation verified on NVMe."
else
    warn "Could not find /etc/os-release on NVMe. Flash may have failed."
fi

# Check cmdline.txt on boot partition
if [[ -f "${MOUNT_BOOT}/cmdline.txt" ]]; then
    info "Boot cmdline.txt: $(cat ${MOUNT_BOOT}/cmdline.txt)"
fi

umount -R "$MOUNT_POINT" 2>/dev/null || true
rmdir "$MOUNT_POINT"

# =============================================================================
# SUMMARY
# =============================================================================
echo
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║              Installation Complete!             ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${BOLD}What to do next:${RESET}"
echo
echo "  1. Power off the RPi 5:"
echo "       sudo poweroff"
echo
echo "  2. Remove the SD card"
echo
echo "  3. Power on – the RPi 5 will boot Ubuntu 24.04 from NVMe"
echo
echo "  4. First boot may take 60–90 seconds (cloud-init runs)"
echo
echo "  5. Default login: ubuntu / ubuntu  (you'll be prompted to change it)"
echo
echo "  6. After first login, verify you're on NVMe:"
echo "       lsblk | grep -E 'nvme|NAME'"
echo "       findmnt / "
echo
echo -e "${BOLD}Optional – if boot fails:${RESET}"
echo "  • Re-insert SD card, boot into it, and run:"
echo "      sudo rpi-eeprom-config --edit"
echo "    Set BOOT_ORDER=0xf61 (NVMe after SD) to debug"
echo "  • Check NVMe HAT PCIe speed: some HATs need the SD to set pciex1_gen=3 in config.txt"
echo "    (RPi 5 defaults to Gen 2; set in /boot/firmware/config.txt on NVMe)"
echo
echo -e "  ${CYAN}PCIe Gen 3 (optional, faster):${RESET}"
echo "  Mount NVMe boot partition and add to config.txt:"
echo "    dtparam=pciex1_gen=3"
echo

if ask "Power off now to remove SD card and boot from NVMe?"; then
    info "Powering off in 3 seconds…"
    sleep 3
    poweroff
fi