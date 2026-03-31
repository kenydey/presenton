#!/usr/bin/env bash
# One-click VPS install for Presenton (Ubuntu/Debian), nginx optional.
# Default (recommended): run services directly, no nginx required.
#   - Next.js: 127.0.0.1:5000 (also externally accessible if firewall allows)
#   - FastAPI: 127.0.0.1:8000
#   - MCP: 127.0.0.1:8001
#
# Usage:
#   sudo bash scripts/install-presenton-vps.sh
#   sudo bash scripts/install-presenton-vps.sh --ref main --next-port 5000
#
# Optional nginx + HTTPS:
#   sudo bash scripts/install-presenton-vps.sh --with-nginx --domain example.com --email you@example.com

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-presenton-vps.sh [options]

Options:
  --repo-url <url>      Git repo url (default: https://github.com/presenton/presenton.git)
  --ref <ref>           Git ref/branch/tag to checkout (default: main)
  --install-dir <dir>  Install directory (default: /opt/presenton)
  --app-data <dir>     Persistent data directory (default: /var/lib/presenton)
  --next-port <port>    Next.js port (default: 5000)
  --fastapi-port <port> FastAPI port (default: 8000)
  --mcp-port <port>     MCP port (default: 8001)
  --enable-ollama       Enable local ollama serve process (default: disabled)
  --with-nginx          Configure nginx reverse proxy (optional)
  --domain <domain>     Required only when --with-nginx is used
  --email <email>       Required only when --with-nginx is used
  --force               Overwrite install dir if it already exists
EOF
}

REPO_URL="https://github.com/presenton/presenton.git"
REF="main"
INSTALL_DIR="/opt/presenton"
APP_DATA_DIRECTORY="/var/lib/presenton"
ENABLE_OLLAMA="false"
WITH_NGINX="false"
DOMAIN=""
EMAIL=""
FORCE="false"
NEXTJS_PORT="5000"
FASTAPI_PORT="8000"
MCP_PORT="8001"
NEXTJS_BIND_HOST="0.0.0.0"

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
    --with-nginx)
      WITH_NGINX="true"
      shift 1
      ;;
    --force)
      FORCE="true"
      shift 1
      ;;
    --next-port)
      NEXTJS_PORT="${2:-}"
      shift 2
      ;;
    --fastapi-port)
      FASTAPI_PORT="${2:-}"
      shift 2
      ;;
    --mcp-port)
      MCP_PORT="${2:-}"
      shift 2
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

if [[ "$WITH_NGINX" == "true" && ( -z "$DOMAIN" || -z "$EMAIL" ) ]]; then
  echo "--with-nginx requires both --domain and --email."
  usage
  exit 1
fi

if [[ "$WITH_NGINX" == "true" ]]; then
  NEXTJS_BIND_HOST="127.0.0.1"
fi

for port_var in NEXTJS_PORT FASTAPI_PORT MCP_PORT; do
  port_val="${!port_var}"
  if ! [[ "$port_val" =~ ^[0-9]+$ ]] || (( port_val < 1 || port_val > 65535 )); then
    echo "Invalid value for ${port_var}: ${port_val}"
    exit 1
  fi
done

echo "[1/9] Installing system packages..."
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
  curl \
  ca-certificates \
  git \
  libreoffice \
  fontconfig \
  build-essential

if [[ "$WITH_NGINX" == "true" ]]; then
  apt-get install -y nginx certbot python3-certbot-nginx
fi

if [[ -z "$CHROMIUM_BIN" ]]; then
  echo "Chromium binary not detected after install."
  exit 1
fi

echo "[2/9] Installing Node.js 20..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

echo "[3/9] Installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found in PATH after install."
  exit 1
fi

echo "[3.1/9] Ensuring Python 3.11 for FastAPI (uv sync requires >=3.11,<3.12)..."
uv python install 3.11

echo "[4/9] Preparing directories..."
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

echo "[5/9] Cloning Presenton..."
git clone "$REPO_URL" "$INSTALL_DIR"
cd "$INSTALL_DIR"
git fetch --all --tags --prune
git checkout "$REF"

echo "[6/9] Building FastAPI (uv sync) and Next.js..."
cd "$INSTALL_DIR/servers/fastapi"
uv sync --frozen

cd "$INSTALL_DIR/servers/nextjs"
npm ci
npm run build

echo "[7/9] Writing systemd env and units..."
ENV_FILE="/etc/presenton.env"
FASTAPI_SERVICE_FILE="/etc/systemd/system/presenton-fastapi.service"
NEXTJS_SERVICE_FILE="/etc/systemd/system/presenton-nextjs.service"
MCP_SERVICE_FILE="/etc/systemd/system/presenton-mcp.service"

TEMP_DIR="/tmp/presenton"
mkdir -p "$TEMP_DIR"
mkdir -p "$APP_DATA_DIRECTORY/exports" "$APP_DATA_DIRECTORY/uploads" "$APP_DATA_DIRECTORY/images" "$APP_DATA_DIRECTORY/fonts"
PYTHON_BIN="$INSTALL_DIR/servers/fastapi/.venv/bin/python"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Python venv executable not found: $PYTHON_BIN"
  exit 1
fi

cat >"$ENV_FILE" <<EOF_ENV
APP_DATA_DIRECTORY=$APP_DATA_DIRECTORY
TEMP_DIRECTORY=$TEMP_DIR
USER_CONFIG_PATH=$APP_DATA_DIRECTORY/userConfig.json
PUPPETEER_EXECUTABLE_PATH=$CHROMIUM_BIN
ENABLE_OLLAMA=$ENABLE_OLLAMA
CAN_CHANGE_KEYS=true
LLM=openai
DISABLE_ANONYMOUS_TELEMETRY=true
PRESENTON_NEXTJS_INTERNAL_URL=http://127.0.0.1:$NEXTJS_PORT
PRESENTON_FASTAPI_INTERNAL_URL=http://127.0.0.1:$FASTAPI_PORT
PRESENTON_NEXTJS_BIND_HOST=$NEXTJS_BIND_HOST
EOF_ENV

chmod 600 "$ENV_FILE"

cat >"$FASTAPI_SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Presenton FastAPI
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/servers/fastapi
EnvironmentFile=$ENV_FILE
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=$PYTHON_BIN $INSTALL_DIR/servers/fastapi/server.py --port $FASTAPI_PORT --reload false
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

cat >"$MCP_SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Presenton MCP
After=network.target presenton-fastapi.service
Requires=presenton-fastapi.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/servers/fastapi
EnvironmentFile=$ENV_FILE
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=$PYTHON_BIN $INSTALL_DIR/servers/fastapi/mcp_server.py --port $MCP_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

cat >"$NEXTJS_SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Presenton Next.js
After=network.target presenton-fastapi.service
Requires=presenton-fastapi.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/servers/nextjs
EnvironmentFile=$ENV_FILE
Environment="NODE_ENV=production"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/usr/bin/npm run start -- -H $NEXTJS_BIND_HOST -p $NEXTJS_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

if [[ "$WITH_NGINX" == "true" ]]; then
  echo "[8/9] Configuring nginx + certbot..."
  SITE_AVAILABLE="/etc/nginx/sites-available/presenton.conf"
  SITE_ENABLED="/etc/nginx/sites-enabled/presenton.conf"

  export PRESENTON_DEPLOY_ROOT="$INSTALL_DIR"
  export PRESENTON_APP_DATA="$APP_DATA_DIRECTORY"
  export PRESENTON_SERVER_NAME="$DOMAIN"
  export PRESENTON_NEXTJS_PORT="$NEXTJS_PORT"
  export PRESENTON_FASTAPI_PORT="$FASTAPI_PORT"
  export PRESENTON_MCP_PORT="$MCP_PORT"

  bash "$INSTALL_DIR/scripts/render-nginx-conf.sh" "$SITE_AVAILABLE"
  ln -sf "$SITE_AVAILABLE" "$SITE_ENABLED"
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx

  set +e
  certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive --redirect -m "$EMAIL"
  CERTBOT_EXIT=$?
  set -e
  if [[ $CERTBOT_EXIT -ne 0 ]]; then
    echo "certbot failed with exit code $CERTBOT_EXIT."
    echo "Presenton will still run over HTTP. Check certbot logs."
  fi
else
  echo "[8/9] Skipping nginx (direct service mode)."
fi

echo "[9/9] Enabling services..."
systemctl daemon-reload
systemctl enable --now presenton-fastapi presenton-mcp presenton-nextjs

echo "Done."
if [[ "$WITH_NGINX" == "true" ]]; then
  echo "Presenton URL:"
  echo "  http://$DOMAIN"
  echo "  https://$DOMAIN (after certbot succeeds)"
else
  echo "Presenton URL (direct):"
  echo "  http://<server-ip>:$NEXTJS_PORT"
fi
echo "Check logs:"
echo "  journalctl -u presenton-fastapi -f"
echo "  journalctl -u presenton-nextjs -f"
echo "  journalctl -u presenton-mcp -f"

