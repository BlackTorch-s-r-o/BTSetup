#!/bin/bash

# WireGuard Key Generation Script
# Creates and manages WireGuard key pairs in ~/.wireguard/

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Key directory
KEY_DIR="$HOME/.wireguard"

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if wireguard-tools is installed
if ! command -v wg &> /dev/null; then
    print_error "WireGuard tools (wg) not found!"
    echo "Please install wireguard-tools:"
    echo "  Ubuntu/Debian: sudo apt install wireguard-tools"
    echo "  macOS: brew install wireguard-tools"
    exit 1
fi

# Create directory if it doesn't exist
if [ ! -d "$KEY_DIR" ]; then
    print_info "Creating directory: $KEY_DIR"
    mkdir -p "$KEY_DIR"
    chmod 700 "$KEY_DIR"
    print_success "Directory created with secure permissions (700)"
fi

# Ask for key name
echo ""
read -p "Enter a name for this key pair (e.g., laptop, phone, server1): " KEY_NAME

# Validate key name
if [ -z "$KEY_NAME" ]; then
    print_error "Key name cannot be empty!"
    exit 1
fi

# Remove any spaces and special characters for safety
KEY_NAME=$(echo "$KEY_NAME" | tr -cd '[:alnum:]-_')

PRIVATE_KEY="$KEY_DIR/${KEY_NAME}-private.key"
PUBLIC_KEY="$KEY_DIR/${KEY_NAME}-public.key"

# Check if keys with this name already exist
if [ -f "$PRIVATE_KEY" ] && [ -f "$PUBLIC_KEY" ]; then
    print_warning "Keys with name '$KEY_NAME' already exist!"
    echo ""
    echo "Existing public key:"
    echo "-------------------"
    cat "$PUBLIC_KEY"
    echo "-------------------"
    echo ""
    
    read -p "Do you want to overwrite these keys? (y/N): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Keeping existing keys. Exiting."
        exit 0
    fi
    
    print_warning "Generating new keys (old keys will be overwritten)..."
elif [ -f "$PRIVATE_KEY" ] || [ -f "$PUBLIC_KEY" ]; then
    print_warning "Incomplete key pair found! Only one of the keys exists."
    print_info "Will create a complete new key pair..."
fi

# Generate new keys
print_info "Generating WireGuard key pair..."

# Set umask to ensure secure permissions
umask 077

# Generate private key and derive public key
wg genkey > "$PRIVATE_KEY"
wg pubkey < "$PRIVATE_KEY" > "$PUBLIC_KEY"

# Ensure proper permissions
chmod 600 "$PRIVATE_KEY"
chmod 644 "$PUBLIC_KEY"

print_success "Keys generated successfully!"
echo ""
echo "Key name:     $KEY_NAME"
echo "Key location: $KEY_DIR"
echo "Private key:  $PRIVATE_KEY (keep this secret!)"
echo "Public key:   $PUBLIC_KEY"
echo ""
echo "Your PUBLIC key (share this with the server):"
echo "=============================================="
cat "$PUBLIC_KEY"
echo "=============================================="
echo ""
print_info "Your private key is stored securely at: $PRIVATE_KEY"
print_warning "Never share your private key with anyone!"
echo ""
print_info "To list all your keys: ls -lh $KEY_DIR"