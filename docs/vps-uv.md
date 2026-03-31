# VPS / bare-metal deployment with uv

Run Presenton on a Linux server without Docker: install system packages, sync Python dependencies with [uv](https://docs.astral.sh/uv/), build Next.js, then run FastAPI + MCP + Next.js as separate systemd services.

## Prerequisites (Debian / Ubuntu)

Adjust package names if you use another distribution.

- **Node.js 20** (e.g. [NodeSource](https://github.com/nodesource/distributions) or your distro’s packages)
- **Chromium** (for Puppeteer / export paths) — set `PUPPETEER_EXECUTABLE_PATH` to the browser binary (often `/usr/bin/chromium` or `/usr/bin/chromium-browser`)
- **LibreOffice** and **fontconfig**
- **uv** — see [Installing uv](https://docs.astral.sh/uv/getting-started/installation/)
- **Python 3.11** — optional if you use `uv python install 3.11` inside the FastAPI project

Example (Ubuntu):

```bash
sudo apt-get update
sudo apt-get install -y chromium-browser libreoffice fontconfig curl
# Install Node.js 20 and uv per upstream docs
```

## 一键安装脚本（Ubuntu/Debian）

若希望开箱即用（自动安装依赖、`uv sync`、构建 Next.js、写入 systemd 服务并直接启动），可以直接运行（脚本固定从 `https://github.com/kenydey/presenton.git` 部署）：

```bash
sudo bash scripts/install-presenton-vps.sh
```

安装完成后访问：

- `http://<vps-ip>:5000`

默认端口：FastAPI `8000`、MCP `8001`、Next.js `5000`。无需 nginx。

如需 nginx + HTTPS（可选），使用：

```bash
sudo bash scripts/install-presenton-vps.sh --with-nginx --domain <your-domain> --email <your-email>
```

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

## Nginx configuration（可选）

当你启用 `--with-nginx` 时，脚本会自动生成并安装站点配置。若你要手动生成，使用：

```bash
export PRESENTON_DEPLOY_ROOT=/opt/presenton    # repository root
export PRESENTON_APP_DATA=/var/lib/presenton   # same as APP_DATA_DIRECTORY
export PRESENTON_NEXTJS_PORT=5000
export PRESENTON_FASTAPI_PORT=8000
export PRESENTON_MCP_PORT=8001
./scripts/render-nginx-conf.sh /tmp/presenton.nginx.conf
sudo cp /tmp/presenton.nginx.conf /etc/nginx/sites-available/presenton
# Enable site and disable default as appropriate, then:
sudo nginx -t && sudo systemctl reload nginx
```

`nginx.conf.template` 已支持通过环境变量覆盖 Next/FastAPI/MCP 端口，不再写死。

## Run

From the repository root:

```bash
export APP_DATA_DIRECTORY=/var/lib/presenton
export TEMP_DIRECTORY=/tmp/presenton
export PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
export ENABLE_OLLAMA=false   # if you do not use local Ollama
export PRESENTON_NEXTJS_INTERNAL_URL=http://127.0.0.1:5000
export PRESENTON_FASTAPI_INTERNAL_URL=http://127.0.0.1:8000

# FastAPI
cd servers/fastapi
uv sync --frozen
.venv/bin/python server.py --port 8000 --reload false

# MCP (new terminal)
.venv/bin/python mcp_server.py --port 8001

# Next.js (new terminal)
cd ../nextjs
npm ci
npm run build
npm run start -- -H 127.0.0.1 -p 5000
```

Open `http://<server>:5000`.

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

脚本会创建以下 unit：

- `presenton-fastapi.service`
- `presenton-nextjs.service`
- `presenton-mcp.service`

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now presenton-fastapi presenton-nextjs presenton-mcp
```

## Firewall

Allow only what you need:

- no nginx mode: expose `5000` (and keep `8000`, `8001` internal if possible)
- nginx mode: expose `80/443`

## Codex OAuth

If you use features that redirect to `localhost:1455`, mirror [docker-compose.yml](../docker-compose.yml) port exposure or configure your reverse proxy accordingly.
