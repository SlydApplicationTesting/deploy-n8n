#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 SLYD LLC
#
# n8n Bootstrap (Ubuntu 24.04, no Docker)
# - Installs Node.js 22.x via NodeSource
# - Installs n8n globally via npm
# - Installs and configures PostgreSQL
# - Creates system user, env file, and systemd unit
# - (Optional) Configures Nginx + Let's Encrypt TLS for a domain
# - Adds SUL acceptance prompt to keep usage compliant
#
# Usage (interactive):
#   sudo bash n8n-bootstrap.sh
#
# Usage (non-interactive example):
#   sudo bash n8n-bootstrap.sh \
#     --domain n8n.example.com \
#     --email admin@example.com \
#     --timezone America/New_York \
#     --db-name n8n --db-user n8n --db-pass 'supersecret' \
#     --yes-sul
#
# Optional flags:
#   --skip-tls        # don't configure Nginx/HTTPS even if a domain is provided
#   --non-interactive # avoid prompts; requires --yes-sul (or ACCEPT_N8N_SUL=yes)
#
set -euo pipefail

# --------------- Defaults ---------------
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
TIMEZONE="${TIMEZONE:-America/New_York}"
DB_NAME="${DB_NAME:-n8n}"
DB_USER="${DB_USER:-n8n}"
DB_PASS="${DB_PASS:-}"
SKIP_TLS="${SKIP_TLS:-}"
YES_SUL="${YES_SUL:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-}"

# --------------- Helpers ---------------
log() { printf "\033[1;32m==>\033[0m %s\n" "$*" ; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*" ; }
err() { printf "\033[1;31m[err]\033[0m %s\n" "$*" >&2 ; }
die() { err "$*"; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root (use sudo)."
  fi
}

usage() {
  cat <<'USAGE'
Usage:
  sudo bash n8n-bootstrap.sh [options]

Options (also support corresponding env vars in ALL_CAPS):
  --domain DOMAIN            Public domain (e.g. n8n.example.com)
  --email EMAIL              Email for Let's Encrypt (required if --domain and TLS enabled)
  --timezone ZONE            IANA TZ (default: America/New_York)
  --db-name NAME             Postgres DB name (default: n8n)
  --db-user USER             Postgres user (default: n8n)
  --db-pass PASS             Postgres password (auto-generated if omitted)
  --skip-tls                 Skip Nginx + TLS (will still set up Nginx if domain set? No.)
  --yes-sul                  Non-interactive acceptance of n8n Sustainable Use License
  --non-interactive          Do not prompt; requires --yes-sul or ACCEPT_N8N_SUL=yes

You can also set:
  ACCEPT_N8N_SUL=yes         (same as --yes-sul)
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0;;
      --domain) DOMAIN="$2"; shift 2;;
      --email) EMAIL="$2"; shift 2;;
      --timezone) TIMEZONE="$2"; shift 2;;
      --db-name) DB_NAME="$2"; shift 2;;
      --db-user) DB_USER="$2"; shift 2;;
      --db-pass) DB_PASS="$2"; shift 2;;
      --skip-tls) SKIP_TLS="yes"; shift 1;;
      --yes-sul) YES_SUL="yes"; shift 1;;
      --non-interactive) NON_INTERACTIVE="yes"; shift 1;;
      *) err "Unknown argument: $1"; usage; exit 1;;
    esac
  done

  # ENV fallback for SUL acceptance
  if [[ -z "${YES_SUL:-}" && "${ACCEPT_N8N_SUL:-}" == "yes" ]]; then
    YES_SUL="yes"
  fi
}

prompt_if_needed() {
  if [[ -z "${NON_INTERACTIVE:-}" ]]; then
    echo
    echo "This installer will download and configure n8n on THIS server."
    echo "By continuing you confirm you’ve reviewed n8n’s Sustainable Use License:"
    echo "  https://docs.n8n.io/sustainable-use-license/"
    echo "and that your use will be for internal business purposes."
    echo "Offering hosted access or white-labeling may require a separate license from n8n."
    echo
    read -r -p "Proceed? (yes/no): " ans
    [[ "$ans" == "yes" ]] || die "Aborted by user."
  else
    [[ "${YES_SUL:-}" == "yes" ]] || die "--non-interactive requires --yes-sul (or ACCEPT_N8N_SUL=yes)."
  fi

  if [[ -z "${DOMAIN}" && -z "${NON_INTERACTIVE:-}" ]]; then
    read -r -p "Enter domain for HTTPS (blank to skip): " DOMAIN
  fi
  if [[ -n "${DOMAIN}" && -z "${EMAIL}" && -z "${NON_INTERACTIVE:-}" && -z "${SKIP_TLS:-}" ]]; then
    read -r -p "Enter email for Let's Encrypt (required for TLS): " EMAIL
  fi
  if [[ -z "${DB_PASS}" && -z "${NON_INTERACTIVE:-}" ]]; then
    # You can press enter to auto-generate
    read -r -s -p "Postgres password for user '${DB_USER}' (blank to auto-generate): " DB_PASS; echo
  fi
}

generate_random_base64() {
  local bytes="${1:-48}" # 48 bytes -> 64 base64 chars
  openssl rand -base64 "$bytes" | tr -d '\n' | sed 's/=*$//'
}

main() {
  require_root
  parse_args "$@"
  prompt_if_needed

  # Determine whether we do TLS + Nginx
  USE_TLS="no"
  if [[ -n "${DOMAIN}" && -z "${SKIP_TLS:-}" ]]; then
    USE_TLS="yes"
    [[ -n "${EMAIL}" ]] || die "Email is required when using TLS with a domain."
  fi

  # Generate DB_PASS if missing
  if [[ -z "${DB_PASS}" ]]; then
    DB_PASS="$(generate_random_base64 24)"
    log "Generated Postgres password for ${DB_USER}."
  fi

  # Generate encryption key
  if [[ -f /etc/n8n/encryption.key ]]; then
    N8N_ENCRYPTION_KEY="$(cat /etc/n8n/encryption.key)"
  else
    mkdir -p /etc/n8n
    chmod 0755 /etc/n8n
    N8N_ENCRYPTION_KEY="$(generate_random_base64 48)"
    printf "%s\n" "${N8N_ENCRYPTION_KEY}" > /etc/n8n/encryption.key
    chmod 0600 /etc/n8n/encryption.key
  fi

  # OS prep
  log "Updating apt cache and installing dependencies..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg2 lsb-release \
    build-essential python3 make gcc g++ \
    postgresql postgresql-contrib
  if [[ "${USE_TLS}" == "yes" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot python3-certbot-nginx
  fi

  # Node.js 22.x via NodeSource
  if ! command -v node >/dev/null 2>&1; then
    log "Installing Node.js 22.x"
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  else
    NODE_V="$(node -v || true)"
    log "Node already present: ${NODE_V}"
  fi

  # Install n8n globally
  if ! command -v n8n >/dev/null 2>&1; then
    log "Installing n8n via npm (global)..."
    npm install -g n8n
  else
    log "n8n already installed."
  fi

  # System user and dirs
  if ! id n8n >/dev/null 2>&1; then
    log "Creating system user 'n8n'..."
    useradd -r -m -d /var/lib/n8n -s /usr/sbin/nologin n8n
  else
    log "System user 'n8n' already exists."
  fi
  mkdir -p /var/lib/n8n
  chown -R n8n:n8n /var/lib/n8n
  mkdir -p /etc/n8n
  chown -R root:root /etc/n8n

  # PostgreSQL setup (idempotent)
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

  # Hostname for env
  if [[ -n "${DOMAIN}" ]]; then
    N8N_HOST="${DOMAIN}"
  else
    N8N_HOST="$(hostname -f 2>/dev/null || hostname)"
  fi

  # Webhook URL & proxy hops
  if [[ "${USE_TLS}" == "yes" ]]; then
    WEBHOOK_URL="https://${DOMAIN}/"
    N8N_PROXY_HOPS="1"
  else
    WEBHOOK_URL="http://${N8N_HOST}:5678/"
    N8N_PROXY_HOPS="0"
  fi

  # Create /etc/n8n/n8n.env
  log "Writing /etc/n8n/n8n.env ..."
  cat >/etc/n8n/n8n.env <<ENV
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2025 SLYD LLC

# ----- Core -----
N8N_PORT=5678
N8N_PROTOCOL=http
N8N_HOST=${N8N_HOST}
GENERIC_TIMEZONE=${TIMEZONE}

# Show correct webhook URLs (esp. behind reverse proxy)
WEBHOOK_URL=${WEBHOOK_URL}
N8N_PROXY_HOPS=${N8N_PROXY_HOPS}

# ----- Security -----
# Persistent key to encrypt credentials
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

# ----- Database (Postgres) -----
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=127.0.0.1
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=${DB_NAME}
DB_POSTGRESDB_USER=${DB_USER}
DB_POSTGRESDB_PASSWORD=${DB_PASS}

# ----- Executions (defaults; tune as needed) -----
EXECUTIONS_MODE=regular
EXECUTIONS_DATA_SAVE_ON_SUCCESS=none
EXECUTIONS_DATA_SAVE_ON_ERROR=all
ENV

  chmod 0640 /etc/n8n/n8n.env

  # systemd unit
  log "Creating systemd unit /etc/systemd/system/n8n.service ..."
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

  # Nginx + TLS
  if [[ "${USE_TLS}" == "yes" ]]; then
    log "Configuring Nginx reverse proxy for ${DOMAIN} ..."
    cat >/etc/nginx/sites-available/n8n <<NGINX
server {
  listen 80;
  server_name ${DOMAIN};

  location / {
    proxy_pass http://127.0.0.1:5678;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Port \$server_port;
  }
}
NGINX

    ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
    nginx -t
    systemctl reload nginx

    log "Requesting Let's Encrypt certificate via certbot..."
    certbot --nginx -d "${DOMAIN}" --redirect -m "${EMAIL}" --agree-tos -n || {
      warn "certbot failed. Check DNS and firewall, then run: certbot --nginx -d ${DOMAIN} --redirect -m ${EMAIL} --agree-tos -n"
    }

    # Reload Nginx to apply TLS
    systemctl reload nginx
  else
    warn "Skipping Nginx/TLS. n8n will be available on http://${N8N_HOST}:5678"
  fi

  # Summary
  echo
  log "n8n bootstrap complete."
  if [[ "${USE_TLS}" == "yes" ]]; then
    echo "URL: https://${DOMAIN}"
  else
    echo "URL: http://${N8N_HOST}:5678"
  fi
  echo "Timezone: ${TIMEZONE}"
  echo "DB: ${DB_NAME} (user: ${DB_USER})"
  echo
  echo "Service status:  systemctl status n8n"
  echo "Live logs:       journalctl -u n8n -f"
  echo
  echo "First-run: open the URL above and complete the admin setup."
  echo "If behind a proxy, WEBHOOK_URL has been set to ensure correct public URLs."
}

main "$@"
