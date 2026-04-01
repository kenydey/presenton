#!/usr/bin/env bash
# Presenton one-click installer for Ubuntu/Debian.
# Default direct mode ports:
#   - Next.js: 5000
#   - FastAPI: 8000
#   - MCP: 8001

set -euo pipefail

readonly REPO_URL="https://github.com/kenydey/presenton.git"

REF="main"
INSTALL_DIR="/opt/presenton"
APP_DATA_DIRECTORY="/var/lib/presenton"
NEXTJS_PORT="5000"
FASTAPI_PORT="8000"
MCP_PORT="8001"
SERVICE_USER="presenton"
SERVICE_GROUP=""
SERVICE_HOME=""
ENABLE_OLLAMA="false"
WITH_NGINX="false"
FORCE="false"
UPGRADE="false"
DOMAIN=""
EMAIL=""
NEXTJS_BIND_HOST="0.0.0.0"

TEMP_DIR="/tmp/presenton"
UV_BIN="/usr/local/bin/uv"
UV_PYTHON_INSTALL_DIR=""
CHROMIUM_BIN=""

ENV_FILE="/etc/presenton.env"
FASTAPI_SERVICE="/etc/systemd/system/presenton-fastapi.service"
MCP_SERVICE="/etc/systemd/system/presenton-mcp.service"
NEXTJS_SERVICE="/etc/systemd/system/presenton-nextjs.service"
PYTHON_BIN=""

usage() {
  cat <<'EOF'
Usage: install-presenton-vps.sh [options]

Options:
  --ref <ref>             Git ref/branch/tag/commit to deploy (default: main)
  --install-dir <dir>     Install directory (default: /opt/presenton)
  --app-data <dir>        Persistent app data directory (default: /var/lib/presenton)
  --next-port <port>      Next.js port (default: 5000)
  --fastapi-port <port>   FastAPI port (default: 8000)
  --mcp-port <port>       MCP port (default: 8001)
  --service-user <user>   System user for services (default: presenton)
  --upgrade               Upgrade existing install in-place
  --force                 Delete install dir then reinstall
  --enable-ollama         Set ENABLE_OLLAMA=true in runtime env
  --with-nginx            Configure nginx + optional certbot
  --domain <domain>       Required with --with-nginx
  --email <email>         Required with --with-nginx
  -h, --help              Show help
EOF
}

info() {
  echo "[install] $*"
}

die() {
  echo "[install][error] $*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Please run as root (use sudo)."
  fi
}

validate_port() {
  local value="$1"
  local name="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    die "Invalid ${name}: ${value}"
  fi
}

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
    return
  fi
  runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" XDG_CACHE_HOME="$SERVICE_HOME/.cache" bash -lc "$cmd"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref) REF="${2:-}"; shift 2 ;;
      --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
      --app-data) APP_DATA_DIRECTORY="${2:-}"; shift 2 ;;
      --next-port) NEXTJS_PORT="${2:-}"; shift 2 ;;
      --fastapi-port) FASTAPI_PORT="${2:-}"; shift 2 ;;
      --mcp-port) MCP_PORT="${2:-}"; shift 2 ;;
      --service-user) SERVICE_USER="${2:-}"; shift 2 ;;
      --upgrade) UPGRADE="true"; shift 1 ;;
      --force) FORCE="true"; shift 1 ;;
      --enable-ollama) ENABLE_OLLAMA="true"; shift 1 ;;
      --with-nginx) WITH_NGINX="true"; shift 1 ;;
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --email) EMAIL="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

validate_args() {
  require_root

  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
    die "Unsupported OS: ${ID:-unknown}. Only Ubuntu/Debian are supported."
  fi

  [[ -n "$SERVICE_USER" ]] || die "--service-user cannot be empty."
  [[ "$FORCE" != "true" || "$UPGRADE" != "true" ]] || die "--force and --upgrade cannot be used together."

  if [[ "$WITH_NGINX" == "true" && ( -z "$DOMAIN" || -z "$EMAIL" ) ]]; then
    die "--with-nginx requires both --domain and --email."
  fi
  if [[ "$WITH_NGINX" == "true" ]]; then
    NEXTJS_BIND_HOST="127.0.0.1"
  fi

  validate_port "$NEXTJS_PORT" "NEXTJS_PORT"
  validate_port "$FASTAPI_PORT" "FASTAPI_PORT"
  validate_port "$MCP_PORT" "MCP_PORT"

  UV_PYTHON_INSTALL_DIR="$INSTALL_DIR/.uv-python"
}

install_chromium() {
  if apt-cache show chromium-browser >/dev/null 2>&1; then
    apt-get install -y chromium-browser
    CHROMIUM_BIN="$(command -v chromium-browser || true)"
    return
  fi
  if apt-cache show chromium >/dev/null 2>&1; then
    apt-get install -y chromium
    CHROMIUM_BIN="$(command -v chromium || true)"
    return
  fi
  die "Chromium package not found in apt sources."
}

install_nodejs_20() {
  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node -v | sed -E 's/^v([0-9]+).*/\1/' || true)"
    if [[ "$major" == "20" ]]; then
      info "Node.js 20 already installed: $(node -v)"
      return
    fi
  fi
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
}

install_uv() {
  if [[ -x "$UV_BIN" ]]; then
    info "uv already installed: $UV_BIN"
    return
  fi
  export UV_INSTALL_DIR="/usr/local/bin"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  [[ -x "$UV_BIN" ]] || die "uv not found after install at $UV_BIN"
}

install_base_packages() {
  info "[1/10] Installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  install_chromium
  apt-get install -y curl ca-certificates git libreoffice fontconfig build-essential
  if [[ "$WITH_NGINX" == "true" ]]; then
    apt-get install -y nginx certbot python3-certbot-nginx
  fi
  [[ -n "$CHROMIUM_BIN" ]] || die "Chromium binary not found after installation."

  info "[2/10] Installing Node.js 20..."
  install_nodejs_20

  info "[3/10] Installing uv..."
  install_uv
}

ensure_service_user() {
  if [[ "$SERVICE_USER" == "root" ]]; then
    SERVICE_GROUP="root"
    SERVICE_HOME="/root"
    return
  fi

  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --create-home --shell /bin/bash "$SERVICE_USER"
  fi

  SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
  SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
  [[ -n "$SERVICE_HOME" ]] || die "Cannot resolve home directory for $SERVICE_USER"
  mkdir -p "$SERVICE_HOME/.cache"
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$SERVICE_HOME"
}

prepare_runtime_dirs() {
  info "[4/10] Installing Python 3.11 via uv..."
  mkdir -p "$UV_PYTHON_INSTALL_DIR"
  UV_PYTHON_INSTALL_DIR="$UV_PYTHON_INSTALL_DIR" "$UV_BIN" python install 3.11

  info "[5/10] Preparing service user and directories..."
  ensure_service_user
  mkdir -p "$APP_DATA_DIRECTORY"/{exports,uploads,images,fonts} "$TEMP_DIR"
  chmod -R 755 "$APP_DATA_DIRECTORY"
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$APP_DATA_DIRECTORY" "$TEMP_DIR" "$UV_PYTHON_INSTALL_DIR"
}

sync_repository() {
  info "[6/10] Fetching repository..."
  mkdir -p "$(dirname "$INSTALL_DIR")"

  if [[ -d "$INSTALL_DIR" && ! -d "$INSTALL_DIR/.git" && "$FORCE" != "true" ]]; then
    die "Install dir exists but is not a git repo: $INSTALL_DIR. Use --force to replace."
  fi

  if [[ "$FORCE" == "true" && -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
  fi

  if [[ "$UPGRADE" != "true" && -d "$INSTALL_DIR/.git" ]]; then
    die "Install dir already has a git repo: $INSTALL_DIR. Use --upgrade or --force."
  fi

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    cd "$INSTALL_DIR"
    local current_remote
    current_remote="$(git remote get-url origin || true)"
    if [[ "$current_remote" != "$REPO_URL" ]]; then
      git remote set-url origin "$REPO_URL"
    fi
  else
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
  fi

  git fetch --all --tags --prune
  if git ls-remote --heads origin "$REF" | grep -q .; then
    git checkout -B "$REF" "origin/$REF"
    git pull --ff-only origin "$REF"
  else
    git checkout "$REF"
  fi
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
}

build_app() {
  info "[7/10] Building FastAPI + Next.js..."
  run_as_service_user "cd '$INSTALL_DIR/servers/fastapi' && UV_PYTHON_INSTALL_DIR='$UV_PYTHON_INSTALL_DIR' '$UV_BIN' sync --frozen"
  run_as_service_user "cd '$INSTALL_DIR/servers/nextjs' && npm ci && npm run build"
}

write_env_file() {
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
}

write_systemd_units() {
  info "[8/10] Writing environment and systemd units..."
  PYTHON_BIN="$INSTALL_DIR/servers/fastapi/.venv/bin/python"
  [[ -x "$PYTHON_BIN" ]] || die "FastAPI venv Python not found: $PYTHON_BIN"

  write_env_file

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

  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$APP_DATA_DIRECTORY" "$TEMP_DIR" "$INSTALL_DIR"
}

configure_nginx_if_needed() {
  if [[ "$WITH_NGINX" != "true" ]]; then
    info "[9/10] Skipping nginx (direct mode)."
    return
  fi

  info "[9/10] Configuring nginx + certbot..."
  local site_available="/etc/nginx/sites-available/presenton.conf"
  local site_enabled="/etc/nginx/sites-enabled/presenton.conf"

  export PRESENTON_DEPLOY_ROOT="$INSTALL_DIR"
  export PRESENTON_APP_DATA="$APP_DATA_DIRECTORY"
  export PRESENTON_SERVER_NAME="$DOMAIN"
  export PRESENTON_NEXTJS_PORT="$NEXTJS_PORT"
  export PRESENTON_FASTAPI_PORT="$FASTAPI_PORT"
  export PRESENTON_MCP_PORT="$MCP_PORT"
  bash "$INSTALL_DIR/scripts/render-nginx-conf.sh" "$site_available"

  ln -sf "$site_available" "$site_enabled"
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx

  set +e
  certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive --redirect -m "$EMAIL"
  local certbot_exit=$?
  set -e
  if [[ $certbot_exit -ne 0 ]]; then
    info "certbot failed (exit $certbot_exit). HTTP will still work."
  fi
}

show_failure_logs() {
  echo
  echo "Recent service logs:"
  journalctl -u presenton-fastapi -n 40 --no-pager || true
  journalctl -u presenton-nextjs -n 40 --no-pager || true
  journalctl -u presenton-mcp -n 40 --no-pager || true
}

run_health_checks() {
  local next_health_url="http://127.0.0.1:$NEXTJS_PORT/"
  local fastapi_health_url="http://127.0.0.1:$FASTAPI_PORT/docs"
  local fastapi_business_url="http://127.0.0.1:$FASTAPI_PORT/api/v1/ppt/ollama/models/supported"
  local next_proxy_url="http://127.0.0.1:$NEXTJS_PORT/api/v1/ppt/ollama/models/supported"
  local health_failed=0

  echo "Health checks (with retries):"
  wait_for_http "$next_health_url" "Next.js" || health_failed=1
  wait_for_http "$fastapi_health_url" "FastAPI" || health_failed=1
  wait_for_http "$fastapi_business_url" "FastAPI business API" || health_failed=1
  wait_for_http "$next_proxy_url" "Next.js -> FastAPI proxy API" || health_failed=1

  if [[ "$health_failed" -ne 0 ]]; then
    echo
    echo "One or more health checks failed."
    show_failure_logs
    exit 1
  fi
}

main() {
  parse_args "$@"
  validate_args
  install_base_packages
  prepare_runtime_dirs
  sync_repository
  build_app
  write_systemd_units
  configure_nginx_if_needed

  info "[10/10] Enabling and starting services..."
  systemctl daemon-reload
  systemctl enable --now presenton-fastapi presenton-mcp presenton-nextjs
  run_health_checks

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
}

main "$@"
