# image

ChatGPT / OpenAI 账号驱动的图片生成服务集合。本仓库是**部署与集成的统一入口**，内含多个子项目与部署脚本。

## 子项目

| 目录 | 说明 |
|---|---|
| `chatgpt2api-bk` | **主后端**（推荐部署）。ChatGPT-to-API 服务：图片生成 API + 账号池管理 + Web 管理台。自带生产级 docker compose。 |
| `image-gen-demo` | 轻量前端 / 代理演示，面向终端用户的图片生成页面。 |
| `chat2api` / `oneapi` | 其它 ChatGPT/OneAPI 相关适配模块。 |

## 部署（个人/小圈子自用 · 单机 VPS）

完整步骤见 **[`deploy/personal/README.md`](deploy/personal/README.md)**。要点：

1. 复用 `chatgpt2api-bk/deploy/production` 的生产级 compose（Caddy 自动 HTTPS + Postgres + Redis + MinIO）。
2. 用 `deploy/personal/.env.personal.example` 生成 `.env.production`（真实密钥不进 git）。
3. `docker compose up -d --build` → 跑迁移 → 上线预检。
4. 配每日备份 cron + 异地。
5. 可选：把 blackcat 刷 token → 同步进账号池 做成定时任务（见 personal README 第 6 节）。

生产级完整说明见 `chatgpt2api-bk/deploy/production/README.md`。

## 目录速览

```
image/
├── chatgpt2api-bk/        # 子模块：主后端 FastAPI 源码 + 生产级 compose（deploy/production）
├── image-gen-demo/       # 轻量前端
├── deploy/
│   └── personal/         # 个人精简部署包（.env 示例 / 桥接脚本 / 刷新脚本 / 部署指南）
└── README.md             # 本文件
```

## 安全约定

- 真实配置 `.env.production`、运行凭据 `accounts.txt` / `config.json`、运行时状态 `bridge-state.json` **均不进 git**（见 `.gitignore`）。
- 仅占位符的 `.env.*.example` 可安全提交。
