#!/usr/bin/env bash
# One-click VPS install for Presenton (Ubuntu/Debian) using uv + nginx + HTTPS (certbot).
# Default external ports: 80/443 (nginx). Internal services: FastAPI 8000, MCP 8001, Next.js 3000.
#
# Usage:
#   sudo bash scripts/install-presenton-vps.sh --domain example.com --email you@example.com
#   sudo bash scripts/install-presenton-vps.sh --domain example.com --email you@example.com --ref main
#
# Optional:
#   --repo-url https://github.com/presenton/presenton.git
#   --install-dir /opt/presenton
#   --app-data /var/lib/presenton
#   --enable-ollama (spawns local ollama serve)
#   --force (reinstall if install dir exists)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-presenton-vps.sh --domain <domain> --email <email> [options]

Required for HTTPS:
  --domain <domain>     Domain to issue TLS cert for
  --email <email>       Email for certbot

Options:
  --repo-url <url>      Git repo url (default: https://github.com/presenton/presenton.git)
  --ref <ref>           Git ref/branch/tag to checkout (default: main)
  --install-dir <dir>  Install directory (default: /opt/presenton)
  --app-data <dir>     Persistent data directory (default: /var/lib/presenton)
  --enable-ollama       Enable local ollama serve process (default: disabled)
  --force               Overwrite install dir if it already exists
EOF
}

REPO_URL="https://github.com/presenton/presenton.git"
REF="main"
INSTALL_DIR="/opt/presenton"
APP_DATA_DIRECTORY="/var/lib/presenton"
ENABLE_OLLAMA="false"
DOMAIN=""
EMAIL=""
FORCE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --email)
      EMAIL="${2:-}"
      shift 2
      ;;
    --repo-url)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --ref)
      REF="${2:-}"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="${2:-}"
      shift 2
      ;;
    --app-data)
      APP_DATA_DIRECTORY="${2:-}"
      shift 2
      ;;
    --enable-ollama)
      ENABLE_OLLAMA="true"
      shift 1
      ;;
    --force)
      FORCE="true"
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

. /etc/os-release
if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
  echo "Unsupported OS: ${ID:-unknown}. This script targets Ubuntu/Debian."
  exit 1
fi

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
  echo "HTTPS requested by plan: please provide --domain and --email."
  usage
  exit 1
fi

echo "[1/10] Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# Chromium package name differs per distro.
CHROMIUM_BIN=""
if apt-cache show chromium-browser >/dev/null 2>&1; then
  apt-get install -y chromium-browser
  CHROMIUM_BIN="$(command -v chromium-browser || true)"
elif apt-cache show chromium >/dev/null 2>&1; then
  apt-get install -y chromium
  CHROMIUM_BIN="$(command -v chromium || true)"
else
  echo "Cannot find chromium package via apt."
  exit 1
fi

apt-get install -y \
  nginx \
  curl \
  ca-certificates \
  git \
  libreoffice \
  fontconfig \
  certbot \
  python3-certbot-nginx \
  build-essential

if [[ -z "$CHROMIUM_BIN" ]]; then
  echo "Chromium binary not detected after install."
  exit 1
fi

echo "[2/10] Installing Node.js 20..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

echo "[3/10] Installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found in PATH after install."
  exit 1
fi

echo "[4/10] Preparing directories..."
mkdir -p "$(dirname "$INSTALL_DIR")"
if [[ -d "$INSTALL_DIR/.git" && "$FORCE" == "false" ]]; then
  echo "Install dir already exists with git repo: $INSTALL_DIR"
  echo "Pass --force to reinstall."
  exit 1
fi

if [[ "$FORCE" == "true" && -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
fi

if [[ ! -d "$APP_DATA_DIRECTORY" ]]; then
  mkdir -p "$APP_DATA_DIRECTORY"
fi

chmod -R 755 "$APP_DATA_DIRECTORY"

echo "[5/10] Cloning Presenton..."
git clone "$REPO_URL" "$INSTALL_DIR"
cd "$INSTALL_DIR"
git fetch --all --tags --prune
git checkout "$REF"

echo "[6/10] Building FastAPI (uv sync) and Next.js..."
cd "$INSTALL_DIR/servers/fastapi"
uv sync --frozen

cd "$INSTALL_DIR/servers/nextjs"
npm ci
npm run build

echo "[7/10] Generating nginx site config..."
SITE_AVAILABLE="/etc/nginx/sites-available/presenton.conf"
SITE_ENABLED="/etc/nginx/sites-enabled/presenton.conf"

export PRESENTON_DEPLOY_ROOT="$INSTALL_DIR"
export PRESENTON_APP_DATA="$APP_DATA_DIRECTORY"
export PRESENTON_SERVER_NAME="$DOMAIN"

bash "$INSTALL_DIR/scripts/render-nginx-conf.sh" "$SITE_AVAILABLE"

ln -sf "$SITE_AVAILABLE" "$SITE_ENABLED"

# Disable default site if present (common on Debian/Ubuntu)
rm -f /etc/nginx/sites-enabled/default || true

nginx -t
systemctl reload nginx

echo "[8/10] Requesting HTTPS certificate (certbot)..."
set +e
certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive --redirect -m "$EMAIL"
CERTBOT_EXIT=$?
set -e
if [[ $CERTBOT_EXIT -ne 0 ]]; then
  echo "certbot failed with exit code $CERTBOT_EXIT."
  echo "Presenton will still run over HTTP. Check certbot logs."
fi

echo "[9/10] Writing systemd unit and env file..."
ENV_FILE="/etc/presenton.env"
SERVICE_FILE="/etc/systemd/system/presenton.service"

TEMP_DIR="/tmp/presenton"
mkdir -p "$TEMP_DIR"

cat >"$ENV_FILE" <<EOF_ENV
APP_DATA_DIRECTORY=$APP_DATA_DIRECTORY
TEMP_DIRECTORY=$TEMP_DIR
PUPPETEER_EXECUTABLE_PATH=$CHROMIUM_BIN
ENABLE_OLLAMA=$ENABLE_OLLAMA
CAN_CHANGE_KEYS=true
LLM=openai
EOF_ENV

chmod 600 "$ENV_FILE"

cat >"$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Presenton (FastAPI + Next.js via start.js)
After=network.target nginx.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/usr/bin/node $INSTALL_DIR/start.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

systemctl enable --now presenton

echo "[10/10] Done."
echo "Presenton URL:"
echo "  http://$DOMAIN"
echo "  https://$DOMAIN (after certbot succeeds)"
echo "Check logs:"
echo "  journalctl -u presenton -f"

