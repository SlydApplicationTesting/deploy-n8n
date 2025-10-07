#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 SLYD LLC
#
# n8n Minimal Bootstrap (Ubuntu 24.04, no Docker, no Nginx/Certbot)
# - Install Node.js 22.x
# - Install n8n (npm -g)
# - Provision PostgreSQL DB/user
# - Create /etc/n8n/n8n.env with minimal vars
# - Create and start systemd service
#
# Endpoints/HTTPS are expected to be handled EXTERNALLY (e.g., Cloudflare Tunnel, ALB, Traefik on another host).
#
# Interactive:
#   sudo bash n8n-bootstrap-min.sh
#
# Non-interactive:
#   sudo bash n8n-bootstrap-min.sh \
#     --non-interactive --yes-sul \
#     --timezone America/New_York \
#     --db-name n8n --db-user n8n --db-pass 'supersecret' \
#     --webhook-url https://n8n.example.com/ \
#     --proxy-hops 1
#
set -euo pipefail

# ---------------- Defaults ----------------
TIMEZONE="${TIMEZONE:-America/New_York}"
DB_NAME="${DB_NAME:-n8n}"
DB_USER="${DB_USER:-n8n}"
DB_PASS="${DB_PASS:-}"
WEBHOOK_URL="${WEBHOOK_URL:-}"     # Optional: set to your external URL, e.g., https://n8n.example.com/
PROXY_HOPS="${PROXY_HOPS:-0}"      # Optional: number of proxies in front of n8n (0 if direct)
YES_SUL="${YES_SUL:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-}"

# ---------------- Helpers ----------------
log() { printf "\033[1;32m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[err]\033[0m %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

require_root() { if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then die "Please run as root (use sudo)."; fi; }

usage() {
  cat <<'USAGE'
Usage:
  sudo bash n8n-bootstrap-min.sh [options]

Options (also support ALL_CAPS env vars):
  --timezone ZONE          IANA TZ (default: America/New_York)
  --db-name NAME           Postgres DB (default: n8n)
  --db-user USER           Postgres user (default: n8n)
  --db-pass PASS           Postgres password (auto-generated if omitted)
  --webhook-url URL        Optional public base URL (e.g., https://n8n.example.com/)
  --proxy-hops N           Optional proxy hops (default: 0)
  --yes-sul                Accept n8n Sustainable Use License
  --non-interactive        Run without prompts (requires --yes-sul)

Examples:
  sudo bash n8n-bootstrap-min.sh --non-interactive --yes-sul \
    --webhook-url https://n8n.example.com/ --proxy-hops 1
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0;;
      --timezone) TIMEZONE="$2"; shift 2;;
      --db-name) DB_NAME="$2"; shift 2;;
      --db-user) DB_USER="$2"; shift 2;;
      --db-pass) DB_PASS="$2"; shift 2;;
      --webhook-url) WEBHOOK_URL="$2"; shift 2;;
      --proxy-hops) PROXY_HOPS="$2"; shift 2;;
      --yes-sul) YES_SUL="yes"; shift 1;;
      --non-interactive) NON_INTERACTIVE="yes"; shift 1;;
      *) err "Unknown argument: $1"; usage; exit 1;;
    esac
  done
}

prompt_if_needed() {
  if [[ -z "${NON_INTERACTIVE:-}" ]]; then
    echo
    echo "This installer will download and configure n8n on THIS server."
    echo "Review n8n’s Sustainable Use License: https://docs.n8n.io/sustainable-use-license/"
    echo "Intended use: internal business. Hosting for third parties may require a separate license."
    echo
    read -r -p "Proceed? (yes/no): " ans
    [[ "$ans" == "yes" ]] || die "Aborted by user."
  else
    [[ "${YES_SUL:-}" == "yes" ]] || die "--non-interactive requires --yes-sul."
  fi

  if [[ -z "${DB_PASS}" && -z "${NON_INTERACTIVE:-}" ]]; then
    read -r -s -p "Postgres password for user '${DB_USER}' (blank to auto-generate): " DB_PASS; echo
  fi
}

generate_random_base64() {
  local bytes="${1:-48}" # 48 bytes -> ~64 base64 chars
  openssl rand -base64 "$bytes" | tr -d '\n' | sed 's/=*$//'
}

main() {
  require_root
  parse_args "$@"
  prompt_if_needed

  # Generate DB_PASS if needed
  if [[ -z "${DB_PASS}" ]]; then
    DB_PASS="$(generate_random_base64 24)"
    log "Generated Postgres password for ${DB_USER}."
  fi

  # Create encryption key (persist)
  if [[ -f /etc/n8n/encryption.key ]]; then
    N8N_ENCRYPTION_KEY="$(cat /etc/n8n/encryption.key)"
  else
    mkdir -p /etc/n8n
    chmod 0755 /etc/n8n
    N8N_ENCRYPTION_KEY="$(generate_random_base64 48)"
    printf "%s\n" "${N8N_ENCRYPTION_KEY}" > /etc/n8n/encryption.key
    chmod 0600 /etc/n8n/encryption.key
  fi

  # Packages
  log "Installing prerequisites and PostgreSQL..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg2 lsb-release \
    build-essential python3 make gcc g++ \
    postgresql postgresql-contrib

  # Node.js 22.x
  if ! command -v node >/dev/null 2>&1; then
    log "Installing Node.js 22.x"
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  else
    log "Node present: $(node -v)"
  fi

  # n8n
  if ! command -v n8n >/dev/null 2>&1; then
    log "Installing n8n globally..."
    npm install -g n8n
  else
    log "n8n already installed."
  fi

  # System user
  if ! id n8n >/dev/null 2>&1; then
    log "Creating system user 'n8n'..."
    useradd -r -m -d /var/lib/n8n -s /usr/sbin/nologin n8n
  fi
  mkdir -p /var/lib/n8n
  chown -R n8n:n8n /var/lib/n8n

  # PostgreSQL
  log "Configuring PostgreSQL..."
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO
\$do\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
      CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';
   END IF;
END
\$do\$;
SQL

  DB_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" || true)
  if [[ "${DB_EXISTS}" != "1" ]]; then
    sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"
  fi

  N8N_HOST="$(hostname -f 2>/dev/null || hostname)"

  # Create env
  log "Writing /etc/n8n/n8n.env ..."
  {
    echo "# SPDX-License-Identifier: Apache-2.0"
    echo "# Copyright (c) 2025 SLYD LLC"
    echo
    echo "N8N_PORT=5678"
    echo "N8N_PROTOCOL=http"
    echo "N8N_HOST=${N8N_HOST}"
    echo "GENERIC_TIMEZONE=${TIMEZONE}"
    if [[ -n "${WEBHOOK_URL}" ]]; then
      echo "WEBHOOK_URL=${WEBHOOK_URL}"
    fi
    echo "N8N_PROXY_HOPS=${PROXY_HOPS}"
    echo "N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}"
    echo "DB_TYPE=postgresdb"
    echo "DB_POSTGRESDB_HOST=127.0.0.1"
    echo "DB_POSTGRESDB_PORT=5432"
    echo "DB_POSTGRESDB_DATABASE=${DB_NAME}"
    echo "DB_POSTGRESDB_USER=${DB_USER}"
    echo "DB_POSTGRESDB_PASSWORD=${DB_PASS}"
    echo "EXECUTIONS_MODE=regular"
    echo "EXECUTIONS_DATA_SAVE_ON_SUCCESS=none"
    echo "EXECUTIONS_DATA_SAVE_ON_ERROR=all"
  } > /etc/n8n/n8n.env
  chmod 0640 /etc/n8n/n8n.env

  # systemd
  log "Creating systemd unit ..."
  cat >/etc/systemd/system/n8n.service <<'UNIT'
[Unit]
Description=n8n workflow automation
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=n8n
Group=n8n
EnvironmentFile=/etc/n8n/n8n.env
WorkingDirectory=/var/lib/n8n
ExecStart=/usr/bin/n8n start
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ProtectHostname=true
ProtectClock=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now n8n

  echo
  log "n8n minimal bootstrap complete."
  echo "Local URL: http://${N8N_HOST}:5678"
  if [[ -n "${WEBHOOK_URL}" ]]; then
    echo "WEBHOOK_URL set to: ${WEBHOOK_URL}"
  else
    echo "Tip: set --webhook-url to your public address so nodes generate correct callback URLs."
  fi
  echo "Service: systemctl status n8n   |   Logs: journalctl -u n8n -f"
}

main "$@"
