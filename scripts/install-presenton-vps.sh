#!/usr/bin/env bash
# Ubuntu/Debian one-click installer for Presenton (kenydey/presenton).
# Default mode is direct deployment (no nginx):
#   - Next.js: 5000
#   - FastAPI: 8000
#   - MCP: 8001
#
# Optional: --with-nginx to configure reverse proxy + certbot HTTPS.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-presenton-vps.sh [options]

Options:
  --ref <ref>             Git ref/branch/tag to checkout (default: main)
  --install-dir <dir>     Install directory (default: /opt/presenton)
  --app-data <dir>        Persistent data directory (default: /var/lib/presenton)
  --next-port <port>      Next.js port (default: 5000)
  --fastapi-port <port>   FastAPI port (default: 8000)
  --mcp-port <port>       MCP port (default: 8001)
  --enable-ollama         Enable local ollama serve (default: disabled)
  --with-nginx            Configure nginx reverse proxy (optional)
  --domain <domain>       Required only when --with-nginx is used
  --email <email>         Required only when --with-nginx is used
  --force                 Overwrite existing install directory
  -h, --help              Show this help
EOF
}

readonly REPO_URL="https://github.com/kenydey/presenton.git"
REF="main"
INSTALL_DIR="/opt/presenton"
APP_DATA_DIRECTORY="/var/lib/presenton"
NEXTJS_PORT="5000"
FASTAPI_PORT="8000"
MCP_PORT="8001"
ENABLE_OLLAMA="false"
WITH_NGINX="false"
FORCE="false"
DOMAIN=""
EMAIL=""
NEXTJS_BIND_HOST="0.0.0.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --enable-ollama)
      ENABLE_OLLAMA="true"
      shift 1
      ;;
    --with-nginx)
      WITH_NGINX="true"
      shift 1
      ;;
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --email)
      EMAIL="${2:-}"
      shift 2
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
  echo "Unsupported OS: ${ID:-unknown}. Only Ubuntu/Debian are supported."
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
    echo "Invalid ${port_var}: ${port_val}"
    exit 1
  fi
done

echo "[1/10] Installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# Chromium package name differs between Ubuntu/Debian flavors.
CHROMIUM_BIN=""
if apt-cache show chromium-browser >/dev/null 2>&1; then
  apt-get install -y chromium-browser
  CHROMIUM_BIN="$(command -v chromium-browser || true)"
elif apt-cache show chromium >/dev/null 2>&1; then
  apt-get install -y chromium
  CHROMIUM_BIN="$(command -v chromium || true)"
else
  echo "Chromium package not found in apt sources."
  exit 1
fi

apt-get install -y curl ca-certificates git libreoffice fontconfig build-essential

if [[ "$WITH_NGINX" == "true" ]]; then
  apt-get install -y nginx certbot python3-certbot-nginx
fi

if [[ -z "$CHROMIUM_BIN" ]]; then
  echo "Chromium binary not found after installation."
  exit 1
fi

echo "[2/10] Installing Node.js 20..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

echo "[3/10] Installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found after install."
  exit 1
fi

echo "[4/10] Installing Python 3.11 via uv..."
uv python install 3.11

echo "[5/10] Preparing directories..."
mkdir -p "$(dirname "$INSTALL_DIR")"
if [[ -d "$INSTALL_DIR/.git" && "$FORCE" != "true" ]]; then
  echo "Install dir already has a git repo: $INSTALL_DIR"
  echo "Use --force to reinstall."
  exit 1
fi
if [[ "$FORCE" == "true" && -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
fi
mkdir -p "$APP_DATA_DIRECTORY"/{exports,uploads,images,fonts}
chmod -R 755 "$APP_DATA_DIRECTORY"

echo "[6/10] Cloning repository..."
git clone "$REPO_URL" "$INSTALL_DIR"
cd "$INSTALL_DIR"
git fetch --all --tags --prune
git checkout "$REF"

echo "[7/10] Building FastAPI + Next.js..."
cd "$INSTALL_DIR/servers/fastapi"
uv sync --frozen

cd "$INSTALL_DIR/servers/nextjs"
npm ci
npm run build

echo "[8/10] Writing environment and systemd units..."
ENV_FILE="/etc/presenton.env"
FASTAPI_SERVICE="/etc/systemd/system/presenton-fastapi.service"
MCP_SERVICE="/etc/systemd/system/presenton-mcp.service"
NEXTJS_SERVICE="/etc/systemd/system/presenton-nextjs.service"
TEMP_DIR="/tmp/presenton"
mkdir -p "$TEMP_DIR"

PYTHON_BIN="$INSTALL_DIR/servers/fastapi/.venv/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "FastAPI venv Python not found: $PYTHON_BIN"
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

cat >"$FASTAPI_SERVICE" <<EOF_FASTAPI
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
EOF_FASTAPI

cat >"$MCP_SERVICE" <<EOF_MCP
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
EOF_MCP

cat >"$NEXTJS_SERVICE" <<EOF_NEXT
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
EOF_NEXT

if [[ "$WITH_NGINX" == "true" ]]; then
  echo "[9/10] Configuring nginx + certbot..."
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
    echo "certbot failed (exit $CERTBOT_EXIT). HTTP still works."
  fi
else
  echo "[9/10] Skipping nginx (direct mode)."
fi

echo "[10/10] Enabling and starting services..."
systemctl daemon-reload
systemctl enable --now presenton-fastapi presenton-mcp presenton-nextjs

NEXT_HEALTH_URL="http://127.0.0.1:$NEXTJS_PORT/"
FASTAPI_HEALTH_URL="http://127.0.0.1:$FASTAPI_PORT/docs"
echo "Health checks:"
curl -fsS "$NEXT_HEALTH_URL" >/dev/null && echo "  Next.js OK ($NEXT_HEALTH_URL)" || echo "  Next.js check failed ($NEXT_HEALTH_URL)"
curl -fsS "$FASTAPI_HEALTH_URL" >/dev/null && echo "  FastAPI OK ($FASTAPI_HEALTH_URL)" || echo "  FastAPI check failed ($FASTAPI_HEALTH_URL)"

echo
echo "Install completed."
if [[ "$WITH_NGINX" == "true" ]]; then
  echo "Open:"
  echo "  http://$DOMAIN"
  echo "  https://$DOMAIN (if certbot succeeded)"
else
  echo "Open:"
  echo "  http://<server-ip>:$NEXTJS_PORT"
fi
echo
echo "Logs:"
echo "  journalctl -u presenton-fastapi -f"
echo "  journalctl -u presenton-nextjs -f"
echo "  journalctl -u presenton-mcp -f"
