#!/bin/bash

# Installation script for ping-monitor service
# Usage: sudo ./install-ping-monitor.sh [target_ip] [interface] [interval]

set -e  # Exit on error

# Configuration (can be overridden by command line arguments)
TARGET_IP="${1:-10.7.0.1}"
INTERFACE="${2:-devnet}"
INTERVAL="${3:-30}"

SCRIPT_PATH="/usr/local/bin/ping-monitor.sh"
SERVICE_PATH="/etc/systemd/system/ping-monitor.service"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "ERROR: Please run as root (use sudo)"
    exit 1
fi

echo "=== Ping Monitor Installation ==="
echo "Target IP: $TARGET_IP"
echo "Interface: $INTERFACE"
echo "Interval: $INTERVAL seconds"
echo ""

# Check if interface exists
if ! ip link show "$INTERFACE" &> /dev/null; then
    echo "WARNING: Interface '$INTERFACE' not found. Service will wait for it to appear."
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Stop service if it's running
if systemctl is-active --quiet ping-monitor.service; then
    echo "Stopping existing service..."
    systemctl stop ping-monitor.service
fi

# Create the ping script
echo "Creating ping monitor script at $SCRIPT_PATH..."
cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash

# Configuration
TARGET_IP="TARGET_IP_PLACEHOLDER"
INTERVAL=INTERVAL_PLACEHOLDER

echo "Ping monitor started for $TARGET_IP"

while true; do
    if ping -c 1 -W 2 "$TARGET_IP" > /dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - SUCCESS: $TARGET_IP is reachable"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - FAILED: $TARGET_IP is unreachable"
    fi
    
    sleep "$INTERVAL"
done
EOF

# Replace placeholders
sed -i "s/TARGET_IP_PLACEHOLDER/$TARGET_IP/" "$SCRIPT_PATH"
sed -i "s/INTERVAL_PLACEHOLDER/$INTERVAL/" "$SCRIPT_PATH"

# Make script executable
chmod +x "$SCRIPT_PATH"
echo "✓ Script created and made executable"

# Create the systemd service
echo "Creating systemd service at $SERVICE_PATH..."
cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Network Ping Monitor ($TARGET_IP via $INTERFACE)
After=network-online.target
Wants=network-online.target
BindsTo=sys-subsystem-net-devices-$INTERFACE.device
After=sys-subsystem-net-devices-$INTERFACE.device

[Service]
Type=simple
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "✓ Systemd service created"

# Reload systemd daemon
echo "Reloading systemd daemon..."
systemctl daemon-reload
echo "✓ Systemd daemon reloaded"

# Enable the service
echo "Enabling service to start on boot..."
systemctl enable ping-monitor.service
echo "✓ Service enabled"

# Start the service
echo "Starting service..."
systemctl start ping-monitor.service
echo "✓ Service started"

# Show status
echo ""
echo "=== Installation Complete ==="
echo ""
echo "Service status:"
systemctl status ping-monitor.service --no-pager -l
echo ""
echo "Useful commands:"
echo "  View status:    sudo systemctl status ping-monitor.service"
echo "  View logs:      sudo journalctl -u ping-monitor.service -f"
echo "  Stop service:   sudo systemctl stop ping-monitor.service"
echo "  Restart:        sudo systemctl restart ping-monitor.service"
echo "  Disable:        sudo systemctl disable ping-monitor.service"
echo ""