# image

基于 ChatGPT / OpenAI 账号的图片生成服务集合。本仓库是**部署与集成的统一入口**，内含多个子项目与部署脚本。

## 三个子项目的关系（先看清，避免部署错）

本仓库用 **git 子模块** 管理三个独立项目，它们不是平级的"三个后端"，而是有主从关系：

| 目录 | 角色 | 是否你改过 | 说明 |
|---|---|---|---|
| `chatgpt2api-bk` | **主后端（核心）** | ✅ 是（你的二开） | ChatGPT-to-API 服务：图片生成 API + 账号池管理 + Web 管理台。基于 `basketikun/chatgpt2api`。**本地能生图就是它单独跑起来的**。（⚠️ 目前 GitHub 上还没有你自己的仓库，部署前必须先 Fork，见下） |
| `image-gen-demo` | 可选的对前端包装 | ✅ 是 | 暴露 8080 的轻量前端。**默认 compose 拉上游已发布镜像，不是你的二开**；要用你的二开需改 compose 指向 `chatgpt2api-bk` 子模块。个人用可不必部署它。 |
| `chat2api` | 中继库（被 image-gen-demo 用） | ❌ 否（=上游） | `LanQian528/chat2api`，把生图 prompt 转 chat completions，仅 relay 模式用到。`chatgpt2api-bk` 自身不依赖它。 |

**一句话**：`chatgpt2api-bk` 是真正干活的后端；`image-gen-demo` 是套在它外面的可选皮肤；`chat2api` 是 image-gen-demo 在 relay 模式下才用的零件。个人/小圈子部署 **只部署 `chatgpt2api-bk` 就够**。

## ⚠️ 部署前必做：给 bk 建你自己的仓库（Fork）

`chatgpt2api-bk` 现在**没有你自己的 GitHub 仓库**（远程仍是上游 `basketikun/chatgpt2api`），你的二开只在本地。服务器要拿到你的二开代码，必须：

1. GitHub 上 **Fork** `basketikun/chatgpt2api` → 得到 `https://github.com/<你的名>/chatgpt2api-bk.git`（含上游基底 `da5e0b42`）。
2. 本地推送二开：`cd chatgpt2api-bk && git remote set-url origin <你的fork> && git push -u origin main`。
3. 父仓库指向 fork：`git submodule set-url chatgpt2api-bk <你的fork>` → `git add` → `git commit` → `git push`。

> 不 Fork 直接部署：服务器只会拿到上游干净版（`da5e0b42`），**不含你的二开**。生产 compose 是 `build: context: ../..` 从本地源码构建，所以指向 fork 后 `docker compose up --build` 才会编进你的改动。

## 部署（个人/小圈子自用 · 单机 VPS）

完整步骤见 **[`deploy/personal/README.md`](deploy/personal/README.md)**。要点：

1. 先按上节 **Fork bk** 并推上去（这是"二开能上服务器"的前提）。
2. 服务器 `git clone --recurse-submodules <image仓库地址> /opt/image`。
3. 复用 `chatgpt2api-bk/deploy/production` 的生产级 compose（Caddy 自动 HTTPS + Postgres + Redis + MinIO）。
4. 用 `deploy/personal/.env.personal.example` 生成 `.env.production`（真实密钥不进 git）。
5. `docker compose up -d --build` → 跑迁移 → 上线预检。
6. 配每日备份 cron + 异地。
7. **贴地址就能更新**：以后每次改完推 GitHub，服务器跑 `./deploy/personal/deploy.sh update` 即可拉最新 + 重建（见 `deploy/personal/deploy.sh`）。
8. 可选：把 blackcat 刷 token → 同步进账号池 做成定时任务（见 personal README 第 6 节）。

生产级完整说明见 `chatgpt2api-bk/deploy/production/README.md`。

## 目录速览

```
image/
├── chatgpt2api-bk/        # 子模块：主后端 FastAPI 源码 + 生产级 compose（deploy/production）
├── image-gen-demo/       # 子模块：可选对前端包装（wujiangcai/gpt-image）
├── chat2api/             # 子模块：中继库（LanQian528/chat2api，未改）
├── deploy/
│   └── personal/         # 个人精简部署包（.env 示例 / 桥接脚本 / 刷新脚本 / deploy.sh / 部署指南）
├── .gitmodules           # 三个子模块的 GitHub 地址
└── README.md             # 本文件
```

## 安全约定

- 真实配置 `.env.production`、运行凭据 `accounts.txt` / `config.json`、运行时状态 `bridge-state.json` **均不进 git**（见 `.gitignore`）。
- `chatgpt2api-bk/config.json` 的真实 auth-key 已 `git update-index --assume-unchanged` 保护，仅留本地，不入库。
- 仅占位符的 `.env.*.example` 可安全提交。
