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
  --service-user <user>   System user to run services (default: presenton)
  --upgrade               Upgrade existing install in-place (default: false)
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
UPGRADE="false"
DOMAIN=""
EMAIL=""
NEXTJS_BIND_HOST="0.0.0.0"
SERVICE_USER="presenton"
TEMP_DIR="/tmp/presenton"
UV_BIN="/usr/local/bin/uv"
UV_PYTHON_INSTALL_DIR=""
DEBUG_LOG_PATH="/opt/cursor/logs/debug.log"

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
    --service-user)
      SERVICE_USER="${2:-}"
      shift 2
      ;;
    --upgrade)
      UPGRADE="true"
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

if [[ -z "$SERVICE_USER" ]]; then
  echo "--service-user cannot be empty."
  exit 1
fi

if [[ "$FORCE" == "true" && "$UPGRADE" == "true" ]]; then
  echo "--force and --upgrade cannot be used together."
  exit 1
fi

UV_PYTHON_INSTALL_DIR="$INSTALL_DIR/.uv-python"

for port_var in NEXTJS_PORT FASTAPI_PORT MCP_PORT; do
  port_val="${!port_var}"
  if ! [[ "$port_val" =~ ^[0-9]+$ ]] || (( port_val < 1 || port_val > 65535 )); then
    echo "Invalid ${port_var}: ${port_val}"
    exit 1
  fi
done

wait_for_http() {
  local url="$1"
  local name="$2"
  local attempts="${3:-30}"
  local sleep_seconds="${4:-2}"
  local i

  for (( i=1; i<=attempts; i++ )); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "  ${name} OK (${url})"
      return 0
    fi
    sleep "$sleep_seconds"
  done

  echo "  ${name} check failed (${url})"
  return 1
}

run_as_service_user() {
  local cmd="$1"
  if [[ "$SERVICE_USER" == "root" ]]; then
    bash -lc "$cmd"
  else
    runuser -u "$SERVICE_USER" -- bash -lc "$cmd"
  fi
}

debug_log() {
  local hypothesis_id="$1"
  local location="$2"
  local message="$3"
  local data_json="${4:-{}}"
  printf '{"hypothesisId":"%s","location":"%s","message":"%s","data":%s,"timestamp":%s}\n' \
    "$hypothesis_id" "$location" "$message" "$data_json" "$(date +%s%3N)" >> "$DEBUG_LOG_PATH" 2>/dev/null || true
}

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
export UV_INSTALL_DIR="/usr/local/bin"
curl -LsSf https://astral.sh/uv/install.sh | sh
if [[ ! -x "$UV_BIN" ]]; then
  echo "uv not found after install."
  exit 1
fi

echo "[4/10] Installing Python 3.11 via uv..."
mkdir -p "$UV_PYTHON_INSTALL_DIR"
UV_PYTHON_INSTALL_DIR="$UV_PYTHON_INSTALL_DIR" "$UV_BIN" python install 3.11

echo "[5/10] Preparing directories and service user..."
mkdir -p "$(dirname "$INSTALL_DIR")"

if [[ -d "$INSTALL_DIR" && ! -d "$INSTALL_DIR/.git" && "$FORCE" != "true" ]]; then
  echo "Install dir exists but is not a git repo: $INSTALL_DIR"
  echo "Use --force to replace it."
  exit 1
fi

if [[ "$FORCE" == "true" && -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
fi

if [[ "$UPGRADE" != "true" && -d "$INSTALL_DIR/.git" ]]; then
  echo "Install dir already has a git repo: $INSTALL_DIR"
  echo "Use --upgrade to update existing installation, or --force to reinstall."
  exit 1
fi

mkdir -p "$APP_DATA_DIRECTORY"/{exports,uploads,images,fonts}
mkdir -p "$TEMP_DIR"
chmod -R 755 "$APP_DATA_DIRECTORY"

if [[ "$SERVICE_USER" != "root" ]]; then
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
fi
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$APP_DATA_DIRECTORY" "$TEMP_DIR" "$UV_PYTHON_INSTALL_DIR"
#region agent log
uv_python_dir_owner="$(stat -c '%U:%G' "$UV_PYTHON_INSTALL_DIR" 2>/dev/null || echo unknown)"
uv_python_dir_mode="$(stat -c '%a' "$UV_PYTHON_INSTALL_DIR" 2>/dev/null || echo unknown)"
debug_log "A" "scripts/install-presenton-vps.sh:268" "uv_python_dir_after_chown" "{\"serviceUser\":\"$SERVICE_USER\",\"serviceGroup\":\"$SERVICE_GROUP\",\"owner\":\"$uv_python_dir_owner\",\"mode\":\"$uv_python_dir_mode\"}"
#endregion

echo "[6/10] Fetching repository..."
if [[ -d "$INSTALL_DIR/.git" ]]; then
  cd "$INSTALL_DIR"
  current_remote="$(git remote get-url origin || true)"
  if [[ "$current_remote" != "$REPO_URL" ]]; then
    git remote set-url origin "$REPO_URL"
  fi
else
  git clone "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
fi

git fetch --all --tags --prune
git checkout "$REF"
if git ls-remote --heads origin "$REF" | grep -q .; then
  git pull --ff-only origin "$REF"
fi
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"

echo "[7/10] Building FastAPI + Next.js..."
#region agent log
fastapi_sync_runner="$(run_as_service_user "id -un" 2>/dev/null || echo unknown)"
debug_log "B" "scripts/install-presenton-vps.sh:291" "before_fastapi_uv_sync" "{\"serviceUser\":\"$SERVICE_USER\",\"syncRunner\":\"$fastapi_sync_runner\"}"
#endregion
run_as_service_user "cd '$INSTALL_DIR/servers/fastapi' && UV_PYTHON_INSTALL_DIR='$UV_PYTHON_INSTALL_DIR' '$UV_BIN' sync --frozen"
#region agent log
fastapi_venv_python="$INSTALL_DIR/servers/fastapi/.venv/bin/python"
fastapi_venv_owner="$(stat -c '%U:%G' "$fastapi_venv_python" 2>/dev/null || echo missing)"
fastapi_venv_mode="$(stat -c '%a' "$fastapi_venv_python" 2>/dev/null || echo missing)"
fastapi_venv_target="$(readlink -f "$fastapi_venv_python" 2>/dev/null || echo missing)"
fastapi_venv_exec_as_user="$(run_as_service_user "test -x '$fastapi_venv_python' && echo yes || echo no" 2>/dev/null || echo unknown)"
debug_log "C" "scripts/install-presenton-vps.sh:299" "after_fastapi_uv_sync" "{\"venvPython\":\"$fastapi_venv_python\",\"owner\":\"$fastapi_venv_owner\",\"mode\":\"$fastapi_venv_mode\",\"target\":\"$fastapi_venv_target\",\"execAsServiceUser\":\"$fastapi_venv_exec_as_user\"}"
#endregion
run_as_service_user "cd '$INSTALL_DIR/servers/nextjs' && npm ci && npm run build"

echo "[8/10] Writing environment and systemd units..."
ENV_FILE="/etc/presenton.env"
FASTAPI_SERVICE="/etc/systemd/system/presenton-fastapi.service"
MCP_SERVICE="/etc/systemd/system/presenton-mcp.service"
NEXTJS_SERVICE="/etc/systemd/system/presenton-nextjs.service"
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$APP_DATA_DIRECTORY" "$TEMP_DIR" "$INSTALL_DIR"

PYTHON_BIN="$INSTALL_DIR/servers/fastapi/.venv/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "FastAPI venv Python not found: $PYTHON_BIN"
  exit 1
fi
#region agent log
python_bin_exec_as_user="$(run_as_service_user "test -x '$PYTHON_BIN' && echo yes || echo no" 2>/dev/null || echo unknown)"
python_bin_target="$(readlink -f "$PYTHON_BIN" 2>/dev/null || echo missing)"
debug_log "D" "scripts/install-presenton-vps.sh:314" "systemd_python_bin_check" "{\"pythonBin\":\"$PYTHON_BIN\",\"target\":\"$python_bin_target\",\"execAsServiceUser\":\"$python_bin_exec_as_user\"}"
#endregion

cat >"$ENV_FILE" <<EOF_ENV
APP_DATA_DIRECTORY=$APP_DATA_DIRECTORY
TEMP_DIRECTORY=$TEMP_DIR
USER_CONFIG_PATH=$APP_DATA_DIRECTORY/userConfig.json
PUPPETEER_EXECUTABLE_PATH=$CHROMIUM_BIN
ENABLE_OLLAMA=$ENABLE_OLLAMA
CAN_CHANGE_KEYS=true
LLM=openai
DISABLE_ANONYMOUS_TELEMETRY=true
DISABLE_ANONYMOUS_TRACKING=true
PRESENTON_NEXTJS_INTERNAL_URL=http://127.0.0.1:$NEXTJS_PORT
PRESENTON_FASTAPI_INTERNAL_URL=http://127.0.0.1:$FASTAPI_PORT
PRESENTON_NEXTJS_BIND_HOST=$NEXTJS_BIND_HOST
EOF_ENV
if [[ "$SERVICE_USER" == "root" ]]; then
  chown root:root "$ENV_FILE"
  chmod 600 "$ENV_FILE"
else
  chown root:"$SERVICE_GROUP" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
fi

cat >"$FASTAPI_SERVICE" <<EOF_FASTAPI
[Unit]
Description=Presenton FastAPI
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
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
User=$SERVICE_USER
Group=$SERVICE_GROUP
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
User=$SERVICE_USER
Group=$SERVICE_GROUP
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
#region agent log
fastapi_state="$(systemctl is-active presenton-fastapi 2>/dev/null || echo unknown)"
mcp_state="$(systemctl is-active presenton-mcp 2>/dev/null || echo unknown)"
nextjs_state="$(systemctl is-active presenton-nextjs 2>/dev/null || echo unknown)"
debug_log "E" "scripts/install-presenton-vps.sh:441" "post_systemctl_start_states" "{\"fastapi\":\"$fastapi_state\",\"mcp\":\"$mcp_state\",\"nextjs\":\"$nextjs_state\"}"
#endregion

NEXT_HEALTH_URL="http://127.0.0.1:$NEXTJS_PORT/"
FASTAPI_HEALTH_URL="http://127.0.0.1:$FASTAPI_PORT/docs"
FASTAPI_BUSINESS_HEALTH_URL="http://127.0.0.1:$FASTAPI_PORT/api/v1/ppt/ollama/models/supported"
NEXT_PROXY_HEALTH_URL="http://127.0.0.1:$NEXTJS_PORT/api/v1/ppt/ollama/models/supported"
HEALTH_FAILED=0
echo "Health checks (with retries):"
if ! wait_for_http "$NEXT_HEALTH_URL" "Next.js"; then
  HEALTH_FAILED=1
fi
if ! wait_for_http "$FASTAPI_HEALTH_URL" "FastAPI"; then
  HEALTH_FAILED=1
fi
if ! wait_for_http "$FASTAPI_BUSINESS_HEALTH_URL" "FastAPI business API"; then
  HEALTH_FAILED=1
fi
if ! wait_for_http "$NEXT_PROXY_HEALTH_URL" "Next.js -> FastAPI proxy API"; then
  HEALTH_FAILED=1
fi

echo
if [[ "$UPGRADE" == "true" ]]; then
  echo "Upgrade completed."
else
  echo "Install completed."
fi
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

if [[ "$HEALTH_FAILED" -ne 0 ]]; then
#region agent log
fastapi_exec_main_status="$(systemctl show presenton-fastapi -p ExecMainStatus --value 2>/dev/null || echo unknown)"
fastapi_exec_main_code="$(systemctl show presenton-fastapi -p ExecMainCode --value 2>/dev/null || echo unknown)"
fastapi_sub_state="$(systemctl show presenton-fastapi -p SubState --value 2>/dev/null || echo unknown)"
fastapi_restart_count="$(systemctl show presenton-fastapi -p NRestarts --value 2>/dev/null || echo unknown)"
fastapi_recent_journal_b64="$(journalctl -u presenton-fastapi -n 20 --no-pager 2>/dev/null | base64 -w0 2>/dev/null || echo none)"
debug_log "F" "scripts/install-presenton-vps.sh:488" "health_check_failed_fastapi_state" "{\"execMainStatus\":\"$fastapi_exec_main_status\",\"execMainCode\":\"$fastapi_exec_main_code\",\"subState\":\"$fastapi_sub_state\",\"restartCount\":\"$fastapi_restart_count\",\"journalB64\":\"$fastapi_recent_journal_b64\"}"
#endregion
  echo
  echo "One or more health checks failed. Please review service logs above."
  exit 1
fi
