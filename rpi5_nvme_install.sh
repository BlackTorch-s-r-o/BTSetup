#!/usr/bin/env bash
# =============================================================================
# BlackTorch – Ubuntu 24.04 server hardening  (v2)
#
# All questions asked upfront, then runs unattended (except `adduser` if you
# ask it to create a brand-new user).  Run:  sudo bash secure_ubuntu_server.sh
#
# Changes vs v1:
#   * SSH keys go to the ADMIN USER, never to root (v1 could lock you out when
#     no user was created, because root login is disabled).
#   * Hardening is a drop-in (00-bt-hardening.conf) that sorts before
#     50-cloud-init.conf, so it actually wins (sshd = first match wins), and the
#     EFFECTIVE config is verified with `sshd -T`.
#   * No SSH port change (Ubuntu 24.04 ssh.socket + UFW = lockout trap).
#   * Refuses to disable password auth unless the admin user has >=1 valid key.
#   * Optional auto-revert timer: SSH/UFW changes roll back after N minutes
#     unless you cancel it from a second, working SSH session.
#   * UFW: no `reset`, optional SSH source restriction, WireGuard port, and
#     Incus bridge rules (UFW's default forward policy breaks Incus NAT/DHCP).
#   * Kernel: rp_filter=2 (loose), no accept_ra=0, no log_martians.
#   * Dropped the /run/shm fstab hack (/run/shm is a symlink on Ubuntu).
#   * auditd: no execve-for-root logging (fills the disk); rules fit this stack.
# =============================================================================
set -Eeuo pipefail

VERSION="2.0"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/var/log/bt-harden.log"
BACKUP_DIR="/root/bt-harden-backup-${STAMP}"
SSH_DROPIN="/etc/ssh/sshd_config.d/00-bt-hardening.conf"
REVERT_SCRIPT="/usr/local/sbin/bt-harden-revert.sh"
REVERT_UNIT="bt-harden-revert"

# ── colours / helpers ─────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

info()    { printf '%s[INFO]%s %s\n'  "$CYAN"   "$RESET" "$*"; }
ok()      { printf '%s[OK]%s %s\n'    "$GREEN"  "$RESET" "$*"; }
warn()    { printf '%s[WARN]%s %s\n'  "$YELLOW" "$RESET" "$*"; }
skip()    { printf '%s[SKIP]%s %s\n'  "$YELLOW" "$RESET" "$*"; }
err()     { printf '%s[ERROR]%s %s\n' "$RED"    "$RESET" "$*" >&2; exit 1; }
section() { printf '\n%s%s══ %s ══%s\n' "$BOLD" "$CYAN" "$*" "$RESET"; }
err_trap() { printf '%s[ERROR]%s failed at line %s (log: %s)\n' "$RED" "$RESET" "$1" "$LOG" >&2; }

# ask "question" [y|n]   -> returns 0 for yes. Default is n unless given.
ask() {
    local prompt="$1" def="${2:-n}" hint answer
    [[ "$def" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        printf '%s%s[?]%s %s %s%s%s ' "$BOLD" "$YELLOW" "$RESET" "$prompt" "$BOLD" "$hint" "$RESET" >&2
        read -r answer || answer=""
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            "")    [[ "$def" == "y" ]] && return 0 || return 1 ;;
            *)     echo " Please answer y or n." >&2 ;;
        esac
    done
}

# prompt "text" VARNAME  -> reads a line into VARNAME (empty allowed)
prompt() {
    local text="$1" var="$2" val
    printf '%s[?]%s %s ' "$BOLD" "$RESET" "$text" >&2
    read -r val || val=""
    printf -v "$var" '%s' "$val"
}

# ── validators ────────────────────────────────────────────────────────────────
# valid_key "ssh-ed25519 AAAA... comment"  (checked by ssh-keygen itself)
valid_key() {
    local k="$1" tmp rc=0
    local re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+'
    [[ "$k" =~ $re ]] || return 1
    tmp="$(mktemp)"
    printf '%s\n' "$k" > "$tmp"
    ssh-keygen -l -f "$tmp" >/dev/null 2>&1 || rc=1
    rm -f "$tmp"
    return "$rc"
}

key_desc() {   # "256 SHA256:xxx comment (ED25519)"
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$1" > "$tmp"
    ssh-keygen -l -f "$tmp" 2>/dev/null || echo "?"
    rm -f "$tmp"
}

count_keys_in_file() {   # number of keys ssh-keygen can read from an authorized_keys file
    local f="$1"
    [[ -f "$f" ]] || { echo 0; return 0; }
    { ssh-keygen -l -f "$f" 2>/dev/null || true; } | wc -l
}

# ip_in_cidr IP CIDR -> 0 inside, 1 outside, 2 invalid input
ip_in_cidr() {
    python3 -I - "$1" "$2" <<'PY'
import ipaddress, sys
try:
    sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)
except ValueError:
    sys.exit(2)
PY
}

valid_cidr() {   # accepts a single IP or a CIDR
    local rc=0
    ip_in_cidr "0.0.0.0" "$1" || rc=$?
    [[ $rc -ne 2 ]]
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

current_client_ip() {
    local ip="${SSH_CLIENT:-}"; ip="${ip%% *}"
    [[ -z "$ip" ]] && ip="$(who -m 2>/dev/null | sed -n 's/.*(\(.*\))$/\1/p')"
    echo "$ip"
}

detect_ssh_svc() {
    local s
    for s in ssh sshd; do
        if systemctl list-unit-files "${s}.service" 2>/dev/null | grep -q "^${s}.service"; then
            echo "$s"; return 0
        fi
    done
    echo ssh
}

detect_ssh_ports() {
    local p
    p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ')" || true
    echo "${p:-22}"
}

# ── config renderers (kept separate so they can be tested) ────────────────────
render_sshd_dropin() {
    cat <<EOF
# Managed by BTSetup secure_ubuntu_server.sh v${VERSION} on ${STAMP}
# Sorts before 50-cloud-init.conf on purpose: for sshd the FIRST value wins.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
HostbasedAuthentication no
IgnoreRhosts yes
MaxAuthTries 3
LoginGraceTime 30
MaxSessions 4
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    if "${SSH_RESTRICT_USER:-false}"; then echo "AllowUsers ${TARGET_USER}"; fi
}

render_fail2ban() {
    cat <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = 127.0.0.1/8 ::1${F2B_IGNORE:+ ${F2B_IGNORE}}

[sshd]
enabled  = true
maxretry = 3
bantime  = 24h
EOF
}

render_sysctl() {
    cat <<'EOF'
# BTSetup kernel hardening. Deliberately does NOT touch ip_forward (Incus/WireGuard
# manage it), accept_ra (colo IPv6 may rely on RA) or log_martians (noisy on a bridge).

# Spoofing / redirects / source routing. rp_filter=2 (loose) is safe with
# WireGuard, bridges and asymmetric paths; strict (1) can silently drop traffic.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# SYN flood / ICMP noise
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Info leaks
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
}

render_audit_rules() {
    cat <<'EOF'
-D
-b 8192
-f 1
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /root/.ssh/ -p wa -k ssh_keys
-w /etc/netplan/ -p wa -k network
-w /etc/wireguard/ -p wa -k wireguard
-w /etc/fstab -p wa -k mounts
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k network_modification
EOF
}

render_revert_script() {
    cat <<EOF
#!/usr/bin/env bash
# Written by BTSetup hardening. Fires if you did not cancel the timer.
rm -f "${SSH_DROPIN}"
systemctl reload ${SSH_SVC} 2>/dev/null || systemctl restart ${SSH_SVC} || true
command -v ufw >/dev/null 2>&1 && ufw --force disable || true
logger -t bt-harden "auto-revert fired: SSH drop-in removed, UFW disabled"
EOF
}

# ── globals set during planning ───────────────────────────────────────────────
DO_UPDATE=false; DO_SSH=false; DO_UFW=false; DO_FAIL2BAN=false
DO_AUTOUPDATE=false; DO_KERNEL=false; DO_AUDIT=false; DO_CLEANUP=false
DO_REBOOT=false; DO_REVERT=false; REVERT_MIN=10
TARGET_USER=""; CREATE_USER=false; SSH_RESTRICT_USER=false
SSH_KEYS=(); SSH_ALLOW_CIDR=""
UFW_HTTP=false; UFW_HTTPS=false; UFW_INCUS=false; UFW_PORTS=()
F2B_IGNORE=""
PKGS_TO_REMOVE=(); SVCS_TO_DISABLE=()
SSH_SVC="ssh"

# =============================================================================
# PHASE 1 · PLANNING
# =============================================================================
plan() {
    [[ $EUID -eq 0 ]] || err "Run as root: sudo bash $0"
    command -v ssh-keygen >/dev/null || err "ssh-keygen missing (apt install openssh-client)"
    command -v python3 >/dev/null || err "python3 missing"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == 24.* ]] || \
            warn "Written for Ubuntu 24.04, this is ${PRETTY_NAME:-unknown}."
    fi

    printf '%s%s\n  BlackTorch · Ubuntu server hardening v%s · Phase 1: planning\n%s\n' "$BOLD" "$CYAN" "$VERSION" "$RESET"
    warn "Keep this SSH session open AND have the iDRAC virtual console ready."
    echo

    # 1 · update
    section "1 · System update"
    ask "Run apt update + full-upgrade + autoremove?" y && DO_UPDATE=true

    # 2/3 · admin user + SSH
    section "2 · Admin user & SSH hardening"
    echo " Disables root login and password auth (drop-in file, verified with sshd -T)."
    if ask "Apply SSH hardening?" y; then
        DO_SSH=true
        local def="${SUDO_USER:-}"
        while true; do
            prompt "Admin username that will log in via SSH [${def:-none}]:" TARGET_USER
            TARGET_USER="${TARGET_USER:-$def}"
            [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
            echo " Invalid username." >&2
        done
        if id "$TARGET_USER" &>/dev/null; then
            info "User '${TARGET_USER}' exists."
        else
            CREATE_USER=true
            info "User '${TARGET_USER}' will be created (adduser asks for a password in phase 2)."
        fi

        local ak="" existing=0
        if ! $CREATE_USER; then
            ak="$(getent passwd "$TARGET_USER" | cut -d: -f6)/.ssh/authorized_keys"
            existing="$(count_keys_in_file "$ak")"
            info "${TARGET_USER} already has ${existing} valid key(s) in authorized_keys."
        fi

        # GitHub import
        local gh k
        prompt "Import keys from GitHub username (blank = skip):" gh
        if [[ -n "$gh" ]]; then
            if [[ "$gh" =~ ^[A-Za-z0-9-]+$ ]] && command -v curl >/dev/null; then
                local fetched; fetched="$(curl -fsSL --max-time 10 "https://github.com/${gh}.keys" 2>/dev/null || true)"
                while IFS= read -r k; do
                    [[ -z "$k" ]] && continue
                    if valid_key "$k"; then SSH_KEYS+=("$k"); info "GitHub key: $(key_desc "$k")"; fi
                done <<< "$fetched"
            else
                warn "Bad GitHub username or curl missing – skipped."
            fi
        fi

        # paste
        echo " Paste public keys (cat ~/.ssh/id_ed25519.pub), blank line to finish:"
        while true; do
            prompt "[key]" k
            [[ -z "$k" ]] && break
            if valid_key "$k"; then
                SSH_KEYS+=("$k"); ok "Accepted: $(key_desc "$k")"
            else
                warn "Not a valid public key – ignored."
            fi
        done

        if (( existing + ${#SSH_KEYS[@]} == 0 )); then
            warn "No keys available for ${TARGET_USER}. Password auth would be disabled with NO way in."
            warn "SSH hardening DISABLED for this run. Add a key and re-run."
            DO_SSH=false
        else
            ask "Restrict SSH logins to '${TARGET_USER}' only (AllowUsers)?" && SSH_RESTRICT_USER=true
        fi
    fi

    # 4 · UFW
    section "3 · UFW firewall"
    echo " deny incoming, allow outgoing, allow SSH (existing rules are kept, no reset)."
    if ask "Install and configure UFW?" y; then
        DO_UFW=true
        local cidr client
        prompt "Allow SSH only from this IP/CIDR (blank = anywhere):" cidr
        if [[ -n "$cidr" ]]; then
            if valid_cidr "$cidr"; then
                client="$(current_client_ip)"
                if [[ -n "$client" ]] && ! ip_in_cidr "$client" "$cidr"; then
                    warn "Your current SSH client (${client}) is NOT inside ${cidr} – you would lock yourself out."
                    warn "Ignoring the restriction; SSH stays open to anywhere."
                else
                    SSH_ALLOW_CIDR="$cidr"
                fi
            else
                warn "Not a valid IP/CIDR – ignored."
            fi
        fi
        ask "Allow HTTP (80)?"  && UFW_HTTP=true
        ask "Allow HTTPS (443)?" && UFW_HTTPS=true
        local wg
        prompt "WireGuard UDP port to allow (e.g. 51820, blank = none):" wg
        if [[ -n "$wg" ]]; then
            valid_port "$wg" && UFW_PORTS+=("${wg}/udp") || warn "Invalid port – ignored."
        fi
        ask "Will this host run Incus (adds incusbr0 rules so VM NAT/DHCP/DNS work)?" y && UFW_INCUS=true
        local cp proto
        while ask "Allow another custom port?"; do
            prompt "Port number:" cp
            prompt "Protocol (tcp/udp) [tcp]:" proto
            proto="${proto:-tcp}"
            if valid_port "$cp" && [[ "$proto" =~ ^(tcp|udp)$ ]]; then UFW_PORTS+=("${cp}/${proto}"); else warn "Invalid – ignored."; fi
        done
    fi

    # 5 · fail2ban
    section "4 · Fail2Ban"
    if ask "Install and configure Fail2Ban (sshd jail)?" y; then
        DO_FAIL2BAN=true
        local ig item
        prompt "Trusted IPs/CIDRs that must never be banned (space-separated, blank = none):" ig
        for item in $ig; do
            valid_cidr "$item" && F2B_IGNORE+="${F2B_IGNORE:+ }${item}" || warn "Skipping invalid '${item}'."
        done
    fi

    # 6-9
    section "5 · Misc"
    ask "Enable automatic SECURITY updates (no auto-reboot)?" y && DO_AUTOUPDATE=true
    ask "Apply kernel/network sysctl hardening?" y && DO_KERNEL=true
    ask "Install auditd with a small rule set (identity, sudo, ssh, netplan, wireguard)?" && DO_AUDIT=true

    if ask "Review packages/services to remove/disable?"; then
        DO_CLEANUP=true
        local pkg svc
        for pkg in telnet rsh-client rsh-redone-client nis talk ntalk inetutils-telnetd; do
            if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
                ask " Remove package '${pkg}'?" && PKGS_TO_REMOVE+=("$pkg")
            fi
        done
        for svc in bluetooth avahi-daemon cups cups-browsed rpcbind snmpd; do
            if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                ask " Disable service '${svc}'?" && SVCS_TO_DISABLE+=("$svc")
            fi
        done
    fi

    # safety net + reboot
    if $DO_SSH || $DO_UFW; then
        section "6 · Safety net"
        echo " Auto-revert removes the SSH drop-in and disables UFW after N minutes unless"
        echo " you cancel it from a NEW working SSH session:  systemctl stop ${REVERT_UNIT}.timer"
        if ask "Arm the auto-revert timer?" y; then
            DO_REVERT=true
            local m; prompt "Minutes [10]:" m
            [[ "$m" =~ ^[0-9]+$ ]] && (( m >= 2 && m <= 120 )) && REVERT_MIN="$m"
        fi
    fi
    if $DO_REVERT; then
        info "Auto-reboot disabled while the revert timer is armed (a reboot would drop the timer)."
    else
        ask "Reboot when finished?" && DO_REBOOT=true
    fi

    # summary
    yn() { if "$1"; then printf '%syes%s' "$GREEN" "$RESET"; else printf '%sno%s' "$YELLOW" "$RESET"; fi; }
    printf '\n%s%s  Plan%s\n' "$BOLD" "$CYAN" "$RESET"
    printf '   %-34s %s\n' "System update"          "$(yn $DO_UPDATE)"
    printf '   %-34s %s\n' "SSH hardening"          "$($DO_SSH && echo "${GREEN}yes → ${TARGET_USER}${RESET} (${#SSH_KEYS[@]} new key(s))" || yn false)"
    printf '   %-34s %s\n' "UFW"                    "$($DO_UFW && echo "${GREEN}yes${RESET}${SSH_ALLOW_CIDR:+ (SSH from ${SSH_ALLOW_CIDR})}" || yn false)"
    printf '   %-34s %s\n' "Fail2Ban"               "$(yn $DO_FAIL2BAN)"
    printf '   %-34s %s\n' "Automatic security updates" "$(yn $DO_AUTOUPDATE)"
    printf '   %-34s %s\n' "Kernel hardening"       "$(yn $DO_KERNEL)"
    printf '   %-34s %s\n' "auditd"                 "$(yn $DO_AUDIT)"
    printf '   %-34s %s\n' "Cleanup"                "$($DO_CLEANUP && echo "${GREEN}pkgs ${#PKGS_TO_REMOVE[@]}, svcs ${#SVCS_TO_DISABLE[@]}${RESET}" || yn false)"
    printf '   %-34s %s\n' "Auto-revert timer"      "$($DO_REVERT && echo "${GREEN}${REVERT_MIN} min${RESET}" || yn false)"
    printf '   %-34s %s\n\n' "Reboot"               "$(yn $DO_REBOOT)"
    ask "Proceed?" || { echo "Aborted."; exit 0; }
}

# =============================================================================
# PHASE 2 · EXECUTION
# =============================================================================
apt_install() { DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq "$@"; }

do_update() {
    section "System update"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
    apt-get -y autoremove
    ok "System up to date."
}

ensure_user() {
    if $CREATE_USER; then
        adduser --gecos "" "$TARGET_USER"
        ok "User ${TARGET_USER} created."
    fi
    if [[ " $(id -nG "$TARGET_USER") " != *" sudo "* ]]; then
        usermod -aG sudo "$TARGET_USER"
        ok "Added ${TARGET_USER} to sudo."
    fi
}

install_keys() {
    local home grp ak k
    home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    grp="$(id -gn "$TARGET_USER")"
    install -d -m 700 -o "$TARGET_USER" -g "$grp" "${home}/.ssh"
    ak="${home}/.ssh/authorized_keys"
    touch "$ak"
    for k in "${SSH_KEYS[@]}"; do
        grep -qxF -- "$k" "$ak" || printf '%s\n' "$k" >> "$ak"
    done
    chown "${TARGET_USER}:${grp}" "$ak"
    chmod 600 "$ak"
    echo "$ak"
}

verify_sshd_effective() {
    local out; out="$(sshd -T 2>/dev/null)" || return 1
    grep -qix 'passwordauthentication no' <<<"$out" && grep -qix 'permitrootlogin no' <<<"$out"
}

arm_revert() {
    section "Arming auto-revert (${REVERT_MIN} min)"
    render_revert_script > "$REVERT_SCRIPT"
    chmod 700 "$REVERT_SCRIPT"
    systemctl stop "${REVERT_UNIT}.timer" "${REVERT_UNIT}.service" 2>/dev/null || true
    systemd-run --quiet --unit="$REVERT_UNIT" --on-active="${REVERT_MIN}m" "$REVERT_SCRIPT"
    ok "SSH/UFW changes roll back in ${REVERT_MIN} min unless you run: sudo systemctl stop ${REVERT_UNIT}.timer"
}

do_ssh() {
    section "SSH hardening"
    [[ -x /usr/sbin/sshd ]] || apt_install openssh-server
    mkdir -p /run/sshd "$BACKUP_DIR"
    cp -a /etc/ssh "${BACKUP_DIR}/ssh"
    ensure_user

    local ak n
    ak="$(install_keys)"
    n="$(count_keys_in_file "$ak")"
    if (( n < 1 )); then
        warn "${ak} has no readable key – NOT touching sshd config."
        DO_SSH=false
        return 0
    fi
    ok "${n} key(s) in ${ak}."

    render_sshd_dropin > "${SSH_DROPIN}.new"
    install -m 644 "${SSH_DROPIN}.new" "$SSH_DROPIN"
    rm -f "${SSH_DROPIN}.new"

    if ! sshd -t; then
        warn "sshd -t failed – removing drop-in, nothing changed."
        rm -f "$SSH_DROPIN"; DO_SSH=false; return 0
    fi
    if ! verify_sshd_effective; then
        warn "Another setting overrides the drop-in (sshd -T still allows passwords/root):"
        grep -rniE 'PasswordAuthentication|PermitRootLogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ || true
        rm -f "$SSH_DROPIN"; DO_SSH=false; return 0
    fi

    systemctl reload "$SSH_SVC" 2>/dev/null || systemctl restart "$SSH_SVC"
    ok "sshd reloaded; effective config verified (no root login, no passwords)."
}

do_ufw() {
    section "UFW firewall"
    apt_install ufw
    ufw default deny incoming  >/dev/null
    ufw default allow outgoing >/dev/null

    local p
    for p in $(detect_ssh_ports); do
        if [[ -n "$SSH_ALLOW_CIDR" ]]; then
            ufw allow from "$SSH_ALLOW_CIDR" to any port "$p" proto tcp comment 'SSH' >/dev/null
        else
            ufw allow "${p}/tcp" comment 'SSH' >/dev/null
        fi
        ok "SSH allowed on ${p}/tcp${SSH_ALLOW_CIDR:+ from ${SSH_ALLOW_CIDR}}."
    done
    $UFW_HTTP  && { ufw allow 80/tcp  comment 'HTTP'  >/dev/null; ok "HTTP allowed."; }
    $UFW_HTTPS && { ufw allow 443/tcp comment 'HTTPS' >/dev/null; ok "HTTPS allowed."; }
    for p in "${UFW_PORTS[@]}"; do ufw allow "$p" >/dev/null; ok "Allowed ${p}."; done
    if $UFW_INCUS; then
        ufw allow in on incusbr0       >/dev/null
        ufw route allow in on incusbr0  >/dev/null
        ufw route allow out on incusbr0 >/dev/null
        ok "Incus bridge rules added (incusbr0)."
    fi
    ufw --force enable >/dev/null
    ok "UFW enabled."
}

do_fail2ban() {
    section "Fail2Ban"
    apt_install fail2ban
    render_fail2ban > /etc/fail2ban/jail.local
    systemctl enable --now fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    ok "Fail2Ban active (sshd jail)."
}

do_autoupdate() {
    section "Automatic security updates"
    apt_install unattended-upgrades apt-listchanges
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    cat > /etc/apt/apt.conf.d/52bt-unattended <<'EOF'
// Security origins are already enabled in 50unattended-upgrades on Ubuntu.
// Never reboot a colo box by surprise; kernel updates wait for you.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    ok "Security updates automatic; reboots stay manual (check /var/run/reboot-required)."
}

do_kernel() {
    section "Kernel hardening"
    render_sysctl > /etc/sysctl.d/99-bt-hardening.conf
    sysctl --system >/dev/null
    ok "sysctl applied (/etc/sysctl.d/99-bt-hardening.conf)."
}

do_audit() {
    section "auditd"
    apt_install auditd audispd-plugins
    render_audit_rules > /etc/audit/rules.d/99-bt-hardening.rules
    systemctl enable --now auditd >/dev/null 2>&1
    augenrules --load >/dev/null 2>&1 || true
    ok "auditd running with the small rule set."
}

do_cleanup() {
    section "Cleanup"
    if (( ${#PKGS_TO_REMOVE[@]} )); then
        apt-get purge -y -qq "${PKGS_TO_REMOVE[@]}"
        apt-get autoremove -y -qq
        ok "Removed: ${PKGS_TO_REMOVE[*]}"
    fi
    local svc
    for svc in "${SVCS_TO_DISABLE[@]}"; do
        if systemctl disable --now "$svc" >/dev/null 2>&1; then ok "Disabled ${svc}"; else warn "Could not disable ${svc}"; fi
    done
}

finish() {
    section "Done – verify"
    if $DO_SSH; then
        echo " Effective sshd settings:"
        sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|allowusers) ' | sed 's/^/   /' || true
    fi
    $DO_UFW && { echo " UFW:"; ufw status | sed 's/^/   /'; }
    $DO_FAIL2BAN && { echo " Fail2Ban:"; fail2ban-client status sshd 2>/dev/null | sed 's/^/   /' || true; }
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
        warn "Clock is not NTP-synchronised (check: timedatectl; apt install chrony)."
    fi
    [[ -f /var/run/reboot-required ]] && warn "Reboot required (kernel/libs updated) – do it when you can."
    printf '\n%s%sNEXT:%s open a NEW terminal and run:  ssh %s@<server-ip>\n' "$BOLD" "$GREEN" "$RESET" "${TARGET_USER:-<user>}"
    if $DO_REVERT; then
        printf '  works?  cancel the rollback:  sudo systemctl stop %s.timer\n' "$REVERT_UNIT"
        printf '  broken? do nothing – in %s min SSH drop-in is removed and UFW disabled.\n' "$REVERT_MIN"
    fi
    echo "  Log: ${LOG}   Backups: ${BACKUP_DIR}"
    echo "  Manual rollback: rm ${SSH_DROPIN}; systemctl reload ${SSH_SVC}; ufw disable"
}

execute() {
    mkdir -p "$BACKUP_DIR"
    exec > >(tee -a "$LOG") 2>&1
    SSH_SVC="$(detect_ssh_svc)"
    echo "== BTSetup hardening v${VERSION} ${STAMP} =="

    $DO_UPDATE && do_update
    if $DO_REVERT; then arm_revert; fi
    $DO_SSH       && do_ssh
    $DO_UFW       && do_ufw
    $DO_FAIL2BAN  && do_fail2ban
    $DO_AUTOUPDATE && do_autoupdate
    $DO_KERNEL    && do_kernel
    $DO_AUDIT     && do_audit
    $DO_CLEANUP   && do_cleanup
    finish

    if $DO_REBOOT; then
        info "Rebooting in 10 seconds (Ctrl+C to abort)…"
        sleep 10
        systemctl reboot
    fi
    return 0
}

main() {
    trap 'err_trap $LINENO' ERR
    plan
    execute
}

# Allow `source`-ing for tests without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi