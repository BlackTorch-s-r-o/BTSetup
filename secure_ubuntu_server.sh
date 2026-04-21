#!/usr/bin/env bash
# =============================================================================
# Ubuntu 24.04 Server Hardening Script
# All questions asked upfront – then runs unattended.
# Run as root or with sudo.
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
skip() { echo -e "${YELLOW}[SKIP]${RESET}  $*"; }

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
[[ $EUID -ne 0 ]] && err "Run as root: sudo ./harden.sh"

# =============================================================================
#  PHASE 1 · PLANNING – all questions upfront
# =============================================================================
clear
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   Ubuntu 24.04 LTS – Server Hardening           ║"
echo "  ║   Phase 1: Planning                             ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
warn "Keep a second SSH session open until all changes are verified."
warn "Have console/VNC access ready as a fallback."
echo
echo "  Answer all questions now. The script will then run unattended."
echo

# ── 1 · System update ─────────────────────────────────────────────────────────
echo -e "${BOLD}── 1 · System Update ────────────────────────────────────${RESET}"
echo "  apt update && apt upgrade && autoremove"
DO_UPDATE=false
ask "Run system update?" && DO_UPDATE=true
echo

# ── 2 · Non-root user ─────────────────────────────────────────────────────────
echo -e "${BOLD}── 2 · Create Non-Root Sudo User ────────────────────────${RESET}"
DO_USER=false
NEW_USER=""
COPY_KEYS=false
ask "Create a new non-root sudo user?" && DO_USER=true

if $DO_USER; then
    while true; do
        echo -en "${BOLD}[?]${RESET} Username: "
        read -r NEW_USER
        [[ -n "$NEW_USER" ]] && break
        echo "  Cannot be empty."
    done
    ask "Copy root's authorized_keys to ${NEW_USER}?" && COPY_KEYS=true
fi
echo

# ── 3 · SSH hardening ─────────────────────────────────────────────────────────
echo -e "${BOLD}── 3 · SSH Hardening ────────────────────────────────────${RESET}"
echo "  Disables password auth, root login, sets session timeouts."
echo
DO_SSH=false
SSH_PORT=22
SSH_CHANGE_PORT=false
SSH_RESTRICT_USER=false
SSH_KEYS=()

ask "Apply SSH hardening?" && DO_SSH=true

if $DO_SSH; then
    echo
    # ── Collect SSH public keys ────────────────────────────────────────────────
    echo -e "  ${BOLD}SSH Public Keys${RESET}"
    echo "  These will be written to authorized_keys BEFORE password auth is disabled."
    echo "  Paste each public key (ssh-ed25519 / ssh-rsa / ecdsa …) and press Enter."
    echo "  Leave blank and press Enter when done."
    echo

    # Show existing keys already on the system as reference
    EXISTING_KEYS=()
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        [[ -f "$f" ]] && while IFS= read -r line; do
            [[ "$line" =~ ^(ssh-|ecdsa-) ]] && EXISTING_KEYS+=("$line")
        done < "$f"
    done

    if [[ ${#EXISTING_KEYS[@]} -gt 0 ]]; then
        info "Existing authorized keys found on this system:"
        for k in "${EXISTING_KEYS[@]}"; do
            # Print key type and comment only, not the full key blob
            TYPE=$(echo "$k" | awk '{print $1}')
            COMMENT=$(echo "$k" | awk '{print $NF}')
            echo "    ${TYPE} … ${COMMENT}"
        done
        echo
        if ask "Include all existing keys automatically?"; then
            SSH_KEYS=("${EXISTING_KEYS[@]}")
            # Write immediately
            mkdir -p /root/.ssh
            chmod 700 /root/.ssh
            touch /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
            for _k in "${EXISTING_KEYS[@]}"; do
                grep -qxF "$_k" /root/.ssh/authorized_keys || echo "$_k" >> /root/.ssh/authorized_keys
            done
            ok "${#SSH_KEYS[@]} existing key(s) confirmed in /root/.ssh/authorized_keys."
        fi
        echo
    fi

    # Ensure authorized_keys exists and is ready before we start accepting keys
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    echo "  Paste additional public keys below (blank line to finish):"
    while true; do
        echo -en "${BOLD}[key]${RESET} "
        read -r KEY_INPUT
        [[ -z "$KEY_INPUT" ]] && break
        if echo "$KEY_INPUT" | grep -qE "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256) "; then
            SSH_KEYS+=("$KEY_INPUT")
            # Write immediately to authorized_keys (deduplicated)
            if grep -qxF "$KEY_INPUT" /root/.ssh/authorized_keys 2>/dev/null; then
                ok "Key already present (${#SSH_KEYS[@]} total): $(echo "$KEY_INPUT" | awk '{print $1}') … $(echo "$KEY_INPUT" | awk '{print $NF}')"
            else
                echo "$KEY_INPUT" >> /root/.ssh/authorized_keys
                ok "Key saved (${#SSH_KEYS[@]} total): $(echo "$KEY_INPUT" | awk '{print $1}') … $(echo "$KEY_INPUT" | awk '{print $NF}')"
            fi
        else
            warn "Does not look like a valid public key – skipping. Expected format: ssh-ed25519 AAAA... comment"
        fi
    done

    if [[ ${#SSH_KEYS[@]} -eq 0 ]]; then
        echo
        warn "No SSH keys collected!"
        warn "Proceeding will disable password auth with NO keys = you will be locked out."
        if ! ask "Are you absolutely sure you want to continue without any keys?"; then
            err "Aborted. Add your SSH key and re-run."
        fi
    else
        ok "${#SSH_KEYS[@]} key(s) will be written before SSH is locked down."
    fi
    echo

    # ── Port and user restrictions ─────────────────────────────────────────────
    CURRENT_PORT=$(grep -E "^#?[[:space:]]*Port " /etc/ssh/sshd_config 2>/dev/null \
        | tail -1 | awk '{print $2}' || echo 22)
    CURRENT_PORT=${CURRENT_PORT:-22}
    if ask "Change SSH port (currently ${CURRENT_PORT})?"; then
        SSH_CHANGE_PORT=true
        while true; do
            echo -en "${BOLD}[?]${RESET} New SSH port (1024–65535): "
            read -r SSH_PORT
            [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )) && break
            echo "  Invalid port."
        done
    fi
    if [[ -n "$NEW_USER" ]]; then
        ask "Restrict SSH logins to '${NEW_USER}' only?" && SSH_RESTRICT_USER=true
    fi
fi
echo

# ── 4 · UFW ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}── 4 · UFW Firewall ─────────────────────────────────────${RESET}"
echo "  deny all incoming, allow all outgoing, allow SSH"
DO_UFW=false
UFW_HTTP=false
UFW_HTTPS=false
UFW_CUSTOM_PORTS=()
ask "Install and configure UFW?" && DO_UFW=true

if $DO_UFW; then
    ask "Allow HTTP (port 80)?"  && UFW_HTTP=true
    ask "Allow HTTPS (port 443)?" && UFW_HTTPS=true
    while ask "Allow a custom port?"; do
        echo -en "${BOLD}[?]${RESET} Port number: "
        read -r CP_NUM
        echo -en "${BOLD}[?]${RESET} Protocol (tcp/udp) [tcp]: "
        read -r CP_PROTO
        CP_PROTO="${CP_PROTO:-tcp}"
        UFW_CUSTOM_PORTS+=("${CP_NUM}/${CP_PROTO}")
    done
fi
echo

# ── 5 · Fail2Ban ──────────────────────────────────────────────────────────────
echo -e "${BOLD}── 5 · Fail2Ban ─────────────────────────────────────────${RESET}"
DO_FAIL2BAN=false
ask "Install and configure Fail2Ban?" && DO_FAIL2BAN=true
echo

# ── 6 · Automatic updates ─────────────────────────────────────────────────────
echo -e "${BOLD}── 6 · Automatic Security Updates ──────────────────────${RESET}"
DO_AUTOUPDATE=false
ask "Enable automatic security updates?" && DO_AUTOUPDATE=true
echo

# ── 7 · Kernel hardening ──────────────────────────────────────────────────────
echo -e "${BOLD}── 7 · Kernel Hardening (sysctl) ────────────────────────${RESET}"
DO_KERNEL=false
ask "Apply kernel hardening?" && DO_KERNEL=true
echo

# ── 8 · Shared memory ─────────────────────────────────────────────────────────
echo -e "${BOLD}── 8 · Secure Shared Memory ─────────────────────────────${RESET}"
DO_SHM=false
ask "Secure /run/shm (noexec, nosuid, nodev)?" && DO_SHM=true
echo

# ── 9 · Audit logging ─────────────────────────────────────────────────────────
echo -e "${BOLD}── 9 · Audit Logging (auditd) ───────────────────────────${RESET}"
DO_AUDIT=false
ask "Install and enable auditd?" && DO_AUDIT=true
echo

# ── 10 · Package cleanup ──────────────────────────────────────────────────────
echo -e "${BOLD}── 10 · Remove Unnecessary Packages & Services ──────────${RESET}"
DO_CLEANUP=false
PKGS_TO_REMOVE=()
SVCS_TO_DISABLE=()

REMOVABLE_PKGS=(telnet rsh-client rsh-redone-client nis talk ntalk inetutils-telnetd xserver-xorg-core)
REMOVABLE_SVCS=(bluetooth avahi-daemon cups isc-dhcp-server slapd nfs-server rpcbind rsync snmpd nis)

ask "Review packages/services to remove?" && DO_CLEANUP=true

if $DO_CLEANUP; then
    echo
    info "Which installed packages should be removed?"
    for pkg in "${REMOVABLE_PKGS[@]}"; do
        if dpkg -l "$pkg" &>/dev/null 2>&1; then
            ask "  Remove package '${pkg}'?" && PKGS_TO_REMOVE+=("$pkg")
        fi
    done
    echo
    info "Which services should be disabled?"
    for svc in "${REMOVABLE_SVCS[@]}"; do
        if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
            ask "  Disable service '${svc}'?" && SVCS_TO_DISABLE+=("$svc")
        fi
    done
fi
echo

# ── reboot ────────────────────────────────────────────────────────────────────
DO_REBOOT=false
ask "Reboot when finished?" && DO_REBOOT=true
echo

# ── confirm plan ──────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   Your Hardening Plan                           ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

yn() { $1 && echo -e "${GREEN}yes${RESET}" || echo -e "${YELLOW}no${RESET}"; }

printf "  %-40s %s\n" "1 · System update"              "$(yn $DO_UPDATE)"
if $DO_USER; then
    printf "  %-40s %s\n" "2 · Create user"             "${GREEN}yes → ${NEW_USER}${RESET}"
else
    printf "  %-40s %s\n" "2 · Create user"             "$(yn $DO_USER)"
fi
if $DO_SSH && $SSH_CHANGE_PORT; then
    printf "  %-40s %s\n" "3 · SSH hardening"           "${GREEN}yes → port ${SSH_PORT}${RESET}"
else
    printf "  %-40s %s\n" "3 · SSH hardening"           "$(yn $DO_SSH)"
fi
printf "  %-40s %s\n" "4 · UFW firewall"                "$(yn $DO_UFW)"
printf "  %-40s %s\n" "5 · Fail2Ban"                    "$(yn $DO_FAIL2BAN)"
printf "  %-40s %s\n" "6 · Automatic security updates"  "$(yn $DO_AUTOUPDATE)"
printf "  %-40s %s\n" "7 · Kernel hardening"            "$(yn $DO_KERNEL)"
printf "  %-40s %s\n" "8 · Secure shared memory"        "$(yn $DO_SHM)"
printf "  %-40s %s\n" "9 · Audit logging"               "$(yn $DO_AUDIT)"
if $DO_CLEANUP && [[ ${#PKGS_TO_REMOVE[@]} -gt 0 || ${#SVCS_TO_DISABLE[@]} -gt 0 ]]; then
    printf "  %-40s %s\n" "10 · Package/service cleanup" \
        "${GREEN}yes → pkgs: ${#PKGS_TO_REMOVE[@]}  svcs: ${#SVCS_TO_DISABLE[@]}${RESET}"
else
    printf "  %-40s %s\n" "10 · Package/service cleanup" "$(yn $DO_CLEANUP)"
fi
printf "  %-40s %s\n" "Reboot when done"                "$(yn $DO_REBOOT)"
echo

ask "Proceed with this plan?" || { echo "Aborted."; exit 0; }

# =============================================================================
#  PHASE 2 · EXECUTION – runs unattended
# =============================================================================
clear
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   Ubuntu 24.04 LTS – Server Hardening           ║"
echo "  ║   Phase 2: Executing                            ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── 1 · System update ─────────────────────────────────────────────────────────
section "1 · System Update"
if $DO_UPDATE; then
    info "Updating package lists…"
    apt-get update -qq
    info "Upgrading packages…"
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    info "Removing unused packages…"
    apt-get autoremove -y
    ok "System up to date."
else
    skip "System update"
fi

# ── 2 · Non-root user ─────────────────────────────────────────────────────────
section "2 · Create Non-Root Sudo User"
if $DO_USER; then
    if id "$NEW_USER" &>/dev/null; then
        warn "User '${NEW_USER}' already exists – ensuring sudo membership."
        usermod -aG sudo "$NEW_USER"
    else
        adduser --gecos "" "$NEW_USER"
        usermod -aG sudo "$NEW_USER"
        ok "User '${NEW_USER}' created."
    fi

    if $COPY_KEYS; then
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
        fi
    fi
else
    skip "User creation"
fi

# ── 3 · SSH hardening ─────────────────────────────────────────────────────────
section "3 · SSH Hardening"
if $DO_SSH; then
    SSHD_CFG="/etc/ssh/sshd_config"
    if [[ ! -f "$SSHD_CFG" ]]; then
        warn "openssh-server not installed – installing now."
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server -qq
    fi
    if [[ ! -f "$SSHD_CFG" ]]; then
        err "${SSHD_CFG} still missing after install – aborting SSH hardening."
    fi
    cp "${SSHD_CFG}" "${SSHD_CFG}.bak.$(date +%Y%m%d%H%M%S)"
    info "Backup saved."

    set_sshd() {
        local key="$1" val="$2"
        if grep -qE "^#?[[:space:]]*${key}" "$SSHD_CFG"; then
            sed -i "s|^#\?[[:space:]]*${key}.*|${key} ${val}|" "$SSHD_CFG"
        else
            echo "${key} ${val}" >> "$SSHD_CFG"
        fi
    }

    # Write SSH keys BEFORE disabling password auth
    if [[ ${#SSH_KEYS[@]} -gt 0 ]]; then
        info "Writing ${#SSH_KEYS[@]} SSH key(s) to authorized_keys..."

        # Write to root
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        # Merge: keep existing keys, append new ones avoiding duplicates
        touch /root/.ssh/authorized_keys
        for key in "${SSH_KEYS[@]}"; do
            grep -qxF "$key" /root/.ssh/authorized_keys || echo "$key" >> /root/.ssh/authorized_keys
        done
        chmod 600 /root/.ssh/authorized_keys
        ok "Keys written to /root/.ssh/authorized_keys (${#SSH_KEYS[@]} key(s))."

        # Also write to new user if created
        if [[ -n "${NEW_USER:-}" ]]; then
            USER_SSH="/home/${NEW_USER}/.ssh"
            mkdir -p "$USER_SSH"
            touch "${USER_SSH}/authorized_keys"
            for key in "${SSH_KEYS[@]}"; do
                grep -qxF "$key" "${USER_SSH}/authorized_keys" || echo "$key" >> "${USER_SSH}/authorized_keys"
            done
            chown -R "${NEW_USER}:${NEW_USER}" "$USER_SSH"
            chmod 700 "$USER_SSH"
            chmod 600 "${USER_SSH}/authorized_keys"
            ok "Keys written to ${USER_SSH}/authorized_keys."
        fi
    else
        warn "No SSH keys – skipping authorized_keys update."
    fi

    set_sshd PermitRootLogin         no
    set_sshd PasswordAuthentication  no
    set_sshd PermitEmptyPasswords    no
    set_sshd MaxAuthTries            3
    set_sshd MaxSessions             3
    set_sshd X11Forwarding           no
    set_sshd IgnoreRhosts            yes
    set_sshd HostbasedAuthentication no
    set_sshd ClientAliveInterval     300
    set_sshd ClientAliveCountMax     2
    set_sshd UsePAM                  yes

    $SSH_CHANGE_PORT  && set_sshd Port "$SSH_PORT"
    $SSH_RESTRICT_USER && [[ -n "$NEW_USER" ]] && set_sshd AllowUsers "$NEW_USER"

    # Enforce perms — sshd refuses keys with loose modes, silent lockout
    if [[ -d /root/.ssh ]]; then
        chmod 700 /root/.ssh
        [[ -f /root/.ssh/authorized_keys ]] && chmod 600 /root/.ssh/authorized_keys
        chown -R root:root /root/.ssh
    fi
    if [[ -n "${NEW_USER:-}" && -d "/home/${NEW_USER}/.ssh" ]]; then
        chmod 700 "/home/${NEW_USER}/.ssh"
        [[ -f "/home/${NEW_USER}/.ssh/authorized_keys" ]] && chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys"
        chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"
    fi
    ok "authorized_keys perms locked (700 dir / 600 file)."

    SSH_SVC="ssh"
    systemctl list-unit-files sshd.service &>/dev/null && SSH_SVC="sshd"
    mkdir -p /run/sshd

    if sshd -t; then
        systemctl restart "$SSH_SVC"
        ok "SSH daemon restarted with hardened config."
    else
        err "sshd config test failed – reverting!"
        cp "$(ls -t "${SSHD_CFG}.bak."* | head -1)" "$SSHD_CFG"
        systemctl restart "$SSH_SVC" || true
    fi
else
    skip "SSH hardening"
fi

# ── 4 · UFW ───────────────────────────────────────────────────────────────────
section "4 · UFW Firewall"
if $DO_UFW; then
    apt-get install -y ufw -qq
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    ufw allow "${SSH_PORT}/tcp" comment "SSH"
    ok "SSH allowed on port ${SSH_PORT}."

    $UFW_HTTP  && ufw allow 80/tcp  comment "HTTP"  && ok "HTTP allowed."
    $UFW_HTTPS && ufw allow 443/tcp comment "HTTPS" && ok "HTTPS allowed."

    for cp in "${UFW_CUSTOM_PORTS[@]}"; do
        ufw allow "$cp"
        ok "Allowed: ${cp}"
    done

    ufw --force enable
    ok "UFW enabled."
else
    skip "UFW firewall"
fi

# ── 5 · Fail2Ban ──────────────────────────────────────────────────────────────
section "5 · Fail2Ban"
if $DO_FAIL2BAN; then
    apt-get install -y fail2ban -qq

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 24h
EOF

    systemctl enable --now fail2ban
    ok "Fail2Ban installed and SSH jail active."
else
    skip "Fail2Ban"
fi

# ── 6 · Automatic updates ─────────────────────────────────────────────────────
section "6 · Automatic Security Updates"
if $DO_AUTOUPDATE; then
    apt-get install -y unattended-upgrades apt-listchanges -qq

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    sed -i 's|//\s*"${distro_id}:${distro_codename}-security";|"${distro_id}:${distro_codename}-security";|' \
        /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true

    systemctl enable --now unattended-upgrades
    ok "Automatic security updates enabled."
else
    skip "Automatic security updates"
fi

# ── 7 · Kernel hardening ──────────────────────────────────────────────────────
section "7 · Kernel Hardening"
if $DO_KERNEL; then
    cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# Network: IP spoofing / redirect protection
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

# SYN flood protection
net.ipv4.tcp_syncookies                    = 1
net.ipv4.tcp_max_syn_backlog               = 2048
net.ipv4.tcp_synack_retries                = 2
net.ipv4.tcp_syn_retries                   = 5

# Ignore ICMP broadcasts / bogus errors
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Log martians (spoofed packets)
net.ipv4.conf.all.log_martians             = 1
net.ipv4.conf.default.log_martians         = 1

# IPv6 router advertisements
net.ipv6.conf.all.accept_ra                = 0
net.ipv6.conf.default.accept_ra            = 0

# Kernel address / pointer exposure
kernel.kptr_restrict                       = 2
kernel.dmesg_restrict                      = 1

# Prevent ptrace abuse
kernel.yama.ptrace_scope                   = 1

# Randomize memory layout (ASLR)
kernel.randomize_va_space                  = 2

# Restrict core dumps
fs.suid_dumpable                           = 0
kernel.core_uses_pid                       = 1
EOF

    sysctl --system > /dev/null
    ok "Kernel parameters applied."
else
    skip "Kernel hardening"
fi

# ── 8 · Secure shared memory ──────────────────────────────────────────────────
section "8 · Secure Shared Memory"
if $DO_SHM; then
    FSTAB="/etc/fstab"
    if grep -q "/run/shm" "$FSTAB"; then
        warn "/run/shm already in fstab – skipping."
    else
        cp "$FSTAB" "${FSTAB}.bak.$(date +%Y%m%d%H%M%S)"
        echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> "$FSTAB"
        mount -o remount /run/shm 2>/dev/null || true
        ok "Shared memory secured."
    fi
else
    skip "Secure shared memory"
fi

# ── 9 · Audit logging ─────────────────────────────────────────────────────────
section "9 · Audit Logging"
if $DO_AUDIT; then
    apt-get install -y auditd audispd-plugins -qq

    cat > /etc/audit/rules.d/99-hardening.rules << 'EOF'
-D
-b 8192
-f 1

-w /etc/passwd          -p wa -k identity
-w /etc/shadow          -p wa -k identity
-w /etc/group           -p wa -k identity
-w /etc/gshadow         -p wa -k identity
-w /etc/sudoers         -p wa -k sudoers
-w /etc/sudoers.d/      -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd
-w /var/log/lastlog     -p wa -k logins
-w /var/run/faillock    -p wa -k logins

-a always,exit -F arch=b64 -S execve -F euid=0 -k root_commands
-a always,exit -F arch=b32 -S execve -F euid=0 -k root_commands
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k network_modification
-w /etc/hosts           -p wa -k hosts_file
-w /etc/network/        -p wa -k network
EOF

    systemctl enable --now auditd
    augenrules --load 2>/dev/null || auditctl -R /etc/audit/rules.d/99-hardening.rules 2>/dev/null || true
    ok "auditd installed and rules loaded."
else
    skip "Audit logging"
fi

# ── 10 · Package/service cleanup ──────────────────────────────────────────────
section "10 · Package & Service Cleanup"
if $DO_CLEANUP; then
    if [[ ${#PKGS_TO_REMOVE[@]} -gt 0 ]]; then
        info "Removing packages: ${PKGS_TO_REMOVE[*]}"
        apt-get purge -y "${PKGS_TO_REMOVE[@]}" -qq
        apt-get autoremove -y -qq
        ok "Packages removed."
    else
        info "No packages to remove."
    fi

    if [[ ${#SVCS_TO_DISABLE[@]} -gt 0 ]]; then
        for svc in "${SVCS_TO_DISABLE[@]}"; do
            systemctl disable --now "$svc" 2>/dev/null \
                && ok "Disabled: ${svc}" \
                || warn "Could not disable ${svc}."
        done
    else
        info "No services to disable."
    fi
else
    skip "Package/service cleanup"
fi

# =============================================================================
#  DONE
# =============================================================================
echo
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║         Hardening Complete!                     ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "${BOLD}Verify:${RESET}"
echo "  ssh -p ${SSH_PORT} ${NEW_USER:-ubuntu}@<ip>   ← test in a NEW session first"
echo "  sudo ufw status verbose"
echo "  sudo fail2ban-client status sshd"
echo "  sudo lynis audit system"
echo

if $DO_REBOOT; then
    info "Rebooting in 5 seconds… (Ctrl+C to abort)"
    sleep 5
    reboot
else
    warn "Some changes (shared memory, kernel params) fully apply after reboot."
fi