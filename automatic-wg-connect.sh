#!/usr/bin/env bash
# wg-autoconnect-setup.sh
# Sets up WireGuard to connect automatically on network availability via systemd.
# Must be run as root.

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
WG_INTERFACE="${1:-bt-vpn}"
WG_CONF="/etc/wireguard/${WG_INTERFACE}.conf"
SERVICE_NAME="wg-bt"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 [interface]"

# ── Dependency checks ─────────────────────────────────────────────────────────
command -v wg-quick  &>/dev/null || die "wg-quick not found. Install wireguard-tools."
command -v systemctl &>/dev/null || die "systemctl not found. Is systemd running?"

# ── WireGuard config check ────────────────────────────────────────────────────
if [[ ! -f "$WG_CONF" ]]; then
    warn "WireGuard config not found at $WG_CONF"
    warn "Place your config there before enabling the service."
    warn "Continuing with unit installation anyway..."
fi

# ── network-online.target check ───────────────────────────────────────────────
info "Checking network-online.target provider..."
if systemctl is-enabled systemd-networkd-wait-online &>/dev/null; then
    info "  systemd-networkd-wait-online is enabled — good."
elif systemctl is-enabled NetworkManager-wait-online &>/dev/null; then
    info "  NetworkManager-wait-online is enabled — good."
else
    warn "No wait-online service detected. network-online.target may fire too early."
    warn "Enable one of: systemd-networkd-wait-online or NetworkManager-wait-online"
fi

# ── Write .service unit ───────────────────────────────────────────────────────
info "Writing /etc/systemd/system/${SERVICE_NAME}.service ..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=WireGuard VPN tunnel (bt-vpn)
After=local-fs.target
Wants=local-fs.target
PartOf=wg-quick.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/bin/wg-quick down bt-vpn
ExecStart=/usr/bin/wg-quick up bt-vpn
ExecStop=/usr/bin/wg-quick down bt-vpn
ExecReload=/bin/bash -c 'exec /usr/bin/wg-quick down bt-vpn; exec /usr/bin/wg-quick up bt-vpn'
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity

[Install]
WantedBy=multi-user.target

EOF

# ── Reload & enable ───────────────────────────────────────────────────────────
info "Reloading systemd daemon..."
systemctl daemon-reload

sudo systemctl enable --now wg-bt.service

# ── Status summary ────────────────────────────────────────────────────────────
echo
info "Done. Unit status:"
echo
systemctl status "${SERVICE_NAME}.service" --no-pager -l || true

echo
info "Useful commands:"
echo "  systemctl status  ${SERVICE_NAME}.service"
echo "  journalctl -u     ${SERVICE_NAME}.service -f"
echo "  systemctl stop    ${SERVICE_NAME}.service   # brings wg down"
