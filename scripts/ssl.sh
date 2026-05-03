#!/usr/bin/env bash
# ssl.sh — Install Nginx + Certbot and configure HTTPS reverse proxy for n8n.
# Run AFTER deploy.sh when n8n is already running on localhost:5678.
# Usage: sudo bash scripts/ssl.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash scripts/ssl.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ ! -f "$REPO_ROOT/.env" ]] && error ".env not found at $REPO_ROOT/.env"
source "$REPO_ROOT/.env"
[[ -z "${N8N_HOST:-}" ]] && error "N8N_HOST is empty in .env — set it to your domain (e.g. n8n.yourdomain.com)"

DOMAIN="$N8N_HOST"
EMAIL="${CERTBOT_EMAIL:-}"   # Optional: set CERTBOT_EMAIL in .env for renewal notifications

# ── 1. Install Nginx + Certbot ───────────────────────────────────
info "Installing Nginx and Certbot..."
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx

systemctl enable nginx
systemctl start nginx

# ── 2. Temporary HTTP config (needed for ACME challenge) ─────────
info "Writing temporary Nginx HTTP config for $DOMAIN..."
CONF="/etc/nginx/sites-available/$DOMAIN"

cat > "$CONF" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    # Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

ln -sf "$CONF" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ── 3. Obtain SSL certificate ────────────────────────────────────
info "Obtaining SSL certificate for $DOMAIN via Let's Encrypt..."
CERTBOT_FLAGS="--nginx -d $DOMAIN --non-interactive --agree-tos"
if [[ -n "$EMAIL" ]]; then
  CERTBOT_FLAGS="$CERTBOT_FLAGS --email $EMAIL"
else
  CERTBOT_FLAGS="$CERTBOT_FLAGS --register-unsafely-without-email"
fi
# shellcheck disable=SC2086
certbot $CERTBOT_FLAGS

# ── 4. Full HTTPS reverse proxy config ──────────────────────────
info "Writing final HTTPS Nginx config..."
cat > "$CONF" <<EOF
# Redirect HTTP → HTTPS
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-XSS-Protection "1; mode=block" always;

    # n8n reverse proxy
    location / {
        proxy_pass         http://127.0.0.1:5678;
        proxy_http_version 1.1;

        # WebSocket support (required for n8n editor)
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
        client_max_body_size 50m;
    }
}
EOF

nginx -t && systemctl reload nginx

# ── 5. Auto-renewal cron (certbot timer already installed; verify)
info "Verifying Certbot auto-renewal..."
systemctl is-enabled certbot.timer &>/dev/null \
  && info "certbot.timer is active — certificates will renew automatically." \
  || { warn "certbot.timer not found — adding cron fallback..."; echo "0 3 * * * root certbot renew --quiet && systemctl reload nginx" >> /etc/cron.d/certbot-renew; }

info ""
info "╔══════════════════════════════════════════════════════════╗"
info "║  HTTPS is configured!                                    ║"
info "║                                                          ║"
info "║  n8n is now available at: https://${DOMAIN}             ║"
info "║                                                          ║"
info "║  Verify SSL:  curl -I https://${DOMAIN}                 ║"
info "╚══════════════════════════════════════════════════════════╝"
