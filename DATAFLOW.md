# Data Flow — n8n Oracle Cloud Self-Host

## 1. Traffic Flow (Request → Response)

```
User Browser
     │
     │  HTTPS Request (port 443)
     ▼
Oracle Cloud VCN Security List
     │  (Allows: 22, 80, 443, 5678)
     ▼
Ubuntu VM (140.245.211.246)
     │
     ▼
UFW Firewall
     │  (Allows: 22, 80, 443)
     ▼
Nginx (Reverse Proxy)
     │  :80  → redirects to :443
     │  :443 → terminates SSL → forwards to localhost:5678
     ▼
n8n Docker Container (localhost:5678)
     │
     ▼
SQLite Database (/home/node/.n8n/database.sqlite)
     │  stored in Docker named volume: n8n_data
     ▼
Response travels back the same path to the browser
```

---

## 2. DNS Flow (Domain → IP)

```
User types: https://gsvrn-n8n.duckdns.org
     │
     ▼
DuckDNS DNS Server
     │  resolves domain → 140.245.211.246
     ▼
Oracle Cloud VM Public IP: 140.245.211.246
     │
     ▼
Nginx on the VM
```

---

## 3. SSL/HTTPS Flow

```
Browser connects to gsvrn-n8n.duckdns.org:443
     │
     ▼
Nginx presents SSL Certificate
     │  (issued by Let's Encrypt, stored at:)
     │  /etc/letsencrypt/live/gsvrn-n8n.duckdns.org/fullchain.pem
     ▼
Encrypted tunnel established (TLS 1.2/1.3)
     │
     ▼
Nginx decrypts request → forwards plain HTTP to localhost:5678
     │
     ▼
n8n processes request → returns response
     │
     ▼
Nginx encrypts response → sends back to browser
```

---

## 4. Docker Data Flow

```
docker-compose.yml
     │
     ├── Pulls image: docker.n8n.io/n8nio/n8n:latest
     │
     ├── Port mapping: 127.0.0.1:5678 → container:5678
     │   (localhost only — Nginx is the only entry point)
     │
     ├── Volume mapping: n8n_data → /home/node/.n8n
     │   (all data persists here across restarts)
     │
     └── Env vars from .env:
             N8N_HOST, WEBHOOK_URL, BASIC_AUTH, TZ ...
```

---

## 5. Data Storage Flow

```
n8n Container (/home/node/.n8n/)
     │
     ├── database.sqlite     ← workflows, credentials, executions
     ├── config              ← n8n settings
     └── (encryption keys)  ← credential encryption
     │
     ▼
Docker Named Volume: n8n_data
     │
     ▼
Physical location on VM:
/var/lib/docker/volumes/n8n_data/_data/
```

---

## 6. Script Execution Flow

```
setup.sh (run once)
     │
     ├── apt update + upgrade
     ├── Create 4GB swap (/swapfile)
     ├── Install Docker + Docker Compose
     ├── Create /opt/n8n/data (permissions: UID 1000)
     ├── Configure UFW (allow 22, 80, 443)
     └── Patch Oracle iptables rules

deploy.sh (run to start/update)
     │
     ├── Validate .env values
     ├── docker compose pull (latest image)
     ├── docker compose up -d
     └── Wait for /healthz → 200 OK

ssl.sh (run once for HTTPS)
     │
     ├── Install Nginx + Certbot
     ├── Write temporary HTTP config (for ACME challenge)
     ├── Certbot contacts Let's Encrypt → verifies domain
     ├── Downloads SSL certificate (valid 90 days)
     ├── Write final HTTPS Nginx config (with WebSocket support)
     └── Certbot timer auto-renews before expiry
```

---

## 7. Webhook Flow (n8n Automation)

```
External Service (e.g. GitHub, Stripe, Telegram)
     │
     │  POST https://gsvrn-n8n.duckdns.org/webhook/xxxxx
     ▼
Nginx (port 443)
     ▼
n8n Container (port 5678)
     │
     ├── Triggers workflow
     ├── Executes nodes (HTTP, email, database, etc.)
     └── Returns response to external service
```

---

## 8. Backup Flow

```
n8n_data Docker Volume
     │
     ▼
docker run alpine tar czf
     │
     ▼
n8n-backup-YYYYMMDD.tar.gz  (on VM)
     │
     ▼ (optional: copy to local PC)
scp ubuntu@140.245.211.246:~/n8n-backup-*.tar.gz .
```

---

## 9. Port Summary

```
Internet
  │
  ├── :22  → SSH (admin access only)
  ├── :80  → Nginx (redirects to 443)
  └── :443 → Nginx → n8n (all user traffic)

Internal (not exposed to internet)
  └── :5678 → n8n container (localhost only)
```

---

## 10. Environment Variables Flow

```
.env file (on VM, never committed to git)
     │
     ▼
docker-compose.yml reads .env
     │
     ▼
Passed as environment variables to n8n container:
     │
     ├── N8N_HOST         → n8n knows its public domain
     ├── WEBHOOK_URL      → n8n generates correct webhook URLs
     ├── N8N_PROTOCOL     → https (for correct URL generation)
     ├── N8N_BASIC_AUTH_* → protects editor with login
     ├── TZ               → correct timezone for scheduling
     └── EXECUTIONS_*     → auto-cleanup of old logs
```

---

*Server IP: 140.245.211.246 | Domain: gsvrn-n8n.duckdns.org | Updated: 2026*
