#!/bin/bash

# Install devnet command
# Usage: sudo ./install-devnet-command.sh

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (use sudo)"
    exit 1
fi

read -r -p "Enter WireGuard interface name [devnet]: " INTERFACE < /dev/tty
INTERFACE="${INTERFACE:-devnet}"
SCRIPT_PATH="/usr/local/bin/$INTERFACE"

echo "Installing $INTERFACE command..."

# Create the script
cat > "$SCRIPT_PATH" << EOF
#!/bin/bash

INTERFACE="$INTERFACE"

case "\$1" in
    up)
        wg-quick up "\$INTERFACE"
        ;;
    down)
        wg-quick down "\$INTERFACE"
        ;;
    status)
        wg show "\$INTERFACE"
        ;;
    restart)
        wg-quick down "\$INTERFACE" 2>/dev/null || true
        wg-quick up "\$INTERFACE"
        ;;
    *)
        echo "Usage: $INTERFACE {up|down|status|restart}"
        exit 1
        ;;
esac
EOF

# Make it executable
chmod +x "$SCRIPT_PATH"
echo "✓ Script created at $SCRIPT_PATH"

# Add sudo rule for passwordless execution
SUDOERS_FILE="/etc/sudoers.d/$INTERFACE"
echo "Adding sudoers rule..."

cat > "$SUDOERS_FILE" << EOF
# Allow wg-quick commands without password for $INTERFACE interface
%sudo ALL=(ALL) NOPASSWD: /usr/bin/wg-quick up $INTERFACE
%sudo ALL=(ALL) NOPASSWD: /usr/bin/wg-quick down $INTERFACE
%sudo ALL=(ALL) NOPASSWD: /usr/bin/wg show $INTERFACE
EOF

chmod 440 "$SUDOERS_FILE"
echo "✓ Sudoers rule added"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "You can now use:"
echo "  sudo $INTERFACE up       - Bring up the VPN"
echo "  sudo $INTERFACE down     - Bring down the VPN"
echo "  sudo $INTERFACE status   - Show VPN status"
echo "  sudo $INTERFACE restart  - Restart the VPN"
echo ""