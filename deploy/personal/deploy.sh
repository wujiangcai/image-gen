#!/usr/bin/env bash
#
# chatgpt2api-bk · 一键部署 / 更新脚本（基于 git）
#
# 设计目标：把"项目地址（git URL）"变成可重复的部署/更新动作。
#   - 部署：服务器上 git clone 一次 image 仓库（含四个子模块，含 blackcat-relogin-dev）
#   - 更新：每次只要跑 ./deploy.sh update，就会拉最新代码 + 重建镜像
#
# 关键前提（务必先看 deploy/personal/README.md 第 2 节）：
#   chatgpt2api-bk 已是你的 fork（wujiangcai/chatgpt2api-bk），本地二开已推上。
#   blackcat-relogin-dev 是第4个子模块（GitHub 仓库 wujiangcai/re-login），用于自动补号/重登，
#   随父仓库一起 clone，无需单独在 VPS 放 /opt/blackcat-relogin-dev。
#
# 用法：
#   部署/更新：  ./deploy.sh update
#   当前版本重建：./deploy.sh deploy
#   看状态：     ./deploy.sh status
#   看日志：     ./deploy.sh logs
#
# 环境变量（可选）：
#   BK_FORK_URL   你的 bk fork 地址。设置后脚本每次会把它设为子模块地址，
#                确保服务器拉到的是"你的二开"而非上游。
#                例：BK_FORK_URL=https://github.com/wujiangcai/chatgpt2api-bk.git
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HERE/../.." && pwd)"          # image 仓库根
BK_DIR="$REPO_DIR/chatgpt2api-bk"
PROD_DIR="$BK_DIR/deploy/production"
BLACKCAT_DIR="$REPO_DIR/blackcat-relogin-dev"   # 第4个子模块：自动补号/重登

BK_FORK_URL="${BK_FORK_URL:-}"
CMD="${1:-update}"

# 未提交改动会被 git pull/checkout 覆盖，先拦一下
guard_dirty() {
  if [ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]; then
    echo "!! 仓库 $REPO_DIR 有未提交改动，先 git commit/stash 再更新，避免被覆盖。" >&2
    exit 1
  fi
}

# 确保 bk 子模块指向你的 fork（若提供）
ensure_fork() {
  if [ -n "$BK_FORK_URL" ]; then
    echo "==> 本机覆盖 chatgpt2api-bk 子模块地址: $BK_FORK_URL"
    git -C "$REPO_DIR" config submodule.chatgpt2api-bk.url "$BK_FORK_URL"
  else
    echo "==> 使用 .gitmodules 中记录的 chatgpt2api-bk 地址。"
  fi
}

case "$CMD" in
  update|deploy)
    guard_dirty
    if [ "$CMD" = "update" ]; then
      echo "==> 拉取 image 父仓库最新代码"
      git -C "$REPO_DIR" pull --ff-only
    else
      echo "==> 使用当前父仓库提交重建（不执行 git pull）"
    fi

    echo "==> 按父仓库锁定提交更新四个子模块"
    ensure_fork
    git -C "$REPO_DIR" submodule sync --recursive
    git -C "$REPO_DIR" submodule update --init --recursive

    echo "==> 确保 blackcat-relogin-dev 依赖就绪（自动补号/重登用）"
    if [ -d "$BLACKCAT_DIR" ]; then
      ( cd "$BLACKCAT_DIR" && npm ci --no-audit --no-fund >/dev/null 2>&1 \
        && echo "OK: blackcat npm 依赖已就绪" ) \
        || echo "!! blackcat npm install 失败，请手动: cd $BLACKCAT_DIR && npm install"
      # Playwright 浏览器只需装一次（需 root + apt）；失败不阻断主流程
      ( cd "$BLACKCAT_DIR" && npx playwright install chromium >/dev/null 2>&1 \
        && echo "OK: playwright chromium 已就绪" ) \
        || echo "!! 若需浏览器兜底，请手动: cd $BLACKCAT_DIR && npx playwright install --with-deps chromium"
    else
      echo "!! 未找到 $BLACKCAT_DIR（blackcat 子模块未初始化？），跳过依赖安装"
    fi

    echo "==> 构建并重启 bk（生产 compose）"
    cd "$PROD_DIR"
    if [ ! -f .env.production ]; then
      echo "!! 缺少 $PROD_DIR/.env.production，跳过重启。" >&2
      echo "   请先参考 deploy/personal/.env.personal.example 创建配置后再运行 update。" >&2
      exit 1
    fi
    docker compose --env-file .env.production up -d --build

    echo "==> 执行数据库迁移"
    docker compose --env-file .env.production exec -T api sh -lc \
      'python scripts/migrate_database.py --database-url "$DATABASE_URL"'

    echo "==> 等待服务就绪并健康检查"
    sleep 8
    if curl -fsS http://127.0.0.1/health/live >/dev/null 2>&1; then
      echo "OK: /health/live 通过"
    else
      echo "!! /health/live 未通过，请查：docker compose --env-file .env.production logs -f api"
    fi
    ;;

  status)
    cd "$PROD_DIR"
    docker compose --env-file .env.production ps
    echo "---- bk 子模块当前 commit ----"
    git -C "$BK_DIR" rev-parse HEAD
    git -C "$BK_DIR" remote -v | head -2
    ;;

  logs)
    cd "$PROD_DIR"
    docker compose --env-file .env.production logs -f "${2:-api}"
    ;;

  *)
    echo "用法: $0 {update|deploy|status|logs}" >&2
    exit 1
    ;;
esac
