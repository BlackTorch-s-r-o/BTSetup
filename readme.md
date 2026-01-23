# BlackTorch Setup Scripts

Automated setup scripts for BlackTorch development and deploy.

## Quick Start

On a fresh device with Ubuntu:
```bash
# 1. Setup Git & GitHub SSH access
curl -fsSL https://raw.githubusercontent.com/BlackTorch-s-r-o/btsetup/main/install-git-deploy-repo.sh | bash

# 2. Clone the repo e.g.:
git clone git@github.com:BlackTorch-s-r-o/BTRemoteHTTPSpeaker.git

```

```bash
For developing for BlackTorch:

# 1. Create a wireguard public/private key
curl -fsSL https://raw.githubusercontent.com/BlackTorch-s-r-o/btsetup/main/wg_create_clients.sh | bash

# 2. Append this to the file in /etc/wireguard/<wg_interface>.conf on the VPN server:
[Peer]
PublicKey = abc123def456...  # The output from above
AllowedIPs = <select-some-unused-ipv4>/32

# 3. Create a client config at you host computer in /etc/wireguard (you may need to use sudo du root mode):
[Interface]
PrivateKey = <content-of-private.key-from-client>
Address = <select-some-unused-ipv4>/32
DNS = 1.1.1.1  # Optional

[Peer]
PublicKey = <content-of-server-public.key-from-server>
Endpoint = your-vps-ip:51821 # Or by default 51820
AllowedIPs = 0.0.0.0/0, ::/0  # Route all traffic through VPN
PersistentKeepalive = 25

# 4. Run setup_host.sh to create local DNS
curl -fsSL https://raw.githubusercontent.com/BlackTorch-s-r-o/btsetup/main/setup_hosts.sh | bash

```

## Scripts

- `install-git-deploy-repo.sh` - Git configuration and SSH key setup

- `wg_create_clients.sh` - Manages Wireguard keys for the local mechine

- `setup_hosts.sh` - Creates DNS in /etc/hosts for dev infra

---

**BlackTorch s.r.o.** - Surveillance systems