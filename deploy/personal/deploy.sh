#!/usr/bin/env bash
#
# chatgpt2api-bk · 一键部署 / 更新脚本（基于 git）
#
# 设计目标：把"项目地址（git URL）"变成可重复的部署/更新动作。
#   - 部署：服务器上 git clone 一次 image 仓库（含子模块）
#   - 更新：每次只要跑 ./deploy.sh update，就会拉最新代码 + 重建镜像
#
# 关键前提（务必先看 deploy/personal/README.md 第 2 节）：
#   chatgpt2api-bk 目前没有自己的 GitHub 仓库，必须先在 GitHub Fork
#   basketikun/chatgpt2api，并把本地二开推上去。否则服务器拿到的只是
#   上游干净版（da5e0b42），不含你的二开代码。
#
# 用法：
#   部署/更新：  ./deploy.sh update
#   看状态：     ./deploy.sh status
#   看日志：     ./deploy.sh logs
#
# 环境变量（可选）：
#   BK_FORK_URL   你的 bk fork 地址。设置后脚本每次会把它设为子模块地址，
#                确保服务器拉到的是"你的二开"而非上游。
#                例：BK_FORK_URL=https://github.com/wujiangcai/chatgpt2api-bk.git
#   GIT_URL       image 父仓库地址（首次 clone 用）。默认见下。
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HERE/../.." && pwd)"          # image 仓库根
BK_DIR="$REPO_DIR/chatgpt2api-bk"
PROD_DIR="$BK_DIR/deploy/production"

GIT_URL="${GIT_URL:-https://github.com/wujiangcai/image.git}"
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
    echo "==> 将子模块 chatgpt2api-bk 指向 fork: $BK_FORK_URL"
    git -C "$REPO_DIR" submodule set-url chatgpt2api-bk "$BK_FORK_URL"
  else
    echo "==> 未设置 BK_FORK_URL：将使用 .gitmodules 中记录的地址。"
    echo "    （若 .gitmodules 仍指向上游 basketikun，服务器只会拿到上游干净版，不含你的二开）"
  fi
}

case "$CMD" in
  update)
    guard_dirty
    echo "==> 拉取 image 父仓库最新代码"
    git -C "$REPO_DIR" pull --ff-only

    echo "==> 更新子模块（含 bk 二开）"
    ensure_fork
    git -C "$REPO_DIR" submodule update --init --remote --recursive

    echo "==> 构建并重启 bk（生产 compose）"
    cd "$PROD_DIR"
    if [ ! -f .env.production ]; then
      echo "!! 缺少 $PROD_DIR/.env.production，跳过重启。" >&2
      echo "   请先参考 deploy/personal/.env.personal.example 创建配置后再运行 update。" >&2
      exit 1
    fi
    docker compose --env-file .env.production up -d --build

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
    echo "用法: $0 {update|status|logs}" >&2
    exit 1
    ;;
esac
