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

For developing for BlackTorch, run setup_host.sh

```bash
curl -fsSL https://raw.githubusercontent.com/BlackTorch-s-r-o/btsetup/main/setup_hosts.sh | bash
```

## Scripts

- `install-git-deploy-repo.sh` - Git configuration and SSH key setup

- `setup_hosts.sh` - Setups DNS in /etc/hosts for dev infra

---

**BlackTorch s.r.o.** - Surveillance systems