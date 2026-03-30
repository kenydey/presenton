# AGENTS.md

## Cursor Cloud specific instructions

### Architecture overview

Presenton is an open-source AI presentation generator with three main services:

| Service | Port | Tech |
|---------|------|------|
| FastAPI backend | 8000 | Python 3.11, SQLModel/SQLite, ChromaDB |
| Next.js frontend | 3000 | Next.js 14, React 18, TypeScript |
| Nginx reverse proxy | 80 | Routes `/` → Next.js, `/api/v1/` → FastAPI |

An optional MCP server runs on port 8001. `start.js` in the repo root orchestrates all services.

### Required environment variables

```bash
export APP_DATA_DIRECTORY=/app_data
export TEMP_DIRECTORY=/tmp/presenton
export PUPPETEER_EXECUTABLE_PATH=/usr/local/bin/google-chrome
export ENABLE_OLLAMA=false
export DISABLE_ANONYMOUS_TELEMETRY=true
```

### Running services for development

Start all three services at once (dev mode with hot-reload):
```bash
node start.js --dev
```

Or start them individually:
- **FastAPI**: `cd servers/fastapi && .venv/bin/python server.py --port 8000 --reload true`
- **Next.js**: `cd servers/nextjs && npm run dev -- -H 127.0.0.1 -p 3000`
- **Nginx**: `sudo service nginx start` (config copied from `nginx.conf` to `/etc/nginx/nginx.conf`)

### Important caveats

- **Python version**: The FastAPI backend requires Python `>=3.11,<3.12`. The venv is managed by `uv` at `servers/fastapi/.venv`.
- **Nginx config**: The stock `nginx.conf` references `/app/servers/fastapi/static/` and `/app_data/`. A symlink `/app -> /workspace` is needed, plus `/app_data` must exist and be writable.
- **Chromium/Chrome**: The Dockerfile uses Chromium, but in the Cloud VM Google Chrome is pre-installed at `/usr/local/bin/google-chrome`. Set `PUPPETEER_EXECUTABLE_PATH` accordingly.
- **ESLint**: The Next.js project doesn't ship an `.eslintrc` file. Running `next lint` will prompt interactively unless you first create `.eslintrc.json` with `{"extends": "next/core-web-vitals"}` and install `eslint@8 eslint-config-next@14` (matching Next.js 14).
- **`/tmp/presenton` ownership**: `TempFileService` tries to `rmdir` the temp directory on startup. If created by root, the FastAPI process may fail with `PermissionError`. Ensure it's owned by the current user.
- **Tests**: `cd servers/fastapi && .venv/bin/python -m pytest` — some tests have pre-existing import errors; collectible tests work. Tests requiring LLM keys will error at runtime without API keys configured.
- **Lint**: `cd servers/nextjs && npm run lint` (requires ESLint setup as noted above).
- **Build**: `cd servers/nextjs && npm run build` will fail on lint warnings treated as errors unless `eslint.ignoreDuringBuilds: true` is added to `next.config.mjs`. This is a pre-existing issue. Dev mode (`npm run dev`) is unaffected.
- **LLM API keys**: Presentation generation requires at least one LLM API key (OpenAI/Google/Anthropic/Ollama). Keys can be configured via environment variables or the in-app settings UI at first launch.
