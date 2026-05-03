# n8n Oracle Cloud Self-Host — Claude.md

> This file is the **brain of the project**. It explains everything: architecture,
> deployment steps, configuration decisions, security, and troubleshooting.
> Read it top-to-bottom before touching anything else.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Oracle Cloud Setup](#2-oracle-cloud-setup)
3. [SSH Connection](#3-ssh-connection)
4. [Security Hardening (Before Deployment)](#4-security-hardening-before-deployment)
5. [Repository Structure](#5-repository-structure)
6. [Step-by-Step Deployment](#6-step-by-step-deployment)
7. [docker-compose.yml Explained](#7-docker-composeyml-explained)
8. [Environment Variables Explained](#8-environment-variables-explained)
9. [Ports Explained](#9-ports-explained)
10. [HTTPS Setup (Nginx + Certbot)](#10-https-setup-nginx--certbot)
11. [Backup Strategy](#11-backup-strategy)
12. [Troubleshooting](#12-troubleshooting)
13. [Scaling (Postgres + Queue Mode)](#13-scaling-postgres--queue-mode)
14. [Oracle Free Tier Limits](#14-oracle-free-tier-limits)

---

## 1. Architecture Overview

### Simple Architecture (Default — What This Repo Deploys)

```
Internet
    │
    ▼
Oracle Cloud VM (ARM A1, Ubuntu 22.04)
    │
    ├── UFW Firewall (ports 22, 80, 443 open; 5678 blocked externally)
    │
    ├── Nginx (reverse proxy on :80 and :443)
    │       └── proxies to → localhost:5678
    │
    └── Docker
            └── n8n container (:5678, localhost only)
                    └── SQLite database (in named Docker volume)
```

**Why Nginx in front of n8n?**
- n8n does not natively terminate TLS. Nginx handles SSL and forwards plain HTTP.
- Nginx adds security headers and rate limiting without modifying n8n.
- Port 5678 stays internal — only Nginx is publicly reachable.

### Optional Advanced Architecture

```
Internet
    │
    ▼
Oracle Cloud VM
    │
    ├── Nginx (:443)
    │
    └── Docker Compose
            ├── n8n (worker mode, :5678)
            ├── n8n (webhook processor)
            ├── PostgreSQL (persistent relational DB)
            └── Redis (queue for execution jobs)
```

This advanced setup is covered in [Section 13](#13-scaling-postgres--queue-mode).

---

## 2. Oracle Cloud Setup

### 2.1 Create a Free Tier Account

1. Go to https://cloud.oracle.com and create a free account.
2. Use a valid credit card (you will not be charged for Always Free resources).
3. Choose your **home region** carefully — it cannot be changed later.
   - Recommended: pick the region closest to your users.

### 2.2 Create the ARM VM Instance

1. In the OCI console, navigate to **Compute → Instances → Create Instance**.
2. **Name**: `n8n-server` (or any name you prefer).
3. **Image**: Ubuntu 22.04 (Minimal) — Canonical.
4. **Shape**:
   - Click **Change Shape**.
   - Select **Ampere** (ARM-based).
   - Shape: `VM.Standard.A1.Flex`.
   - **OCPUs**: 2–4 (Free Tier allows up to 4 total across all A1 instances).
   - **Memory**: 12–24 GB (Free Tier allows up to 24 GB total).
5. **Networking**: Use the default VCN or create one — keep defaults.
6. **SSH Keys**: Upload your **public** key (`.pub` file).
   - If you don't have one: `ssh-keygen -t ed25519 -C "your@email.com"`
   - Your public key is at `~/.ssh/id_ed25519.pub`
7. **Boot Volume**: 50 GB is sufficient. (Free Tier: up to 200 GB total block storage.)
8. Click **Create**. Wait ~2 minutes for provisioning.

### 2.3 Get the Public IP Address

After the instance is Running, copy the **Public IP address** shown in the instance details page.

### 2.4 Open Ports in the Oracle VCN Security List

Oracle Cloud has **two layers of firewall**: the VCN Security List (cloud-level) AND the OS firewall (UFW). Both must allow traffic.

1. In the instance details, click on your **Subnet** → **Security List**.
2. Under **Ingress Rules**, add:

| Stateless | Source CIDR | IP Protocol | Port Range | Description      |
|-----------|-------------|-------------|------------|------------------|
| No        | 0.0.0.0/0   | TCP         | 22         | SSH              |
| No        | 0.0.0.0/0   | TCP         | 80         | HTTP             |
| No        | 0.0.0.0/0   | TCP         | 443        | HTTPS            |

> **Do NOT add port 5678** to the VCN rules. It should only be accessible via Nginx.

### 2.5 Point Your Domain to the VM

In your DNS provider (Cloudflare, Route53, etc.), add an **A record**:

```
Type: A
Name: n8n          (or @ for root domain)
Value: <VM Public IP>
TTL: 300 (auto)
```

Wait 1–5 minutes for DNS propagation. Verify with:
```bash
dig n8n.yourdomain.com +short
# Should return your VM IP
```

---

## 3. SSH Connection

### First Connection

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<VM_PUBLIC_IP>
```

- Default username for Oracle Ubuntu images is `ubuntu`.
- Accept the host key fingerprint on first connect.

### Recommended: SSH Config Entry

Add to `~/.ssh/config` on your local machine:

```
Host n8n-oracle
    HostName <VM_PUBLIC_IP>
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
```

Then connect with just: `ssh n8n-oracle`

### Copy Files to the Server

```bash
# Copy the entire repo to the server
scp -r . ubuntu@<VM_PUBLIC_IP>:~/n8n-oracle-cloud-selfhost/

# Or clone directly on the server:
git clone https://github.com/pankajAdhikari2002/n8n-oracle-cloud-selfhost.git
```

---

## 4. Security Hardening (Before Deployment)

### 4.1 Disable Password SSH Login

Password-based SSH login is a major attack surface. Disable it immediately after key-based login is confirmed working.

```bash
# On the VM, edit the SSH daemon config
sudo nano /etc/ssh/sshd_config
```

Find and set these lines (add them if missing):
```
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
MaxAuthTries 3
```

Restart SSH:
```bash
sudo systemctl restart sshd
```

> **Test** your key login in a **new terminal** before closing the current session.

### 4.2 Keep System Updated

```bash
sudo apt-get update && sudo apt-get upgrade -y
# Set up automatic security updates (optional but recommended):
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

### 4.3 Use a Strong Basic Auth Password

When filling in `.env`, use a password with 20+ characters. A strong password prevents brute-force access to the n8n editor.

```bash
# Generate a strong password:
openssl rand -base64 24
```

---

## 5. Repository Structure

```
.
├── claude.md              ← You are here (project brain)
├── docker-compose.yml     ← Defines the n8n Docker stack
├── .env                   ← Your local config (never commit this)
├── .env.example           ← Template — copy to .env and fill in
├── .gitignore             ← Keeps .env out of git
├── README.md              ← Quick-start guide
└── scripts/
    ├── setup.sh           ← One-time server setup (Docker, firewall, swap)
    ├── deploy.sh          ← Start/update n8n
    └── ssl.sh             ← Install Nginx + Certbot HTTPS
```

---

## 6. Step-by-Step Deployment

Follow these steps **in order**.

### Step 1 — Provision VM & open VCN ports (Section 2)

### Step 2 — SSH into the VM

```bash
ssh ubuntu@<VM_PUBLIC_IP>
```

### Step 3 — Clone the repo

```bash
git clone https://github.com/pankajAdhikari2002/n8n-oracle-cloud-selfhost.git
cd n8n-oracle-cloud-selfhost
```

### Step 4 — Create your .env file

```bash
cp .env.example .env
nano .env
```

Fill in every variable. Minimum required:
```
N8N_HOST=n8n.yourdomain.com
WEBHOOK_URL=https://n8n.yourdomain.com/
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=<strong-password>
TZ=Asia/Kolkata
```

### Step 5 — Run setup.sh (one time only)

```bash
sudo bash scripts/setup.sh
```

This installs Docker, creates swap, configures UFW, and sets up the data directory. Takes ~3 minutes.

### Step 6 — Run deploy.sh

```bash
bash scripts/deploy.sh
```

n8n will start and the script will wait until it is healthy.

### Step 7 — Verify n8n is running

```bash
# Should return HTTP 200
curl -s -o /dev/null -w "%{http_code}" http://localhost:5678/healthz

# View running containers
docker ps

# View logs
docker compose logs -f n8n
```

### Step 8 — Set up HTTPS (recommended)

```bash
sudo bash scripts/ssl.sh
```

This installs Nginx, gets a free SSL cert from Let's Encrypt, and configures the reverse proxy.

### Step 9 — Open n8n in your browser

```
https://n8n.yourdomain.com
```

Log in with your `N8N_BASIC_AUTH_USER` and `N8N_BASIC_AUTH_PASSWORD`.

---

## 7. docker-compose.yml Explained

```yaml
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
```
Always pulls from n8n's official registry. Uses `latest` for simplicity; pin to a specific version (e.g., `1.40.0`) for a more stable production deployment.

```yaml
    restart: unless-stopped
```
The container automatically restarts if it crashes or if the VM reboots. `unless-stopped` means it won't restart if you manually stop it with `docker compose down`.

```yaml
    ports:
      - "127.0.0.1:5678:5678"
```
Binds n8n **only to localhost**. External traffic cannot reach port 5678 directly — it must go through Nginx. This is a critical security decision.

```yaml
    volumes:
      - n8n_data:/home/node/.n8n
```
All n8n data (workflows, credentials, execution history) is stored in a named Docker volume. This data **persists across container restarts and updates**.

```yaml
    user: "node"
```
Runs n8n as a non-root user inside the container — a security best practice.

```yaml
    healthcheck:
```
Docker will periodically call `/healthz` to verify n8n is running. If it fails repeatedly, Docker can restart the container automatically.

---

## 8. Environment Variables Explained

| Variable                  | Required | Description                                                                 |
|---------------------------|----------|-----------------------------------------------------------------------------|
| `N8N_HOST`                | Yes      | Your domain (e.g. `n8n.yourdomain.com`). Used in URLs n8n generates.       |
| `N8N_PROTOCOL`            | Yes      | `https` for production, `http` for local testing only.                     |
| `WEBHOOK_URL`             | Yes      | Full URL including trailing slash: `https://n8n.yourdomain.com/`           |
| `N8N_BASIC_AUTH_ACTIVE`   | Yes      | `true` enables password protection on the editor. Never set to `false`.    |
| `N8N_BASIC_AUTH_USER`     | Yes      | Username for the editor login prompt.                                       |
| `N8N_BASIC_AUTH_PASSWORD` | Yes      | Password for the editor. Use 20+ character random string.                  |
| `TZ`                      | Yes      | Timezone for workflow scheduling (e.g. `Asia/Kolkata`, `UTC`, `US/Eastern`)|
| `GENERIC_TIMEZONE`        | Auto     | Set from `TZ` automatically in docker-compose.yml.                         |
| `N8N_DIAGNOSTICS_ENABLED` | No       | `false` disables telemetry sent to n8n.io.                                 |
| `EXECUTIONS_DATA_PRUNE`   | No       | `true` enables automatic cleanup of old execution logs.                    |
| `EXECUTIONS_DATA_MAX_AGE` | No       | How many hours to keep execution logs (default: 168 = 7 days).             |

---

## 9. Ports Explained

| Port | Direction | Purpose                              | Opened in VCN? | Opened in UFW? |
|------|-----------|--------------------------------------|----------------|----------------|
| 22   | Inbound   | SSH remote access                    | Yes            | Yes            |
| 80   | Inbound   | HTTP (redirects to HTTPS via Nginx)  | Yes            | Yes            |
| 443  | Inbound   | HTTPS (Nginx → n8n proxy)            | Yes            | Yes            |
| 5678 | Internal  | n8n editor/API (localhost only)      | **No**         | **No**         |

Port 5678 is **never** opened to the internet. All external traffic enters via Nginx on 443.

---

## 10. HTTPS Setup (Nginx + Certbot)

The `scripts/ssl.sh` script handles everything automatically, but here is what it does step by step:

### What ssl.sh does

1. **Installs Nginx** — the web server that will proxy requests to n8n.
2. **Writes a temporary HTTP config** — needed for Let's Encrypt to verify you own the domain.
3. **Runs Certbot** — contacts Let's Encrypt and downloads a free 90-day SSL certificate.
4. **Writes the final HTTPS config** — full reverse proxy with security headers and WebSocket support.
5. **Sets up auto-renewal** — Certbot's systemd timer renews the cert before it expires.

### WebSocket Support

n8n's editor uses WebSockets for real-time updates. The Nginx config includes:
```nginx
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection "upgrade";
```
Without these, the editor will appear to load but feel broken (no live updates).

### Manual Certificate Renewal

```bash
sudo certbot renew --dry-run   # Test renewal without actually renewing
sudo certbot renew             # Force renew now
```

---

## 11. Backup Strategy

### What to Back Up

All n8n state lives in the Docker named volume `n8n_data`, which maps to `/home/node/.n8n` inside the container. This contains:
- `database.sqlite` — all workflows, credentials, execution history
- `config` — n8n configuration

### Manual Backup

```bash
# Create a timestamped tar archive of the n8n volume
docker run --rm \
  -v n8n_data:/data \
  -v $(pwd):/backup \
  alpine \
  tar czf /backup/n8n-backup-$(date +%Y%m%d-%H%M%S).tar.gz -C /data .

# Verify the backup
ls -lh n8n-backup-*.tar.gz
```

### Automated Daily Backup (Cron)

```bash
# Add to root's crontab: sudo crontab -e
0 2 * * * docker run --rm -v n8n_data:/data -v /opt/n8n/backups:/backup alpine tar czf /backup/n8n-backup-$(date +\%Y\%m\%d).tar.gz -C /data . && find /opt/n8n/backups -name "*.tar.gz" -mtime +7 -delete
```

This runs at 2 AM daily, backs up n8n data, and deletes backups older than 7 days.

### Restore from Backup

```bash
# Stop n8n first
docker compose down

# Restore the volume
docker run --rm \
  -v n8n_data:/data \
  -v $(pwd):/backup \
  alpine \
  sh -c "cd /data && tar xzf /backup/n8n-backup-YYYYMMDD-HHMMSS.tar.gz"

# Restart n8n
docker compose up -d
```

---

## 12. Troubleshooting

### n8n container keeps restarting

```bash
# Check container status and recent exit codes
docker ps -a

# Check logs for errors
docker compose logs --tail=100 n8n

# Common causes:
# - .env variables are empty or malformed
# - /home/node/.n8n permission issues inside volume
# - Port 5678 already in use by another process
```

### Cannot reach n8n on port 5678 from browser

Port 5678 is intentionally blocked externally. Access n8n through:
- `https://yourdomain.com` (after SSL setup)
- SSH tunnel: `ssh -L 5678:localhost:5678 ubuntu@<IP>` → then open `http://localhost:5678`

### Nginx returns 502 Bad Gateway

```bash
# Is n8n running?
docker ps | grep n8n

# Is n8n listening on 5678?
ss -tlnp | grep 5678

# Check n8n logs
docker compose logs --tail=50 n8n

# Check Nginx error log
sudo tail -50 /var/log/nginx/error.log
```

### SSL certificate errors

```bash
# Check certificate expiry
sudo certbot certificates

# Force renewal
sudo certbot renew --force-renewal

# Test Nginx config
sudo nginx -t
```

### Oracle iptables blocking traffic (common issue)

Oracle Cloud injects iptables rules on the VM that can block traffic even when UFW is configured correctly. Fix:

```bash
sudo iptables -I INPUT -p tcp --dport 80  -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 22  -j ACCEPT
sudo netfilter-persistent save
```

Then also verify the **VCN Security List** (cloud-level firewall) has the correct ingress rules — see Section 2.4.

### n8n editor loads but webhooks don't fire

```bash
# Check WEBHOOK_URL in .env — must be the full public URL with trailing slash
WEBHOOK_URL=https://n8n.yourdomain.com/

# Verify the domain resolves to your VM
curl -I https://n8n.yourdomain.com/webhook-test/test

# Check n8n logs for webhook errors
docker compose logs -f n8n | grep -i webhook
```

### Out of memory

```bash
# Check memory usage
free -h
docker stats n8n

# If swap is not active:
sudo swapon /swapfile
# If /swapfile doesn't exist, re-run setup.sh
```

### Update n8n to latest version

```bash
# Pull latest image and restart
bash scripts/deploy.sh
# deploy.sh runs "docker compose pull" before starting
```

---

## 13. Scaling (Postgres + Queue Mode)

The default SQLite setup works well for personal use and small teams (up to ~10 active workflows, light load).

For heavier workloads, migrate to **PostgreSQL** as the backend and enable **Queue Mode** (Redis-backed job queue).

### Switch to PostgreSQL

1. Uncomment the `db` service in `docker-compose.yml`.
2. Add these environment variables to the `n8n` service in `docker-compose.yml`:
   ```yaml
   - DB_TYPE=postgresdb
   - DB_POSTGRESDB_HOST=db
   - DB_POSTGRESDB_PORT=5432
   - DB_POSTGRESDB_DATABASE=${POSTGRES_DB:-n8n}
   - DB_POSTGRESDB_USER=${POSTGRES_USER:-n8n}
   - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
   ```
3. Add `POSTGRES_PASSWORD` to `.env`.
4. Restart: `bash scripts/deploy.sh`

### Enable Queue Mode (for parallel execution)

Queue mode allows multiple n8n workers to process executions in parallel using Redis.

```yaml
# Add to n8n service environment:
- EXECUTIONS_MODE=queue
- QUEUE_BULL_REDIS_HOST=redis
- QUEUE_HEALTH_CHECK_ACTIVE=true

# Add a Redis service:
redis:
  image: redis:7-alpine
  restart: unless-stopped
  volumes:
    - redis_data:/data
```

Queue mode requires PostgreSQL (not SQLite).

---

## 14. Oracle Free Tier Limits

Oracle Always Free Tier (as of 2024) includes:

| Resource           | Limit                                          |
|--------------------|------------------------------------------------|
| ARM (A1) Instances | Up to 4 OCPUs and 24 GB RAM total              |
| AMD (E2) Instances | 2 × VM.Standard.E2.1.Micro (1 OCPU, 1 GB RAM) |
| Block Storage      | 200 GB total                                   |
| Outbound Bandwidth | 10 TB/month                                    |
| Load Balancers     | 1 × 10 Mbps (flexible)                         |

**Recommended ARM shape for n8n:**
- 2 OCPUs + 12 GB RAM — handles n8n comfortably with room for other processes
- 4 OCPUs + 24 GB RAM — maximum free; run n8n + Postgres + other services

**Important:** The Always Free tier is permanent as long as your account remains active and you don't upgrade to a paid account. Paid accounts lose Always Free status if the resources are upgraded beyond the limits.

---

*Last updated: 2025 | Based on n8n >= 1.0 | Oracle Cloud Ubuntu 22.04 ARM*
