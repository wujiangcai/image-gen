#!/usr/bin/env bash
# ============================================================
# blackcat 重登刷新 access_token -> 同步进 chatgpt2api 账号池
# 供 VPS 上 cron / systemd timer 定时调用，实现账号池自动续命。
#
# 放置：本目录 (deploy/personal) 随 image 父仓库一起 clone 到 VPS（例如 /opt/image/deploy/personal）。
#       chmod +x /opt/image/deploy/personal/refresh-and-sync.sh
#       桥接脚本 blackcat-chatgpt2api-bridge.js 与本脚本同目录；blackcat 现作为 image 第4个子模块，
#       脚本用 DIR 自动定位 image 根，再定位 blackcat-relogin-dev 子模块，无需手改路径。
#
# 前置（在 VPS 上一次性装好，blackcat 已随 image clone，无需单独下载）：
#   1) Node 20+                 node -v
#   2) blackcat 依赖：cd $IMAGE_DIR/blackcat-relogin-dev && npm install
#   3) Playwright 浏览器：      cd $IMAGE_DIR/blackcat-relogin-dev && npx playwright install --with-deps chromium
#   4) 账号文件 accounts.txt 与 config.json（从 config.example.json 复制）配好接码通道，放在 blackcat 子模块目录
#   注：accounts.txt / config.json 已被 blackcat 的 .gitignore 忽略，不会进版本库，属本地运行凭据。
#
# 建议 cron（每 6 小时刷新一次；access_token 到期前主动续）：
#   0 */6 * * *  /opt/image/deploy/personal/refresh-and-sync.sh >> /var/log/token-refresh.log 2>&1
# ============================================================
set -euo pipefail

# 自动定位本脚本所在目录，桥接脚本与它同目录
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 路径（blackcat 现作为 image 第4个子模块，自动定位，无需手改） ----------
IMAGE_DIR="$(cd "$DIR/../.." && pwd)"             # image 父仓库根
BLACKCAT_DIR="$IMAGE_DIR/blackcat-relogin-dev"    # blackcat 子模块目录
ACCOUNTS_FILE="$BLACKCAT_DIR/accounts.txt"        # 账号清单（gitignored，需自建）
SAVE_DIR="$BLACKCAT_DIR/codex_relogin"            # token JSON 输出目录（gitignored）
BRIDGE_JS="$DIR/blackcat-chatgpt2api-bridge.js"   # 桥接脚本（同目录）
STATE_FILE="$DIR/bridge-state.json"               # email->token 映射（运行时生成，已 gitignore）
# ----------------------------------------

# 运行凭据从 gitignored 文件或进程环境读取，避免把管理员 key 写进脚本。
TOKEN_REFRESH_ENV_FILE="${TOKEN_REFRESH_ENV_FILE:-$DIR/token-refresh.env}"
if [ -f "$TOKEN_REFRESH_ENV_FILE" ]; then
  # 文件格式为 shell KEY=value；权限建议 chmod 600。
  set -a
  # shellcheck disable=SC1090
  . "$TOKEN_REFRESH_ENV_FILE"
  set +a
fi
C2A_BASE_URL="${C2A_BASE_URL:-http://127.0.0.1}"
: "${C2A_AUTH_KEY:?请在 token-refresh.env 或环境变量中设置 C2A_AUTH_KEY}"

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
  --at-check-remote \
  --save-dir "$SAVE_DIR" \
  --config config.json

# 2) 桥接：把最新 access_token 推进 chatgpt2api 账号池（旧删新加，避免重复）
node "$BRIDGE_JS" \
  --save-dir "$SAVE_DIR" \
  --base-url "$C2A_BASE_URL" \
  --auth-key "$C2A_AUTH_KEY" \
  --state-file "$STATE_FILE"

echo "===== $(date '+%F %T') token refresh done  ====="
