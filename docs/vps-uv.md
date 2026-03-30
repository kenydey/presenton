# VPS / bare-metal deployment with uv

Run Presenton on a Linux server without Docker: install system packages, sync Python dependencies with [uv](https://docs.astral.sh/uv/), build Next.js, then start everything with [`start.js`](../start.js) (same entrypoint as the container).

## Prerequisites (Debian / Ubuntu)

Adjust package names if you use another distribution.

- **Node.js 20** (e.g. [NodeSource](https://github.com/nodesource/distributions) or your distro’s packages)
- **nginx**
- **Chromium** (for Puppeteer / export paths) — set `PUPPETEER_EXECUTABLE_PATH` to the browser binary (often `/usr/bin/chromium` or `/usr/bin/chromium-browser`)
- **LibreOffice** and **fontconfig**
- **uv** — see [Installing uv](https://docs.astral.sh/uv/getting-started/installation/)
- **Python 3.11** — optional if you use `uv python install 3.11` inside the FastAPI project

Example (Ubuntu):

```bash
sudo apt-get update
sudo apt-get install -y nginx chromium-browser libreoffice fontconfig curl
# Install Node.js 20 and uv per upstream docs
```

## 一键安装脚本（Ubuntu/Debian）

若希望开箱即用（自动安装依赖、`uv sync`、构建 Next.js、配置 nginx，并通过 certbot 自动签发 HTTPS），可以直接运行：

```bash
sudo bash scripts/install-presenton-vps.sh --domain <your-domain> --email <your-email>
```

安装完成后访问：

- `http://<your-domain>`（或 `http://<vps-ip>`）
- `https://<your-domain>`（certbot 签发成功后）

默认对外使用 `80/443`，内部端口仍为 FastAPI `8000`、MCP `8001`、Next.js `3000`，nginx 负责反向代理。

## Install application

From the repository root:

```bash
cd servers/fastapi
uv sync --frozen   # omit --frozen if you intentionally want to update lock resolution
cd ../nextjs
npm ci
npm run build
cd ../..
```

After `uv sync`, `start.js` automatically uses `servers/fastapi/.venv` for FastAPI and the MCP server. Docker images keep using global `python` (no `.venv`).

Override the interpreter if needed:

- `PRESENTON_PYTHON=/path/to/python`

## Environment variables

Set at least:

| Variable | Example | Purpose |
|----------|---------|---------|
| `APP_DATA_DIRECTORY` | `/var/lib/presenton` | Persistent config, uploads, exports |
| `TEMP_DIRECTORY` | `/tmp/presenton` | Temp files |
| `PUPPETEER_EXECUTABLE_PATH` | `/usr/bin/chromium` | Headless browser for exports |

Optional process control:

| Variable | Values | Purpose |
|----------|--------|---------|
| `ENABLE_OLLAMA` | `false` or `0` | Do not spawn `ollama serve` (typical when using only cloud APIs) |

All other keys match the **Deployment Configurations** section in [README.md](../README.md) (LLM, API keys, etc.).

Ensure `APP_DATA_DIRECTORY` exists and is writable by the user that runs `node start.js`.

## Nginx configuration

The committed [`nginx.conf`](../nginx.conf) assumes Docker layout (`/app`, `/app_data`). On a VPS, generate a config that points at your real paths:

```bash
export PRESENTON_DEPLOY_ROOT=/opt/presenton    # repository root
export PRESENTON_APP_DATA=/var/lib/presenton   # same as APP_DATA_DIRECTORY
./scripts/render-nginx-conf.sh /tmp/presenton.nginx.conf
sudo cp /tmp/presenton.nginx.conf /etc/nginx/sites-available/presenton
# Enable site and disable default as appropriate, then:
sudo nginx -t && sudo systemctl reload nginx
```

If you clone the repo to `/app` and use `APP_DATA_DIRECTORY=/app_data`, you can use the stock `nginx.conf` with minimal or no edits.

`start.js` runs `service nginx start`. On many VPS setups nginx is already managed by systemd; you can start nginx yourself and rely on `start.js` only for FastAPI, Next.js, and (optionally) Ollama — or run `node start.js` under a user that may invoke `service nginx start` via sudo, depending on your policy.

## Run

From the repository root (same as Docker `WORKDIR`):

```bash
export APP_DATA_DIRECTORY=/var/lib/presenton
export TEMP_DIRECTORY=/tmp/presenton
export PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
export ENABLE_OLLAMA=false   # if you do not use local Ollama
node start.js
```

Open `http://<server>:80` (or the port nginx listens on). For HTTPS, terminate TLS with nginx or a reverse proxy in front.

## systemd example

`/etc/presenton.env` (mode `0600` — contains secrets):

```env
APP_DATA_DIRECTORY=/var/lib/presenton
TEMP_DIRECTORY=/tmp/presenton
PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
ENABLE_OLLAMA=false
CAN_CHANGE_KEYS=true
LLM=openai
OPENAI_API_KEY=sk-...
```

`/etc/systemd/system/presenton.service`:

```ini
[Unit]
Description=Presenton (FastAPI + Next.js via start.js)
After=network.target nginx.service

[Service]
Type=simple
User=presenton
Group=presenton
WorkingDirectory=/opt/presenton
EnvironmentFile=/etc/presenton.env
ExecStart=/usr/bin/node /opt/presenton/start.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now presenton
```

## Firewall

Allow only what you need (e.g. `80`/`443` from the internet; keep `3000`, `8000`, `8001` on localhost behind nginx).

## Codex OAuth

If you use features that redirect to `localhost:1455`, mirror [docker-compose.yml](../docker-compose.yml) port exposure or configure your reverse proxy accordingly.
