#!/bin/bash
GREEN='\033[0;32m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[BTEntry]${NC} $1"; }

HOSTS_FILE="/etc/hosts"
MARKER="# BlackTorch Development Hosts"

log_info "Setting up BlackTorch development DNS entries..."

# Check if we're running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    log_info "This script requires sudo privileges to modify /etc/hosts"
    exit 1
fi

# Remove old BlackTorch entries if they exist
if grep -q "$MARKER" "$HOSTS_FILE"; then
    log_info "Removing existing BlackTorch entries..."
    sed -i "/$MARKER/,+2d" "$HOSTS_FILE"
fi

# Add new entries
log_info "Adding BlackTorch DNS entries to /etc/hosts..."
cat >> "$HOSTS_FILE" << EOF
$MARKER
100.64.0.1    hub.blacktorch.test
100.64.0.2    site.blacktorch.test
EOF

log_info "DNS setup completed! The following domains are now configured:"
log_info "  hub.blacktorch.test  -> 100.64.0.1"
log_info "  site.blacktorch.test -> 100.64.0.2"
