#!/usr/bin/env bash
# Render nginx.conf from nginx.conf.template for bare-metal / VPS paths.
# Usage:
#   ./scripts/render-nginx-conf.sh                    # print to stdout
#   ./scripts/render-nginx-conf.sh /path/to/out.conf  # write file
#
# Environment:
#   PRESENTON_DEPLOY_ROOT  - git checkout root (default: parent of scripts/)
#   PRESENTON_APP_DATA      - persistent app data dir (default: $APP_DATA_DIRECTORY or <deploy>/app_data)
#   PRESENTON_NEXTJS_PORT   - Next.js upstream port (default: 5000)
#   PRESENTON_FASTAPI_PORT  - FastAPI upstream port (default: 8000)
#   PRESENTON_MCP_PORT      - MCP upstream port (default: 8001)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_ROOT="${PRESENTON_DEPLOY_ROOT:-$REPO_ROOT}"

if [[ -n "${APP_DATA_DIRECTORY:-}" ]]; then
  APP_DATA="${PRESENTON_APP_DATA:-$APP_DATA_DIRECTORY}"
else
  APP_DATA="${PRESENTON_APP_DATA:-$DEPLOY_ROOT/app_data}"
fi

SERVER_NAME="${PRESENTON_SERVER_NAME:-localhost}"
NEXTJS_PORT="${PRESENTON_NEXTJS_PORT:-5000}"
FASTAPI_PORT="${PRESENTON_FASTAPI_PORT:-8000}"
MCP_PORT="${PRESENTON_MCP_PORT:-8001}"

TEMPLATE="$REPO_ROOT/nginx.conf.template"
if [[ ! -f "$TEMPLATE" ]]; then
  echo "error: missing $TEMPLATE" >&2
  exit 1
fi

rendered="$(awk -v d="$DEPLOY_ROOT" -v a="$APP_DATA" -v s="$SERVER_NAME" -v n="$NEXTJS_PORT" -v f="$FASTAPI_PORT" -v m="$MCP_PORT" '
  {
    gsub(/__PRESENTON_DEPLOY_ROOT__/, d)
    gsub(/__PRESENTON_APP_DATA__/, a)
    gsub(/__PRESENTON_SERVER_NAME__/, s)
    gsub(/__PRESENTON_NEXTJS_PORT__/, n)
    gsub(/__PRESENTON_FASTAPI_PORT__/, f)
    gsub(/__PRESENTON_MCP_PORT__/, m)
    print
  }
' "$TEMPLATE")"

if [[ "${1:-}" ]]; then
  printf '%s\n' "$rendered" >"$1"
  echo "Wrote $1"
else
  printf '%s\n' "$rendered"
fi
