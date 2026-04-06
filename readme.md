# BlackTorch Setup Scripts

Automated setup scripts for BlackTorch development and deploy.

## Quick Start

On a fresh device with Ubuntu:
```bash
# 1. Setup Git & GitHub SSH access
curl -fsSL https://raw.githubusercontent.com/BlackTorch-s-r-o/btsetup/main/install_git_deploy_repo.sh | bash

# 2. Clone the repo e.g.:
git clone git@github.com:BlackTorch-s-r-o/BTRemoteHTTPSpeaker.git

```

```bash
For developing for BlackTorch:

# 1. Create a wireguard public/private key
bash <(curl -fsSL https://raw.githubusercontent.com/BlackTorch-s-r-o/btsetup/main/wg_create_client.sh)

# 2. Append this to the file in /etc/wireguard/<wg_interface>.conf on the VPN server:
[Peer]
PublicKey = abc123def456...  # The output from above
AllowedIPs = <select-some-unused-ipv4>/32

# 3. Create a client config at you host computer in /etc/wireguard (you may need to use sudo du root mode):
[Interface]
PrivateKey = <content-of-private.key-from-client>
Address = <select-some-unused-ipv4>/32
DNS = 1.1.1.1  # Optional
PostUp = ip route add 10.7.0.0/24 dev %i # For Jetsons
PostDown = ip route del 10.7.0.0/24 dev %i # For Jetsons
Table = off # For Jetsons


[Peer]
PublicKey = <content-of-server-public.key-from-server>
Endpoint = your-vps-ip:51821 # Or by default 51820
AllowedIPs = 0.0.0.0/0, ::/0  # Route all traffic through VPN
PersistentKeepalive = 25

# 4. Run ping_service.sh to make the connection in wg interface reliable:
curl -fsSL https://raw.githubusercontent.com/BlackTorch-s-r-o/btsetup/main/ping_service.sh | sudo bash

# 5. Custom commands (devnet up/down/status)
curl -fsSL https://raw.githubusercontent.com/BlackTorch-s-r-o/btsetup/main/custom_commands.sh | sudo bash

# 6. Run setup_hosts.sh to create local DNS
curl -fsSL https://raw.githubusercontent.com/BlackTorch-s-r-o/btsetup/main/setup_hosts.sh | bash

```

## Scripts

- `install_git_deploy_repo.sh` - Git configuration and SSH key setup

- `wg_create_client.sh` - Manages Wireguard keys for the local machine

- `ping_service.sh` - Installs systemd service that pings VPN server every 30 seconds

- `custom_commands.sh` - Creates aliases for managing wireguard interface

- `setup_hosts.sh` - Creates DNS in /etc/hosts for dev infra

- `secure_ubuntu_server.sh` - Interactive Ubuntu 24.04 server hardening script

- `rpi5_nvme_install.sh` - Installs Ubuntu 24.04 onto an NVMe drive on a Raspberry Pi 5

## Server Hardening

Run on a fresh Ubuntu 24.04 server to interactively apply security hardening:

```bash
curl -fsSL https://raw.githubusercontent.com/BlackTorch-s-r-o/btsetup/main/secure_ubuntu_server.sh | sudo bash
```

Or clone and run locally:

```bash
sudo bash secure_ubuntu_server.sh
```

> **Warning:** Keep a second SSH session open and have console/VNC access ready before running.

The script walks through each step and asks for confirmation before applying any change:

| Step | What it does |
|------|-------------|
| 1. System Update | `apt upgrade` + autoremove |
| 2. Non-root sudo user | Creates a new user, optionally copies SSH keys from root |
| 3. SSH Hardening | Disables password auth and root login, sets `MaxAuthTries 3`, optional port change |
| 4. UFW Firewall | Deny all incoming, allow outgoing, allow SSH + optional HTTP/HTTPS/custom ports |
| 5. Fail2Ban | Installs and enables SSH jail (3 retries → 24 h ban) |
| 6. Automatic Updates | Enables `unattended-upgrades` for security patches |
| 7. Kernel Hardening | Writes hardened sysctl params (ASLR, SYN cookies, redirect protection, etc.) |
| 8. Secure Shared Memory | Mounts `/run/shm` with `noexec,nosuid,nodev` |
| 9. Audit Logging | Installs `auditd` with rules for auth files, SSH config, privileged commands |
| 10. Package Cleanup | Removes/disables unnecessary packages and services (telnet, avahi, cups, etc.) |

## RPi 5 – NVMe Boot Install

Flashes Ubuntu 24.04 LTS onto an NVMe drive and configures the RPi 5 to boot from it. Run this **from the SD card** while booted into Ubuntu.

**Prerequisites:**
- Raspberry Pi 5 with NVMe HAT connected
- Booted into Ubuntu 24.04 on SD card
- Internet connection (downloads ~1.2 GB image)

```bash
sudo bash rpi5_nvme_install.sh
```

> **Warning:** The script will **erase the NVMe drive completely.** You will be asked to confirm before any data is written.

The script walks through each step interactively:

| Step | What it does |
|------|-------------|
| 1. Dependencies | Installs `rpi-eeprom`, `wget`, `xz-utils`, `parted` |
| 2. EEPROM update | Checks and optionally updates bootloader firmware |
| 3. Detect NVMe | Auto-detects the NVMe drive, prompts for confirmation |
| 4. Partition layout | Plans 512 MB FAT32 boot + ext4 root (optional custom size) |
| 5. Ubuntu image | Downloads Ubuntu 24.04.4 LTS ARM64 and verifies SHA256 |
| 6. Flash | Writes image to NVMe with `dd` |
| 7. Expand root | Expands root partition to fill the NVMe |
| 8. Boot order | Sets EEPROM boot order to NVMe-first (`0xf16`) |
| 8b. First-boot config | Optionally sets static IP (netplan) and SSH password (cloud-init) |
| 9. Verify | Mounts NVMe and confirms Ubuntu is present |

**After the script completes:**
1. `sudo poweroff` and remove the SD card
2. Power on — RPi 5 boots Ubuntu 24.04 from NVMe
3. First boot takes 60–90 s (cloud-init runs)
4. Default login: `ubuntu` / `ubuntu` (or the password you set)
5. Verify boot device: `findmnt /` and `lsblk`

**If boot fails:** re-insert SD card and run `sudo rpi-eeprom-config --edit` to adjust `BOOT_ORDER`. Some NVMe HATs also need `dtparam=pciex1_gen=3` in `/boot/firmware/config.txt` for Gen 3 speeds.

---

**BlackTorch s.r.o.** - Surveillance systems