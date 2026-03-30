#!/usr/bin/env bash
# Render nginx.conf from nginx.conf.template for bare-metal / VPS paths.
# Usage:
#   ./scripts/render-nginx-conf.sh                    # print to stdout
#   ./scripts/render-nginx-conf.sh /path/to/out.conf  # write file
#
# Environment:
#   PRESENTON_DEPLOY_ROOT  - git checkout root (default: parent of scripts/)
#   PRESENTON_APP_DATA     - persistent app data dir (default: $APP_DATA_DIRECTORY or <deploy>/app_data)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_ROOT="${PRESENTON_DEPLOY_ROOT:-$REPO_ROOT}"

if [[ -n "${APP_DATA_DIRECTORY:-}" ]]; then
  APP_DATA="${PRESENTON_APP_DATA:-$APP_DATA_DIRECTORY}"
else
  APP_DATA="${PRESENTON_APP_DATA:-$DEPLOY_ROOT/app_data}"
fi

TEMPLATE="$REPO_ROOT/nginx.conf.template"
if [[ ! -f "$TEMPLATE" ]]; then
  echo "error: missing $TEMPLATE" >&2
  exit 1
fi

rendered="$(awk -v d="$DEPLOY_ROOT" -v a="$APP_DATA" '
  {
    gsub(/__PRESENTON_DEPLOY_ROOT__/, d)
    gsub(/__PRESENTON_APP_DATA__/, a)
    print
  }
' "$TEMPLATE")"

if [[ "${1:-}" ]]; then
  printf '%s\n' "$rendered" >"$1"
  echo "Wrote $1"
else
  printf '%s\n' "$rendered"
fi
