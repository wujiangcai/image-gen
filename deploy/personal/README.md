# chatgpt2api-bk · 单机个人版部署指南

> 适用场景：**单台 VPS 一把梭 · 主要是 `chatgpt2api-bk` 主后端 · 个人/小圈子自用 · 顺带把 blackcat 账号刷新做成服务器上的自动续命。**
>
> 本目录 `deploy/personal/`（位于仓库根，独立于 `chatgpt2api-bk` 子模块）是个人自用精简部署包，复用子模块内自带的 `chatgpt2api-bk/deploy/production` 生产级 compose，只是关掉了支付/邮件/对外注册。

---

## 0. 先回答三个常见问题

**Q1：项目是怎么启动的？bk 是后端吗？**
**是的，`chatgpt2api-bk` 就是主后端。** 它是 FastAPI 应用（`main.py` → `create_app()`），自带：账号池、Web 管理台 UI、图片生成 API。你本地"能正常生图"就是它单独跑起来（端口 8000）的结果。本地启动方式：
```bash
cd chatgpt2api-bk
STORAGE_BACKEND=json .venv/Scripts/python.exe -m uvicorn main:app --host 127.0.0.1 --port 8000
```
服务器上则用它的生产 compose（Docker，见 §3），更稳定。

**Q2：image-gen-demo 和 chat2api 又是什么？**
- `image-gen-demo`（子模块 `wujiangcai/gpt-image`）：一个**对外轻量前端/包装**（暴露 8080）。⚠️ 它默认的 `docker-compose.yml` 拉的是**上游已发布镜像** `ghcr.io/basketikun/chatgpt2api:latest`，**不是你本地二开的代码**。也就是说：只用 image-gen-demo 而不改它的 compose，服务器跑的是上游干净版。
- `chat2api`（子模块 `LanQian528/chat2api`）：一个 ChatGPT→API **中继库**，你没改它（=上游）。它只在 image-gen-demo 的 "relay/chat2api 模式" 下，用来把生图 prompt 转成 chat completions。`chatgpt2api-bk` 自身**不依赖** chat2api（bk 自带 `chatgpt_service`）。

**结论（个人用什么）**：直接用 `chatgpt2api-bk` 即可（已验证可生图、含账号池+管理台）。`image-gen-demo` 是可选的更友好公开 UI，**且必须改成 build 你自己的 bk fork** 才能用上你的二开（见 §10）。

**Q3：bk 现在没有自己的 GitHub 仓库，怎么办？要新建吗？**
**不要建空白仓库，要 Fork。** 详见 §2。一句话：在 GitHub 上 Fork `basketikun/chatgpt2api` → 把本地二开推上去 → 父仓库子模块指向你的 fork。这样服务器 `docker compose up --build` 才会编进你的二开（生产 compose 是 `build: context: ../..`，从本地源码构建）。

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
         │  api (FastAPI / chatgpt2api-bk)  ← 图片API + 账号池 + Web管理台
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

## 2. 把 bk 变成你自己的仓库（Fork，关键步骤）

`chatgpt2api-bk` 目前远程是上游 `basketikun/chatgpt2api`，你的本地二开（2 个提交 `a2899b2` + `6a013bc`）**还没推到任何 GitHub 仓库**。服务器要拿到你的二开，必须先把 bk 变成你自己的仓库：

**① 在 GitHub 上 Fork**
打开 https://github.com/basketikun/chatgpt2api → 点 Fork → 得到 `https://github.com/<你的名>/chatgpt2api-bk.git`（含上游基底 commit `da5e0b42`）。

**② 本地推送二开**
```bash
cd chatgpt2api-bk
git remote set-url origin https://github.com/<你的名>/chatgpt2api-bk.git
git push -u origin main      # 推 6a013bc，auth-key 已是占位符，安全
```
> 若 push 被拒（fork 默认分支名不同），按提示 `git push -u origin HEAD:<fork默认分支>`。

**③ 让父仓库 image 指向你的 fork（推荐，否则别人/服务器 clone 到的还是上游）**
```bash
cd image
git submodule set-url chatgpt2api-bk https://github.com/<你的名>/chatgpt2api-bk.git
git add chatgpt2api-bk .gitmodules
git commit -m "chore: chatgpt2api-bk 指向我的 fork"
git push
```
> 做过 ③ 后，服务器 clone 时子模块就直接是 fork；没做 ③ 也行，但服务器跑 `deploy.sh` 时必须带 `BK_FORK_URL=...`（见 §3.7）。

**④（可选）image-gen-demo / chat2api**
- `image-gen-demo` 你已有 `wujiangcai/gpt-image`，直接推。
- `chat2api` 是别人的仓库，你没改，**保持引用上游即可，不要推**。

---

## 3. 部署主后端（核心步骤）

### 3.1 把代码弄到服务器
两种方式，任选其一：

**方式 A（推荐，git 驱动）—— 贴项目地址就能部署/更新**
```bash
# 在服务器上，克隆 image 父仓库（含三个子模块）
git clone --recurse-submodules https://github.com/<你的名>/image.git /opt/image
cd /opt/image
# 若父仓库 .gitmodules 已指向你的 fork（做过 §2③），直接：
./deploy/personal/deploy.sh update
# 若还没改 .gitmodules，用环境变量临时指定 fork：
BK_FORK_URL=https://github.com/<你的名>/chatgpt2api-bk.git ./deploy/personal/deploy.sh update
```

**方式 B（手动上传）**
```bash
# 把整个 image 仓库（含子模块）传到 /opt/image，例如：
scp -r /c/Users/caiwujiang/Desktop/image root@<服务器IP>:/opt/image
# 或分别 git clone 三个子模块到对应目录
```

### 3.2 写配置
```bash
cd /opt/image/chatgpt2api-bk/deploy/production
# 用本指南配套的精简版覆盖更省心：
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
> 密钥最佳实践：用环境变量 `CHATGPT2API_AUTH_KEY` 启动时传入，避免把 key 写进 `config.json`。本机 `config.json` 已 `git update-index --assume-unchanged` 保护，不会入库。

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

### 3.7 后续更新（贴地址就能更新）
以后每次改完代码推到 GitHub，服务器只要：
```bash
cd /opt/image
# 若 .gitmodules 已指向 fork：
./deploy/personal/deploy.sh update
# 否则：
BK_FORK_URL=https://github.com/<你的名>/chatgpt2api-bk.git ./deploy/personal/deploy.sh update
```
脚本会：拉父仓库最新 → 更新子模块（含你的 bk 二开）→ 重建并重启 → 健康检查。
这就是"贴项目地址能部署更新"的落地方式：**地址 = git URL，更新 = 一次 `deploy.sh update`**。

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
| 升级 | 平滑更新 | `./deploy.sh update`，起不来用旧镜像回滚 |

---

## 5. 每日备份（务必配）

容器内已带 `backup_data.py`，宿主机加一条 cron 每天打包并做保留：

```bash
# crontab -e
# 每天 3:30 备份（含图片资源），脚本自身按 BACKUP_RETENTION_DAYS=30 清理
30 3 * * * cd /opt/image/chatgpt2api-bk/deploy/production && docker compose --env-file .env.production exec -T api sh -lc 'python scripts/backup_data.py create --database-url "$DATABASE_URL" --json' >> /var/log/c2a-backup.log 2>&1
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

# 更新版本（git 工作流见 §8，脚本见 §3.7）
./deploy/personal/deploy.sh update

# 磁盘 / 资源
df -h ; docker system df

# 账号池健康
curl -s -H "Authorization: Bearer <key>" https://img.example.com/api/accounts | head
curl -s -H "Authorization: Bearer <key>" https://img.example.com/api/admin/alerts
```

---

## 8. 与 git 仓库协同（提交 / 更新 / 回滚）

本仓库的版本控制约定：

- ✅ **可提交**：源码、`deploy/production/*.example`、`deploy/production/docker-compose.yml`/`Caddyfile`/`README.md`、本目录 `deploy/personal/` 下的全部文件（`.env.personal.example` 仅为占位符）、父仓库 `README.md` / `.gitmodules`。
- ❌ **不提交**（已被 `.gitignore` 忽略）：`.env.production`（真实密钥）、`bridge-state.json`（运行时生成的映射）、`accounts.txt` / blackcat 的 `config.json`（运行凭据）、`chatgpt2api-bk/config.json`（真实 auth-key，已 `assume-unchanged`）。

常规更新流程（开发机）：
```bash
# 改完代码后
git status                              # 确认只有预期文件变更
git add -A
git commit -m "feat: 更新 xxx"
git push                               # 推到你的远端

# 若改的是 bk 子模块，进入子模块再 push：
cd chatgpt2api-bk && git add -A && git commit -m "..." && git push
# 父仓库记录新的子模块指针：
cd .. && git add chatgpt2api-bk && git commit -m "bump bk" && git push
```

服务器更新（见 §3.7）：`./deploy/personal/deploy.sh update`

回滚：
```bash
git log --oneline | head          # 找到上一个好版本 <commit>
git checkout <commit>
./deploy/personal/deploy.sh update  # 用旧镜像重建
```

---

## 9. 常见坑

- **Caddy 拿不到证书**：80/443 没放行，或域名没解析到本机 IP。先 `dig img.example.com` 确认。
- **api 一直 unhealthy**：多半是 `DATABASE_URL` 密码与 `POSTGRES_PASSWORD` 不一致，或没跑 §3.4 迁移。
- **图片能生成但打不开**：`OBJECT_STORAGE_PUBLIC_BASE_URL` 配错，或 MinIO 桶没设公共读（compose 的 minio-init 会设，检查它是否 completed）。
- **账号池老是"限流/异常"**：token 过期没续命（配 §6），或账号本身额度用尽——限流会自动轮到下一个可用账号。
- **别把 5432/6379/9000 映射到公网**：个人版保持内网 expose，只暴露 Caddy 的 80/443。
- **bridge-state.json 误提交**：已加进 `.gitignore`；若已误加，执行 `git rm --cached deploy/personal/bridge-state.json`。
- **服务器跑的是上游干净版（不含二开）**：忘了 §2 的 Fork + 子模块指向 fork。检查 `git -C chatgpt2api-bk remote -v` 是否指向你的 fork；不是就重做 §2③ 或部署时带 `BK_FORK_URL`。
- **本地改了 bk 但没生效**：`config.json` 被 `assume-unchanged` 保护，改它不会进提交；改源码（`api/`、`services/`、`web/`）才会随 `git push` + `deploy.sh update` 上服务器。

---

## 10. 可选：用 image-gen-demo 作公开前端（需改 compose）

如果你想要一个更友好的对外页面（暴露 8080），可以用 `image-gen-demo` 包住 bk。**但它的默认 compose 拉的是上游镜像，不会用你的二开**，必须改成 build 你的 fork：

```yaml
# image-gen-demo/docker-compose.yml 修改 chatgpt2api 服务：
services:
  chatgpt2api:
    build:
      context: ../chatgpt2api-bk      # 改用你的子模块源码，而非 ghcr.io 上游镜像
      dockerfile: Dockerfile
    image: chatgpt2api:local
    container_name: chatgpt2api
    restart: unless-stopped
    volumes:
      - ./c2a-data:/app/data
      - ./c2a-config.json:/app/config.json:ro
    environment:
      - STORAGE_BACKEND=json
      - CHATGPT2API_AUTH_KEY=${C2A_KEY}
```
其余 image-gen-demo 的环境变量（`C2A_BASE=http://chatgpt2api:80`、`C2A_KEY`、`IMAGE_API_BASE=http://chatgpt2api:80/v1/images`）不变。这样公开页就用上了你的二开后端。

> 个人/小圈子用，直接部署 §3 的 bk 就够了，不必折腾这一节。
