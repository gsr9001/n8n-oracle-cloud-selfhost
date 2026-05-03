# n8n on Oracle Cloud Free Tier (ARM)

Self-host [n8n](https://n8n.io) on Oracle Cloud Always Free ARM VM with Docker, Nginx, and Let's Encrypt HTTPS.

## Quick Start

```bash
# 1. Clone
git clone https://github.com/pankajAdhikari2002/n8n-oracle-cloud-selfhost.git
cd n8n-oracle-cloud-selfhost

# 2. Configure
cp .env.example .env
nano .env          # fill in N8N_HOST, WEBHOOK_URL, passwords

# 3. Setup server (once)
sudo bash scripts/setup.sh

# 4. Deploy
bash scripts/deploy.sh

# 5. Enable HTTPS (after pointing your domain to the VM)
sudo bash scripts/ssl.sh
```

Open `https://your-domain.com` → n8n is running.

---

## Architecture

```
Internet → Nginx (:443) → n8n Docker container (:5678, localhost only)
```

- n8n runs in Docker with persistent named volume
- Nginx handles SSL termination and reverse proxying
- Port 5678 is never exposed publicly

## What the Scripts Do

| Script           | Purpose                                              | Run as  |
|------------------|------------------------------------------------------|---------|
| `setup.sh`       | Install Docker, configure firewall, create swap      | root    |
| `deploy.sh`      | Pull latest image, start stack, verify health        | user    |
| `ssl.sh`         | Install Nginx + Certbot, configure HTTPS             | root    |

## Files

```
docker-compose.yml   n8n stack definition
.env                 your local config (never commit)
.env.example         config template
scripts/             automation scripts
claude.md            full architecture + deployment guide
```

## Oracle Cloud Free Tier

- Shape: `VM.Standard.A1.Flex` (Ampere ARM)
- Free: up to 4 OCPUs + 24 GB RAM total
- Recommended: 2 OCPUs + 12 GB RAM for n8n

Open these ports in your **Oracle VCN Security List**:

| Port | Protocol | Purpose  |
|------|----------|----------|
| 22   | TCP      | SSH      |
| 80   | TCP      | HTTP     |
| 443  | TCP      | HTTPS    |

Do **not** open port 5678 — n8n is proxied through Nginx.

## Full Documentation

See [claude.md](claude.md) for:
- Detailed Oracle Cloud VM setup
- SSH hardening guide
- All environment variables explained
- Backup strategy
- Troubleshooting (iptables, 502 errors, webhooks)
- Scaling to Postgres + Queue Mode

## Update n8n

```bash
bash scripts/deploy.sh   # pulls latest image and restarts
```

## Backup n8n Data

```bash
docker run --rm \
  -v n8n_data:/data \
  -v $(pwd):/backup \
  alpine \
  tar czf /backup/n8n-backup-$(date +%Y%m%d).tar.gz -C /data .
```

---

Lightweight self-hosting. No Kubernetes. No complexity. Just Docker + Nginx.
