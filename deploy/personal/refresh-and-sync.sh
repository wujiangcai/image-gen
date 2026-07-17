#!/usr/bin/env bash
# ============================================================
# blackcat 重登刷新 access_token -> 同步进 chatgpt2api 账号池
# 供 VPS 上 cron / systemd timer 定时调用，实现账号池自动续命。
#
# 放置：建议把本目录 (deploy/personal) 整体传到 VPS，例如 /opt/deploy-personal/
#       chmod +x /opt/deploy-personal/refresh-and-sync.sh
#       桥接脚本 blackcat-chatgpt2api-bridge.js 与本脚本同目录即可（已用 DIR 自动定位）。
#
# 前置（在 VPS 上一次性装好）：
#   1) Node 20+                 node -v
#   2) blackcat 依赖：cd $BLACKCAT_DIR && npm install
#   3) Playwright 浏览器：      cd $BLACKCAT_DIR && npx playwright install --with-deps chromium
#   4) 账号文件 accounts.txt（格式见 blackcat README）与 config.json 配好接码通道
#
# 建议 cron（每 6 小时刷新一次；access_token 到期前主动续）：
#   0 */6 * * *  /opt/deploy-personal/refresh-and-sync.sh >> /var/log/token-refresh.log 2>&1
# ============================================================
set -euo pipefail

# 自动定位本脚本所在目录，桥接脚本与它同目录
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 按你的实际路径修改 ----------
BLACKCAT_DIR="/opt/blackcat-relogin-dev"          # blackcat 项目目录
ACCOUNTS_FILE="$BLACKCAT_DIR/accounts.txt"        # 账号清单
SAVE_DIR="$BLACKCAT_DIR/codex_relogin"            # token JSON 输出目录
BRIDGE_JS="$DIR/blackcat-chatgpt2api-bridge.js"   # 桥接脚本（同目录）
STATE_FILE="$DIR/bridge-state.json"               # email->token 映射（运行时生成，已 gitignore）
# ----------------------------------------

# chatgpt2api 地址与管理员 key（与 .env.production 里 CHATGPT2API_AUTH_KEY 一致）
C2A_BASE_URL="https://img.example.com"            # 或 http://127.0.0.1:3000（单容器模式）
C2A_AUTH_KEY="change-me-long-random-admin-secret"

echo "===== $(date '+%F %T') token refresh start ====="

# 0) 前置检查
if [ ! -x "$(command -v node)" ]; then
  echo "[ERR] 未找到 node，请先安装 Node 20+"; exit 1
fi
if [ ! -f "$BRIDGE_JS" ]; then
  echo "[ERR] 找不到桥接脚本: $BRIDGE_JS"; exit 1
fi

# 1) blackcat：AT 失效才重登（想每次强制续命可加 --force-refresh）
cd "$BLACKCAT_DIR"
node src/cli.js refresh \
  --file "$ACCOUNTS_FILE" \
  --save-login-session \
  --save-dir "$SAVE_DIR" \
  --config config.json

# 2) 桥接：把最新 access_token 推进 chatgpt2api 账号池（旧删新加，避免重复）
node "$BRIDGE_JS" \
  --save-dir "$SAVE_DIR" \
  --base-url "$C2A_BASE_URL" \
  --auth-key "$C2A_AUTH_KEY" \
  --state-file "$STATE_FILE"

echo "===== $(date '+%F %T') token refresh done  ====="
