#!/usr/bin/env bash
# deploy.sh — Start (or update) the n8n stack.
# Run from the repository root: bash scripts/deploy.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Preflight checks ─────────────────────────────────────────────
[[ ! -f ".env" ]] && error ".env file not found. Copy the example: cp .env.example .env and fill in your values."
command -v docker &>/dev/null || error "Docker is not installed. Run: sudo bash scripts/setup.sh"

# Validate critical env vars are not empty
source .env
[[ -z "${N8N_HOST:-}"               ]] && error "N8N_HOST is empty in .env"
[[ -z "${WEBHOOK_URL:-}"            ]] && error "WEBHOOK_URL is empty in .env"
[[ -z "${N8N_BASIC_AUTH_USER:-}"    ]] && error "N8N_BASIC_AUTH_USER is empty in .env"
[[ -z "${N8N_BASIC_AUTH_PASSWORD:-}"]] && error "N8N_BASIC_AUTH_PASSWORD is empty in .env"

# ── Pull latest image ────────────────────────────────────────────
info "Pulling latest n8n image..."
docker compose pull

# ── Start / restart stack ────────────────────────────────────────
info "Starting n8n stack..."
docker compose up -d --remove-orphans

# ── Wait for health ──────────────────────────────────────────────
info "Waiting for n8n to become healthy..."
RETRIES=20
until docker inspect --format='{{.State.Health.Status}}' n8n 2>/dev/null | grep -q "healthy"; do
  RETRIES=$((RETRIES - 1))
  [[ $RETRIES -le 0 ]] && { warn "Health check timed out — showing logs:"; docker compose logs --tail=50 n8n; exit 1; }
  sleep 5
done

# ── Summary ──────────────────────────────────────────────────────
info ""
info "╔══════════════════════════════════════════════════════════╗"
info "║  n8n is running!                                         ║"
info "║                                                          ║"
info "║  Local:   http://localhost:5678                          ║"
info "║  Public:  https://${N8N_HOST}                           ║"
info "║                                                          ║"
info "║  View logs:  docker compose logs -f n8n                  ║"
info "║  Stop:       docker compose down                         ║"
info "║  Update:     bash scripts/deploy.sh  (re-run this)       ║"
info "╚══════════════════════════════════════════════════════════╝"
