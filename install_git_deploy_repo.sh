#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

echo "================================================"
echo "  Git & GitHub SSH Setup Script"
echo "================================================"
echo ""

# Fix .ssh ownership and permissions (in case files were created as root)
log_step "Fixing .ssh directory ownership and permissions..."
CURRENT_USER=$(whoami)
sudo chown -R "${CURRENT_USER}:${CURRENT_USER}" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
find "$HOME/.ssh" -type f -name "*.pub" -exec chmod 644 {} \;
find "$HOME/.ssh" -type f ! -name "*.pub" -exec chmod 600 {} \;
log_info "Ownership and permissions fixed for $HOME/.ssh"
echo ""

# Install Git
log_step "Installing Git..."
sudo apt update
sudo apt install -y git
log_info "Git installed successfully"
echo ""

# Configure Git user
log_step "Configuring Git user information..."
echo "Enter your Git username (e.g., 'Ondra' or 'Your Name'):"
read -r GIT_USERNAME < /dev/tty

echo "Enter your Git email (e.g., 'your.email@example.com'):"
read -r GIT_EMAIL < /dev/tty

if [ -z "$GIT_USERNAME" ] || [ -z "$GIT_EMAIL" ]; then
    log_error "Username and email cannot be empty"
    exit 1
fi

git config --global user.name "$GIT_USERNAME"
git config --global user.email "$GIT_EMAIL"

log_info "Git configured with:"
echo "  Username: $GIT_USERNAME"
echo "  Email: $GIT_EMAIL"
echo ""

# Generate SSH key
log_step "Generating SSH key for GitHub..."
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

if [ -f "$SSH_KEY_PATH" ]; then
    log_warn "SSH key already exists at $SSH_KEY_PATH"
    echo "Do you want to use the existing key? (y/n)"
    read -r USE_EXISTING < /dev/tty

    if [[ ! "$USE_EXISTING" =~ ^[Yy]$ ]]; then
        echo "Enter a name for the new key (default: id_ed25519_github):"
        read -r KEY_NAME < /dev/tty
        KEY_NAME=${KEY_NAME:-id_ed25519_github}
        SSH_KEY_PATH="$HOME/.ssh/$KEY_NAME"
    fi
fi

if [ ! -f "$SSH_KEY_PATH" ]; then
    log_info "Creating new SSH key..."
    ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$SSH_KEY_PATH" -N ""
    log_info "SSH key generated at: $SSH_KEY_PATH"
    # Fix permissions on the newly created key
    chmod 600 "$SSH_KEY_PATH"
    chmod 644 "${SSH_KEY_PATH}.pub"
else
    log_info "Using existing SSH key at: $SSH_KEY_PATH"
fi

# Start ssh-agent and add key
log_info "Starting ssh-agent and adding key..."
eval "$(ssh-agent -s)" > /dev/null
ssh-add "$SSH_KEY_PATH" 2>/dev/null || log_warn "Key already added to ssh-agent"

echo ""
log_step "Your SSH public key:"
echo "================================================"
cat "${SSH_KEY_PATH}.pub"
echo "================================================"
echo ""

log_warn "IMPORTANT: Copy the above SSH key and add it to GitHub"
echo ""
echo "To add as a Deploy Key (repo-specific, read-only by default):"
echo "  1. Go to: https://github.com/<your-org>/<your-repo>/settings/keys"
echo "  2. Click 'Add deploy key'"
echo "  3. Paste the key above"
echo "  4. Give it a title (e.g., 'torch-$HOSTNAME')"
echo "  5. Check 'Allow write access' if needed"
echo ""

# Test GitHub connection in a loop
while true; do
    echo "Press Enter once you've added the key to GitHub..."
    read -r < /dev/tty

    log_info "Testing GitHub SSH connection..."

    if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        log_info "GitHub SSH connection successful!"
        echo ""
        break
    else
        log_error "GitHub SSH connection failed"
        echo ""
        echo "Troubleshooting:"
        echo "  - Make sure you copied the ENTIRE key (including ssh-ed25519 and email)"
        echo "  - Verify the key is added to GitHub"
        echo "  - For private repos, use Deploy Keys or add to your account"
        echo ""
        echo "Do you want to:"
        echo "  1. Try again"
        echo "  2. Display the public key again"
        echo "  3. Exit"
        read -r CHOICE < /dev/tty

        case $CHOICE in
            1)
                continue
                ;;
            2)
                echo ""
                cat "${SSH_KEY_PATH}.pub"
                echo ""
                ;;
            3)
                log_warn "Exiting. Run this script again when ready."
                exit 0
                ;;
            *)
                log_warn "Invalid choice, trying connection again..."
                ;;
        esac
    fi
done

# Configure SSH config for GitHub
log_step "Configuring SSH for GitHub..."
SSH_CONFIG="$HOME/.ssh/config"

if grep -q "Host github.com" "$SSH_CONFIG" 2>/dev/null; then
    log_warn "GitHub entry already exists in SSH config — removing old entry..."
    # Remove existing github.com block (handles both HostName variants)
    awk '
        /^Host github\.com/ { skip=1; next }
        skip && /^Host / { skip=0 }
        !skip { print }
    ' "$SSH_CONFIG" > "${SSH_CONFIG}.tmp" && mv "${SSH_CONFIG}.tmp" "$SSH_CONFIG"
fi

log_info "Appending GitHub config (port 443 via ssh.github.com)..."
cat >> "$SSH_CONFIG" << EOF

# GitHub configuration
Host github.com
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile $SSH_KEY_PATH
    IdentitiesOnly yes
EOF

chmod 600 "$SSH_CONFIG"
log_info "SSH config updated"

echo ""
log_info "Setup complete!"
echo ""
log_step "Quick reference:"
echo ""
echo "  Clone the repo:"
echo "    git clone git@github.com:<your-org>/<your-repo>.git"
echo ""
echo "  View Git config:"
echo "    git config --global --list"
echo ""
echo "  View your public key:"
echo "    cat ${SSH_KEY_PATH}.pub"
echo ""
log_info "Happy rest of the setup! 🚀"