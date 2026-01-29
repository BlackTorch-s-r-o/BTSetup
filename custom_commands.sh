#!/bin/bash

# Install devnet command
# Usage: sudo ./install-devnet-command.sh

set -e

INTERFACE="devnet"
SCRIPT_PATH="/usr/local/bin/devnet"

if [ "$EUID" -ne 0 ]; then 
    echo "ERROR: Please run as root (use sudo)"
    exit 1
fi

echo "Installing devnet command..."

# Create the script
cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash

INTERFACE="devnet"

case "$1" in
    up)
        wg-quick up "$INTERFACE"
        ;;
    down)
        wg-quick down "$INTERFACE"
        ;;
    status)
        wg show "$INTERFACE"
        ;;
    restart)
        wg-quick down "$INTERFACE" 2>/dev/null || true
        wg-quick up "$INTERFACE"
        ;;
    *)
        echo "Usage: devnet {up|down|status|restart}"
        exit 1
        ;;
esac
EOF

# Make it executable
chmod +x "$SCRIPT_PATH"
echo "✓ Script created at $SCRIPT_PATH"

# Add sudo rule for passwordless execution
SUDOERS_FILE="/etc/sudoers.d/devnet"
echo "Adding sudoers rule..."

cat > "$SUDOERS_FILE" << EOF
# Allow wg-quick commands without password for devnet interface
%sudo ALL=(ALL) NOPASSWD: /usr/bin/wg-quick up devnet
%sudo ALL=(ALL) NOPASSWD: /usr/bin/wg-quick down devnet
%sudo ALL=(ALL) NOPASSWD: /usr/bin/wg show devnet
EOF

chmod 440 "$SUDOERS_FILE"
echo "✓ Sudoers rule added"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "You can now use:"
echo "  sudo devnet up       - Bring up the VPN"
echo "  sudo devnet down     - Bring down the VPN"
echo "  sudo devnet status   - Show VPN status"
echo "  sudo devnet restart  - Restart the VPN"
echo ""