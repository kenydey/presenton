#!/usr/bin/env bash
# Presenton UV 安装模式
# 使用 uv 安装 Python 依赖，比 pip 更快更可靠
# 详见: https://docs.astral.sh/uv/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Presenton UV 安装模式${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 检查 uv 是否已安装
check_uv() {
    if command -v uv &> /dev/null; then
        echo -e "${GREEN}✓ 检测到 uv: $(uv --version)${NC}"
        return 0
    else
        echo -e "${YELLOW}uv 未安装。正在安装...${NC}"
        if command -v curl &> /dev/null; then
            curl -LsSf https://astral.sh/uv/install.sh | sh
            export PATH="$HOME/.local/bin:$PATH"
        elif command -v wget &> /dev/null; then
            wget -qO- https://astral.sh/uv/install.sh | sh
            export PATH="$HOME/.local/bin:$PATH"
        else
            echo -e "${RED}✗ 无法安装 uv。请手动安装: https://docs.astral.sh/uv/getting-started/installation/${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ uv 安装完成${NC}"
        return 0
    fi
}

# 安装主 FastAPI 服务 (servers/fastapi)
install_main_fastapi() {
    if [ -d "servers/fastapi" ] && [ -f "servers/fastapi/pyproject.toml" ]; then
        echo -e "${YELLOW}→ 安装主 FastAPI 依赖 (servers/fastapi)...${NC}"
        cd servers/fastapi
        uv sync
        cd "$PROJECT_ROOT"
        echo -e "${GREEN}✓ 主 FastAPI 依赖安装完成${NC}"
    else
        echo -e "${YELLOW}⚠ servers/fastapi 未找到，跳过${NC}"
    fi
}

# 安装 Electron FastAPI 服务 (electron/servers/fastapi)
install_electron_fastapi() {
    if [ -d "electron/servers/fastapi" ] && [ -f "electron/servers/fastapi/pyproject.toml" ]; then
        echo -e "${YELLOW}→ 安装 Electron FastAPI 依赖 (electron/servers/fastapi)...${NC}"
        cd electron/servers/fastapi
        uv sync
        cd "$PROJECT_ROOT"
        echo -e "${GREEN}✓ Electron FastAPI 依赖安装完成${NC}"
    else
        echo -e "${YELLOW}⚠ electron/servers/fastapi 未找到，跳过${NC}"
    fi
}

# 安装 Node.js 依赖
install_node_deps() {
    echo -e "${YELLOW}→ 安装 Node.js 依赖...${NC}"
    if [ -d "electron" ] && [ -f "electron/package.json" ]; then
        cd electron
        npm install
        cd "$PROJECT_ROOT"
    fi
    if [ -d "servers/nextjs" ] && [ -f "servers/nextjs/package.json" ]; then
        cd servers/nextjs
        npm ci 2>/dev/null || npm install
        cd "$PROJECT_ROOT"
    fi
    if [ -d "electron/servers/nextjs" ] && [ -f "electron/servers/nextjs/package.json" ]; then
        cd electron/servers/nextjs
        npm ci 2>/dev/null || npm install --legacy-peer-deps
        cd "$PROJECT_ROOT"
    fi
    echo -e "${GREEN}✓ Node.js 依赖安装完成${NC}"
}

# 解析参数
MODE="${1:-electron}"

check_uv
echo ""

case "$MODE" in
    electron|desktop)
        echo -e "${BLUE}模式: Electron 桌面应用${NC}"
        install_electron_fastapi
        install_node_deps
        echo ""
        echo -e "${GREEN}✅ UV 安装完成！运行 Electron 应用:${NC}"
        echo -e "   cd electron && npm run dev"
        ;;
    main|servers)
        echo -e "${BLUE}模式: 主服务 (servers/)${NC}"
        install_main_fastapi
        install_node_deps
        echo ""
        echo -e "${GREEN}✅ UV 安装完成！${NC}"
        ;;
    fastapi-only)
        echo -e "${BLUE}模式: 仅 FastAPI 后端${NC}"
        install_main_fastapi
        install_electron_fastapi
        echo ""
        echo -e "${GREEN}✅ FastAPI 依赖安装完成！${NC}"
        ;;
    *)
        echo -e "${RED}未知模式: $MODE${NC}"
        echo "用法: $0 [electron|main|fastapi-only]"
        echo "  electron       - Electron 桌面应用 (默认)"
        echo "  main           - 主服务 (servers/)"
        echo "  fastapi-only   - 仅 Python FastAPI 依赖"
        exit 1
        ;;
esac

echo ""
