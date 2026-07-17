# chatgpt2api-bk · 单机个人版部署指南

> 适用场景：**单台 VPS 一把梭 · 只部署 `chatgpt2api-bk` 主后端 · 个人/小圈子自用 · 顺带把 blackcat 账号刷新做成服务器上的自动续命。**
>
> 本目录 `deploy/personal/`（位于仓库根，独立于 `chatgpt2api-bk` 子模块）是个人自用精简部署包，复用子模块内自带的 `chatgpt2api-bk/deploy/production` 生产级 compose，只是关掉了支付/邮件/对外注册。

---

## 0. 一句话结论

你不用从零搭。`chatgpt2api-bk/deploy/production/` 里**已经有一套生产级 docker compose**（Caddy 自动 HTTPS + FastAPI + PostgreSQL + Redis + MinIO + 健康检查 + 备份 + 上线预检 + 告警）。个人自用直接复用这套、关掉注册/支付/邮件即可——这就是"最稳"的做法。本指南把它落地成照着敲能上线的步骤，并补上账号自动续命。

本目录（`deploy/personal/`）包含：

| 文件 | 作用 |
|---|---|
| `.env.personal.example` | 精简版环境变量（占位符，可提交 git），覆盖到 `chatgpt2api-bk/deploy/production/.env.production` |
| `blackcat-chatgpt2api-bridge.js` | token 同步桥接：读取 blackcat 的 JSON → 推送进账号池（旧删新加，避免重复账号） |
| `refresh-and-sync.sh` | blackcat 刷新 + 同步账号池的 cron 脚本 |
| `README.md` | 本文件 |

---

## 1. 架构（单机全栈）

```
             Internet
                │  443/80
         ┌──────▼──────┐
         │   Caddy     │  自动 HTTPS + 安全头 + 反代
         └──────┬──────┘
                │ 内网 :80
         ┌──────▼──────┐
         │  api (FastAPI)  ← 图片API + 账号池 + Web管理台
         └──┬───┬───┬──┘
            │   │   └────────────┐
    ┌───────▼┐ ┌▼─────┐   ┌──────▼──────┐
    │Postgres│ │Redis │   │   MinIO     │
    │ 账号/  │ │队列/ │   │  图片对象   │
    │ 业务库 │ │锁/限流│  │   存储      │
    └────────┘ └──────┘   └─────────────┘
数据卷：postgres_data / redis_data / minio_data / api_data / caddy_data
```

为什么个人版也用这套而不是"单容器 + json 文件"：
- **Postgres** 避免 json 文件并发写损坏，这是长期稳定的地基。
- **Redis** 让图片任务有重试/死信/超时回收，卡住的任务能自愈。
- **Caddy** 自动续 HTTPS 证书，零维护。
- 每个服务都带 `healthcheck` + `restart: unless-stopped`，挂了自动拉起。

> 想要极简：仓库根还有单容器 `docker-compose.yml`（`STORAGE_BACKEND=json`，映射 3000 端口）。省事但并发/稳定性弱，仅建议临时试用。

---

## 2. 前置准备

**VPS 建议规格**：2 核 / 4G 内存 / 40G 盘起步（MinIO 存图会长，盘按需加）。系统 Ubuntu 22.04+ / Debian 12。

安装 Docker：
```bash
curl -fsSL https://get.docker.com | sh
sudo systemctl enable --now docker
docker compose version   # 确认 compose 插件可用
```

域名（强烈建议）：把你的域名 A 记录解析到 VPS 公网 IP，例如 `img.example.com`。放行安全组/防火墙 **80、443**。

---

## 3. 部署主后端（核心步骤）

### 3.1 上传代码
把整个 `chatgpt2api-bk` 仓库传到服务器，例如 `/opt/chatgpt2api-bk`（`git clone` 你自己的仓库，或 `scp -r`）。

### 3.2 写配置
```bash
cd /opt/chatgpt2api-bk/deploy/production
# 用本指南配套的精简版覆盖更省心（deploy/personal 在仓库根，从 production 目录往上三级）：
cp ../../deploy/personal/.env.personal.example .env.production
nano .env.production
```
**必须改的项**（详见 `.env.personal.example` 注释）：
- `CADDY_SITE_ADDRESS` / `CHATGPT2API_BASE_URL` / `WEB_ALLOWED_ORIGINS` / `APP_PUBLIC_URL` → 你的域名
- `ACME_EMAIL` → 你的邮箱（Let's Encrypt 通知用）
- `CHATGPT2API_AUTH_KEY` → 管理员密钥，**长随机**：`openssl rand -hex 24`
- `POSTGRES_PASSWORD` 且同步进 `DATABASE_URL`
- `MINIO_ROOT_PASSWORD` 且同步进 `OBJECT_STORAGE_SECRET_ACCESS_KEY`
- 个人版：`REGISTRATION_ENABLED=false`（不开放注册，只你自己用 key）

> 安全提示：`.env.production` 含真实密钥，**已被仓库 `.gitignore` 忽略**，请勿提交。本目录的 `.env.personal.example` 仅占位符，可安全提交。

### 3.3 启动
```bash
docker compose --env-file .env.production up -d --build
docker compose --env-file .env.production ps    # postgres/redis/minio/api/caddy 应为 healthy/running
```

### 3.4 建库（首次必做）
```bash
docker compose --env-file .env.production exec api sh -lc \
  'python scripts/migrate_database.py --database-url "$DATABASE_URL"'
# 查看状态
docker compose --env-file .env.production exec api sh -lc \
  'python scripts/migrate_database.py --database-url "$DATABASE_URL" --status'
```

### 3.5 上线预检 + 健康校验
```bash
# 容器内严格预检（会告诉你哪些必配项还没配好）
docker compose --env-file .env.production exec api sh -lc 'python scripts/check_production_ready.py'

# 存活/就绪探针
curl -fsS https://img.example.com/health/live
curl -fsS https://img.example.com/health/ready

# 存储/队列确认（应显示 postgres / redis / minio）
curl -fsS https://img.example.com/api/storage/info
```

### 3.6 冒烟测试
1. 用管理员 key 登录 Web 管理台（`https://img.example.com`）。
2. 导入几个账号（access_token）到账号池，看 `/api/accounts` 是否刷出 email/额度。
3. 跑一次异步出图任务，确认状态到 `succeeded`，并能打开生成图 URL。

---

## 4. 稳定性加固清单（重点）

| 维度 | 措施 | 怎么做 |
|---|---|---|
| 自愈 | 容器崩溃自动重启 | compose 已 `restart: unless-stopped`，无需改 |
| 自愈 | 依赖健康才启动 | compose 已用 `depends_on: condition: service_healthy` |
| 自愈 | 卡死任务回收 | `IMAGE_JOB_STALE_RUNNING_SECONDS=900`、`IMAGE_JOB_MAX_ATTEMPTS=3` |
| 数据 | **每日备份 + 异地** | 见 §5，cron 打包 + 同步到另一台/另一个桶 |
| 数据 | 数据卷不要乱删 | `postgres_data`/`minio_data`/`api_data` 是命根子 |
| 监控 | 主动告警 | `/api/admin/alerts`、`/api/admin/metrics?format=prometheus` |
| 监控 | 磁盘水位 | `ALERT_DISK_FREE_MB=512`，MinIO 存图会涨，定期看 `df -h` |
| 安全 | 只开 80/443 | Postgres/Redis/MinIO **不要**对公网暴露端口（compose 默认只 expose 内网） |
| 安全 | 管理员 key 保密 | `CHATGPT2API_AUTH_KEY` 泄露=账号池全失守；定期轮换 |
| 安全 | 关闭对外注册 | 个人版 `REGISTRATION_ENABLED=false` |
| 可用 | 账号池不断供 | 见 §6 自动续命；单账号限流会自动切下一个 |
| 升级 | 平滑更新 | `git pull && docker compose ... up -d --build`，起不来用旧镜像回滚 |

---

## 5. 每日备份（务必配）

容器内已带 `backup_data.py`，宿主机加一条 cron 每天打包并做保留：

```bash
# crontab -e
# 每天 3:30 备份（含图片资源），脚本自身按 BACKUP_RETENTION_DAYS=30 清理
30 3 * * * cd /opt/chatgpt2api-bk/deploy/production && docker compose --env-file .env.production exec -T api sh -lc 'python scripts/backup_data.py create --database-url "$DATABASE_URL" --json' >> /var/log/c2a-backup.log 2>&1
```

验证 / 演练恢复（关键：备份没验证过等于没有）：
```bash
docker compose --env-file .env.production exec api sh -lc \
  'python scripts/backup_data.py verify /app/data/backups/<文件>.zip --json'
```

**强烈建议**：再加一条把 `data/backups/*.zip` `rsync` 到另一台机器或另一个对象存储桶——同机备份挡不住 VPS 整机丢失。

---

## 6. 账号池自动续命（对接 blackcat）

原理：image 账号池吃的是 `access_token`（短期 JWT，会过期），它自己**不会**用 session_token 续。所以由 blackcat 定时重登刷出新 token，再用桥接脚本推进账号池（旧删新加，避免重复账号）。

### 6.1 在 VPS 上装 blackcat
blackcat 是独立项目（仓库：`blackcat-relogin-dev`），传一份到 `/opt/blackcat-relogin-dev`：
```bash
cd /opt/blackcat-relogin-dev
npm install
npx playwright install --with-deps chromium   # Sentinel/浏览器兜底需要
cp config.example.json config.json            # 配好接码通道（API接码或Outlook）
# 准备 accounts.txt，格式见 blackcat README（邮箱----API链接 等）
```

### 6.2 放置续命脚本
把本目录 `deploy/personal/` 整体传到 `/opt/deploy-personal/`（含 `refresh-and-sync.sh`、`blackcat-chatgpt2api-bridge.js`、`.env.personal.example`），改脚本顶部路径与 `C2A_AUTH_KEY`：
```bash
chmod +x /opt/deploy-personal/refresh-and-sync.sh
# 先手动干跑一遍确认无误：
node /opt/deploy-personal/blackcat-chatgpt2api-bridge.js \
  --save-dir /opt/blackcat-relogin-dev/codex_relogin \
  --base-url https://img.example.com --auth-key <你的管理员key> --dry-run
```

### 6.3 定时任务
```bash
# crontab -e ——每 6 小时刷新一次，赶在 token 过期前续上
0 */6 * * * /opt/deploy-personal/refresh-and-sync.sh >> /var/log/token-refresh.log 2>&1
```

> 现实提醒：blackcat 的 refresh 是"完整重登需要邮箱验证码"，所以**接码通道必须稳定**（API 接码不掉线 / Outlook refresh_token 不失效），这才是自动续命能不能长期跑通的关键，而不是代码本身。

---

## 7. 日常运维速查

```bash
# 看状态 / 日志
docker compose --env-file .env.production ps
docker compose --env-file .env.production logs -f api
docker compose --env-file .env.production logs -f caddy

# 重启单个服务
docker compose --env-file .env.production restart api

# 更新版本（git 工作流见 §8）
cd /opt/chatgpt2api-bk && git pull
docker compose -f deploy/production/docker-compose.yml --env-file deploy/production/.env.production up -d --build

# 磁盘 / 资源
df -h ; docker system df

# 账号池健康
curl -s -H "Authorization: Bearer <key>" https://img.example.com/api/accounts | head
curl -s -H "Authorization: Bearer <key>" https://img.example.com/api/admin/alerts
```

---

## 8. 与 git 仓库协同（提交 / 更新 / 回滚）

本仓库的版本控制约定：

- ✅ **可提交**：源码、`deploy/production/*.example`、`deploy/production/docker-compose.yml`/`Caddyfile`/`README.md`、本目录 `deploy/personal/` 下的全部文件（`.env.personal.example` 仅为占位符）。
- ❌ **不提交**（已被 `.gitignore` 忽略）：`.env.production`（真实密钥）、`bridge-state.json`（运行时生成的映射）、`accounts.txt` / blackcat 的 `config.json`（运行凭据）。

常规更新流程：
```bash
git status                              # 确认只有预期文件变更
git add -A
git commit -m "deploy: 更新 xxx"
git push                               # 推到你的远端
# 服务器上：
ssh root@server
cd /opt/chatgpt2api-bk && git pull
docker compose -f deploy/production/docker-compose.yml --env-file deploy/production/.env.production up -d --build
```

回滚：
```bash
git log --oneline | head          # 找到上一个好版本 <commit>
git checkout <commit>
docker compose ... up -d --build  # 用旧镜像重建
```

---

## 9. 常见坑

- **Caddy 拿不到证书**：80/443 没放行，或域名没解析到本机 IP。先 `dig img.example.com` 确认。
- **api 一直 unhealthy**：多半是 `DATABASE_URL` 密码与 `POSTGRES_PASSWORD` 不一致，或没跑 §3.4 迁移。
- **图片能生成但打不开**：`OBJECT_STORAGE_PUBLIC_BASE_URL` 配错，或 MinIO 桶没设公共读（compose 的 minio-init 会设，检查它是否 completed）。
- **账号池老是"限流/异常"**：token 过期没续命（配 §6），或账号本身额度用尽——限流会自动轮到下一个可用账号。
- **别把 5432/6379/9000 映射到公网**：个人版保持内网 expose，只暴露 Caddy 的 80/443。
- **bridge-state.json 误提交**：已加进 `.gitignore`；若已误加，执行 `git rm --cached deploy/personal/bridge-state.json`。
