#!/usr/bin/env bash
# =============================================================================
# Ubuntu 24.04 Server Hardening Script
# Interactive – each step asks for confirmation before running.
# Run as root or with sudo.
# =============================================================================

set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}[ERROR]${RESET} $*"; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${CYAN}  $*${RESET}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }
skip()    { echo -e "${YELLOW}[SKIP]${RESET}  Skipping: $*\n"; }

# Ask yes/no – returns 0 for yes, 1 for no
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

# ── root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (or via sudo)."
    exit 1
fi

# =============================================================================
# WELCOME
# =============================================================================
clear
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║   Ubuntu 24.04 LTS – Interactive Hardening   ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${RESET}"
warn "Keep a second SSH session open until you verify all changes work."
warn "Have console/VNC access ready as a fallback."
echo

# =============================================================================
# 1 · SYSTEM UPDATE
# =============================================================================
section "1 · System Update"
echo "  Runs: apt update && apt upgrade && autoremove"
echo

if ask "Update and upgrade all packages now?"; then
    info "Updating package lists…"
    apt-get update -qq

    info "Upgrading installed packages…"
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

    info "Removing unused packages…"
    apt-get autoremove -y

    ok "System is up to date."
else
    skip "System update"
fi

# =============================================================================
# 2 · CREATE NON-ROOT SUDO USER
# =============================================================================
section "2 · Create Non-Root Sudo User"
echo "  Creates a new user and adds it to the sudo group."
echo "  Recommended to do BEFORE locking down SSH."
echo

if ask "Create a new non-root sudo user?"; then
    while true; do
        echo -en "${BOLD}[?]${RESET} Enter new username: "
        read -r NEW_USER
        [[ -n "$NEW_USER" ]] && break
        echo "  Username cannot be empty."
    done

    if id "$NEW_USER" &>/dev/null; then
        warn "User '${NEW_USER}' already exists. Ensuring sudo membership…"
        usermod -aG sudo "$NEW_USER"
    else
        adduser --gecos "" "$NEW_USER"
        usermod -aG sudo "$NEW_USER"
        ok "User '${NEW_USER}' created and added to sudo group."
    fi

    if ask "Copy root's authorized_keys to ${NEW_USER} (for key-based SSH)?"; then
        ROOT_KEYS="/root/.ssh/authorized_keys"
        USER_SSH="/home/${NEW_USER}/.ssh"
        if [[ -f "$ROOT_KEYS" ]]; then
            mkdir -p "$USER_SSH"
            cp "$ROOT_KEYS" "${USER_SSH}/authorized_keys"
            chown -R "${NEW_USER}:${NEW_USER}" "$USER_SSH"
            chmod 700 "$USER_SSH"
            chmod 600 "${USER_SSH}/authorized_keys"
            ok "authorized_keys copied to ${NEW_USER}."
        else
            warn "No /root/.ssh/authorized_keys found – skipping key copy."
            warn "Make sure you add an SSH key for '${NEW_USER}' before disabling password auth!"
        fi
    fi
else
    skip "User creation"
fi

# =============================================================================
# 3 · SSH HARDENING – DISABLE PASSWORD AUTH
# =============================================================================
section "3 · SSH Hardening – Disable Password Authentication"
echo "  Sets: PermitRootLogin no"
echo "        PasswordAuthentication no"
echo "        MaxAuthTries 3"
echo "        X11Forwarding no"
echo "        ClientAliveInterval 300 / CountMax 2"
echo

warn "Ensure your SSH key is in authorized_keys BEFORE proceeding."
warn "Otherwise you will lock yourself out!"
echo

if ask "Apply SSH hardening?"; then
    SSHD_CFG="/etc/ssh/sshd_config"
    cp "${SSHD_CFG}" "${SSHD_CFG}.bak.$(date +%Y%m%d%H%M%S)"
    info "Backup saved: ${SSHD_CFG}.bak.*"

    # Helper: set or replace a directive
    set_sshd() {
        local key="$1" val="$2"
        if grep -qE "^#?[[:space:]]*${key}" "$SSHD_CFG"; then
            sed -i "s|^#\?[[:space:]]*${key}.*|${key} ${val}|" "$SSHD_CFG"
        else
            echo "${key} ${val}" >> "$SSHD_CFG"
        fi
    }

    set_sshd PermitRootLogin        no
    set_sshd PasswordAuthentication no
    set_sshd PermitEmptyPasswords   no
    set_sshd MaxAuthTries           3
    set_sshd MaxSessions            3
    set_sshd X11Forwarding          no
    set_sshd IgnoreRhosts           yes
    set_sshd HostbasedAuthentication no
    set_sshd ClientAliveInterval    300
    set_sshd ClientAliveCountMax    2
    set_sshd UsePAM                 yes

    # Optionally change SSH port
    CURRENT_PORT=$(grep -E "^#?[[:space:]]*Port " "$SSHD_CFG" | tail -1 | awk '{print $2}' || echo 22)
    CURRENT_PORT=${CURRENT_PORT:-22}
    if ask "Change SSH port (currently ${CURRENT_PORT})? [Requires UFW update if enabled]"; then
        while true; do
            echo -en "${BOLD}[?]${RESET} Enter new SSH port (1024–65535): "
            read -r SSH_PORT
            if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )); then
                break
            fi
            echo "  Invalid port. Enter a number between 1024 and 65535."
        done
        set_sshd Port "$SSH_PORT"
        warn "SSH port set to ${SSH_PORT}. Remember to allow it in UFW!"
        SSH_PORT_CHANGED=true
    else
        SSH_PORT=22
        SSH_PORT_CHANGED=false
    fi

    # Optionally restrict to specific user
    if [[ -n "${NEW_USER:-}" ]]; then
        if ask "Restrict SSH logins to user '${NEW_USER}' only?"; then
            set_sshd AllowUsers "$NEW_USER"
            ok "AllowUsers set to ${NEW_USER}."
        fi
    fi

    sshd -t && systemctl restart sshd && ok "SSH daemon restarted with hardened config." \
        || { err "sshd config test failed – reverting!"; cp "${SSHD_CFG}.bak."* "$SSHD_CFG"; systemctl restart sshd; }
else
    skip "SSH hardening"
    SSH_PORT=22
    SSH_PORT_CHANGED=false
fi

# =============================================================================
# 4 · UFW FIREWALL
# =============================================================================
section "4 · UFW Firewall"
echo "  deny all incoming, allow all outgoing, allow SSH"
echo

if ask "Install and configure UFW?"; then
    apt-get install -y ufw -qq

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    SSH_PORT="${SSH_PORT:-22}"
    ufw allow "${SSH_PORT}/tcp" comment "SSH"
    ok "Allowed SSH on port ${SSH_PORT}."

    if ask "Allow HTTP (port 80)?";  then ufw allow 80/tcp  comment "HTTP";  ok "HTTP allowed.";  fi
    if ask "Allow HTTPS (port 443)?"; then ufw allow 443/tcp comment "HTTPS"; ok "HTTPS allowed."; fi

    while ask "Allow another custom port?"; do
        echo -en "${BOLD}[?]${RESET} Port number: "
        read -r CUSTOM_PORT
        echo -en "${BOLD}[?]${RESET} Protocol (tcp/udp) [tcp]: "
        read -r CUSTOM_PROTO
        CUSTOM_PROTO="${CUSTOM_PROTO:-tcp}"
        ufw allow "${CUSTOM_PORT}/${CUSTOM_PROTO}"
        ok "Allowed ${CUSTOM_PORT}/${CUSTOM_PROTO}."
    done

    ufw --force enable
    ok "UFW enabled."
    ufw status verbose
else
    skip "UFW firewall"
fi

# =============================================================================
# 5 · FAIL2BAN
# =============================================================================
section "5 · Fail2Ban – Brute-Force Protection"
echo "  Installs Fail2Ban and enables the SSH jail."
echo

if ask "Install and configure Fail2Ban?"; then
    apt-get install -y fail2ban -qq

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT:-22}
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 24h
EOF

    systemctl enable --now fail2ban
    ok "Fail2Ban installed and SSH jail active."
    fail2ban-client status
else
    skip "Fail2Ban"
fi

# =============================================================================
# 6 · AUTOMATIC SECURITY UPDATES
# =============================================================================
section "6 · Automatic Security Updates"
echo "  Installs unattended-upgrades for automatic security patches."
echo

if ask "Enable automatic security updates?"; then
    apt-get install -y unattended-upgrades apt-listchanges -qq

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # Ensure security updates are enabled in unattended-upgrades config
    sed -i 's|//\s*"${distro_id}:${distro_codename}-security";|"${distro_id}:${distro_codename}-security";|' \
        /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true

    systemctl enable --now unattended-upgrades
    ok "Automatic security updates enabled."
else
    skip "Automatic security updates"
fi

# =============================================================================
# 7 · KERNEL HARDENING (sysctl)
# =============================================================================
section "7 · Kernel Hardening"
echo "  Writes hardened sysctl parameters to:"
echo "  /etc/sysctl.d/99-hardening.conf"
echo

if ask "Apply kernel hardening via sysctl?"; then
    cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# ── Network: IP spoofing / redirect protection ────────────────────────────────
net.ipv4.conf.all.rp_filter                = 1
net.ipv4.conf.default.rp_filter            = 1
net.ipv4.conf.all.accept_redirects         = 0
net.ipv4.conf.default.accept_redirects     = 0
net.ipv6.conf.all.accept_redirects         = 0
net.ipv6.conf.default.accept_redirects     = 0
net.ipv4.conf.all.send_redirects           = 0
net.ipv4.conf.default.send_redirects       = 0
net.ipv4.conf.all.accept_source_route      = 0
net.ipv4.conf.default.accept_source_route  = 0
net.ipv6.conf.all.accept_source_route      = 0

# ── SYN flood protection ──────────────────────────────────────────────────────
net.ipv4.tcp_syncookies                    = 1
net.ipv4.tcp_max_syn_backlog               = 2048
net.ipv4.tcp_synack_retries                = 2
net.ipv4.tcp_syn_retries                   = 5

# ── Ignore ICMP broadcasts / bogus errors ─────────────────────────────────────
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ── Log martians (spoofed packets) ───────────────────────────────────────────
net.ipv4.conf.all.log_martians             = 1
net.ipv4.conf.default.log_martians         = 1

# ── IPv6 router advertisements ───────────────────────────────────────────────
net.ipv6.conf.all.accept_ra                = 0
net.ipv6.conf.default.accept_ra            = 0

# ── Kernel address / pointer exposure ────────────────────────────────────────
kernel.kptr_restrict                       = 2
kernel.dmesg_restrict                      = 1

# ── Prevent ptrace abuse ─────────────────────────────────────────────────────
kernel.yama.ptrace_scope                   = 1

# ── Randomize memory layout (ASLR) ───────────────────────────────────────────
kernel.randomize_va_space                  = 2

# ── Restrict core dumps ──────────────────────────────────────────────────────
fs.suid_dumpable                           = 0
kernel.core_uses_pid                       = 1
EOF

    sysctl --system > /dev/null
    ok "Kernel parameters applied."
else
    skip "Kernel hardening"
fi

# =============================================================================
# 8 · SECURE SHARED MEMORY
# =============================================================================
section "8 · Secure Shared Memory (/run/shm)"
echo "  Mounts /run/shm with noexec, nosuid, nodev."
echo "  Prevents code execution from shared memory."
echo

if ask "Secure shared memory?"; then
    FSTAB="/etc/fstab"
    if grep -q "/run/shm" "$FSTAB"; then
        warn "/run/shm already in fstab – skipping to avoid duplicate."
    else
        cp "$FSTAB" "${FSTAB}.bak.$(date +%Y%m%d%H%M%S)"
        echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> "$FSTAB"
        mount -o remount /run/shm 2>/dev/null || true
        ok "Shared memory secured."
    fi
else
    skip "Secure shared memory"
fi

# =============================================================================
# 9 · AUDIT LOGGING (auditd)
# =============================================================================
section "9 · Audit Logging (auditd)"
echo "  Installs auditd for tracking security-relevant system calls."
echo

if ask "Install and enable auditd?"; then
    apt-get install -y auditd audispd-plugins -qq

    # Basic audit rules
    cat > /etc/audit/rules.d/99-hardening.rules << 'EOF'
# Delete existing rules
-D

# Set buffer size
-b 8192

# Failure mode: 1 = print, 2 = panic
-f 1

# Monitor authentication files
-w /etc/passwd       -p wa -k identity
-w /etc/shadow       -p wa -k identity
-w /etc/group        -p wa -k identity
-w /etc/gshadow      -p wa -k identity
-w /etc/sudoers      -p wa -k sudoers
-w /etc/sudoers.d/   -p wa -k sudoers

# Monitor SSH config
-w /etc/ssh/sshd_config -p wa -k sshd

# Monitor login/logout
-w /var/log/lastlog  -p wa -k logins
-w /var/run/faillock -p wa -k logins

# Monitor privileged commands
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_commands
-a always,exit -F arch=b32 -S execve -F euid=0 -k root_commands

# Monitor network config changes
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k network_modification
-w /etc/hosts        -p wa -k hosts_file
-w /etc/network/     -p wa -k network

# Make rules immutable (requires reboot to change)
# -e 2
EOF

    systemctl enable --now auditd
    augenrules --load 2>/dev/null || auditctl -R /etc/audit/rules.d/99-hardening.rules 2>/dev/null || true
    ok "auditd installed and rules loaded."
else
    skip "Audit logging"
fi

# =============================================================================
# 10 · REMOVE UNNECESSARY PACKAGES / SERVICES
# =============================================================================
section "10 · Remove Unnecessary Packages & Services"
echo "  Removes/disables common packages not needed on a server."
echo

if ask "Review and remove unnecessary packages/services?"; then

    REMOVABLE_PKGS=(
        "telnet"
        "rsh-client"
        "rsh-redone-client"
        "nis"
        "talk"
        "ntalk"
        "inetutils-telnetd"
        "xserver-xorg-core"
    )

    REMOVABLE_SVCS=(
        "bluetooth"
        "avahi-daemon"
        "cups"
        "isc-dhcp-server"
        "slapd"
        "nfs-server"
        "rpcbind"
        "rsync"
        "snmpd"
        "nis"
    )

    echo
    info "Checking packages to remove…"
    PKGS_TO_REMOVE=()
    for pkg in "${REMOVABLE_PKGS[@]}"; do
        if dpkg -l "$pkg" &>/dev/null 2>&1; then
            if ask "  Remove package '${pkg}'?"; then
                PKGS_TO_REMOVE+=("$pkg")
            fi
        fi
    done

    if [[ ${#PKGS_TO_REMOVE[@]} -gt 0 ]]; then
        apt-get purge -y "${PKGS_TO_REMOVE[@]}" -qq
        apt-get autoremove -y -qq
        ok "Removed: ${PKGS_TO_REMOVE[*]}"
    else
        info "No packages removed."
    fi

    echo
    info "Checking services to disable…"
    for svc in "${REMOVABLE_SVCS[@]}"; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1 | grep -q "$svc"; then
            if ask "  Disable and stop service '${svc}'?"; then
                systemctl disable --now "$svc" 2>/dev/null && ok "Disabled: ${svc}" || warn "Could not disable ${svc} (may not be installed)."
            fi
        fi
    done
else
    skip "Package/service cleanup"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo
echo -e "${BOLD}${GREEN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║         Hardening Run Complete!           ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${BOLD}Next steps:${RESET}"
echo "  • Verify SSH access in a NEW session before closing this one"
echo "  • Run: sudo lynis audit system  (for a full security score)"
echo "  • Run: sudo ufw status verbose  (review firewall rules)"
echo "  • Run: sudo fail2ban-client status sshd  (check jail)"
echo "  • Consider enabling Ubuntu Pro for USG/CIS automation:"
echo "    sudo pro attach && sudo pro enable usg"
echo

if ask "Reboot now to apply all changes (recommended)?"; then
    info "Rebooting in 5 seconds… (Ctrl+C to abort)"
    sleep 5
    reboot
else
    warn "Some changes (shared memory, kernel params) are fully active after reboot."
fi