#!/usr/bin/env bash
# setup.sh — Run once on a fresh Oracle Cloud ARM Ubuntu instance.
# Installs Docker, configures firewall, creates swap, sets up data dir.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash scripts/setup.sh"

# ── 1. System update ────────────────────────────────────────────
info "Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget git ufw iptables-persistent \
  ca-certificates gnupg lsb-release

# ── 2. Swap memory (recommended: 4 GB for ARM Free Tier) ────────
SWAP_FILE=/swapfile
if [[ ! -f "$SWAP_FILE" ]]; then
  info "Creating 4 GB swap file..."
  fallocate -l 4G "$SWAP_FILE"
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"
  echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
  sysctl vm.swappiness=10
  echo "vm.swappiness=10" >> /etc/sysctl.conf
  info "Swap created and enabled."
else
  warn "Swap file already exists — skipping."
fi

# ── 3. Docker installation ───────────────────────────────────────
if command -v docker &>/dev/null; then
  warn "Docker already installed ($(docker --version)). Skipping."
else
  info "Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker
  info "Docker installed: $(docker --version)"
fi

# ── 4. Add current user to docker group (if not root) ───────────
SUDO_USER="${SUDO_USER:-}"
if [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
  usermod -aG docker "$SUDO_USER"
  info "Added $SUDO_USER to docker group. Log out and back in to apply."
fi

# ── 5. n8n data directory ────────────────────────────────────────
info "Creating /opt/n8n/data with correct permissions..."
mkdir -p /opt/n8n/data
# UID 1000 = node user inside the n8n container
chown -R 1000:1000 /opt/n8n/data
chmod 755 /opt/n8n/data

# ── 6. Firewall (UFW + Oracle iptables fix) ──────────────────────
info "Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment "SSH"
ufw allow 80/tcp    comment "HTTP"
ufw allow 443/tcp   comment "HTTPS"
# Port 5678 is intentionally NOT opened publicly.
# Nginx acts as reverse proxy and handles external traffic.
ufw --force enable

# Oracle Cloud injects iptables rules that block traffic even when
# UFW is configured correctly. The fix below preserves rules across reboots.
info "Patching Oracle iptables rules..."
iptables -I INPUT -p tcp --dport 80  -j ACCEPT
iptables -I INPUT -p tcp --dport 443 -j ACCEPT
netfilter-persistent save

info ""
info "╔══════════════════════════════════════════════════════╗"
info "║  Setup complete! Next steps:                         ║"
info "║  1. Copy .env and fill in your values                ║"
info "║     cp .env .env  # edit N8N_HOST, passwords etc.   ║"
info "║  2. Run:  sudo bash scripts/deploy.sh                ║"
info "╚══════════════════════════════════════════════════════╝"
