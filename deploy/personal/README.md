# image-gen 个人生产部署指南

本指南部署父仓库中的生产主线 `chatgpt2api-bk`，并可选启用 `blackcat-relogin-dev` 定时刷新 AT。目标环境为 Ubuntu 22.04/24.04 单机 VPS。

## 1. 最终架构

```text
Internet
   │ 80/443
 Caddy
   │
 chatgpt2api-bk API/Web
   ├─ PostgreSQL
   ├─ Redis
   ├─ MinIO
   └─ ChatGPT Web / 图片上游

blackcat-relogin-dev
   └─ bridge ──> /api/accounts
```

父仓库地址：<https://github.com/wujiangcai/image-gen>

四个子模块均指向个人仓库：

- `wujiangcai/chat2api-bk`
- `wujiangcai/gpt-image`
- `wujiangcai/re-login`
- `wujiangcai/chat2api`

## 2. 服务器准备

建议至少 2 vCPU、4 GB 内存、30 GB 磁盘；图片资产多时使用独立数据盘或外部 S3/R2。

```bash
sudo apt-get update
sudo apt-get install -y git curl ca-certificates openssl nodejs npm
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh
sudo usermod -aG docker "$USER"
newgrp docker
docker --version
docker compose version
node --version
```

Blackcat 要求 Node.js 20 或更高。系统仓库版本过低时，改用 NodeSource、nvm 或发行版支持的 Node 20 包。

## 3. 克隆父仓库

```bash
sudo mkdir -p /opt/image-gen
sudo chown "$USER":"$USER" /opt/image-gen
git clone --recurse-submodules \
  https://github.com/wujiangcai/image-gen.git /opt/image-gen
cd /opt/image-gen
git submodule status
```

必须看到四行，且行首没有 `-`：

```text
blackcat-relogin-dev
chat2api
chatgpt2api-bk
image-gen-demo
```

不要用 `scp -r` 上传整个开发目录，避免把本机 `.env`、AT、邮箱凭据和缓存带到服务器。

## 4. 生产配置

```bash
cd /opt/image-gen
cp deploy/personal/.env.personal.example \
  chatgpt2api-bk/deploy/production/.env.production
chmod 600 chatgpt2api-bk/deploy/production/.env.production
nano chatgpt2api-bk/deploy/production/.env.production
```

必须替换：

| 配置 | 要求 |
|---|---|
| `CADDY_SITE_ADDRESS` | 正式域名，如 `https://img.example.com` |
| `ACME_EMAIL` | 证书通知邮箱 |
| `CHATGPT2API_BASE_URL` / `APP_PUBLIC_URL` | 与正式域名一致 |
| `WEB_ALLOWED_ORIGINS` | 只列可信前端域名 |
| `CHATGPT2API_AUTH_KEY` | 长随机管理员 key |
| `POSTGRES_PASSWORD` | 长随机数据库密码，并同步更新 `DATABASE_URL` |
| `MINIO_ROOT_PASSWORD` | 长随机密码，并同步更新对象存储 secret |
| `OBJECT_STORAGE_PUBLIC_BASE_URL` | Caddy 对象存储公共路径或 CDN 域名 |

生成随机值：

```bash
openssl rand -hex 32
```

个人环境建议：

```env
REGISTRATION_ENABLED=false
IMAGE_JOB_QUEUE_BACKEND=redis
RATE_LIMIT_BACKEND=redis
IMAGE_SSE_TIMEOUT_SECONDS=180
AUTH_SESSION_COOKIE_ENABLED=true
AUTH_SESSION_COOKIE_SECURE=true
AUTH_RESPONSE_INCLUDE_TOKEN=false
```

Compose 完整变量说明见 [`chatgpt2api-bk/deploy/production/README.md`](../../chatgpt2api-bk/deploy/production/README.md)。

## 5. 启动、迁移与预检

可直接使用父仓库脚本：

```bash
cd /opt/image-gen
chmod +x deploy/personal/deploy.sh
./deploy/personal/deploy.sh update
```

脚本会：

1. 拒绝覆盖未提交工作区。
2. `git pull --ff-only` 更新父仓库。
3. 按父提交初始化四个子模块。
4. 安装 Blackcat Node 依赖。
5. 构建/启动生产 Compose。
6. 执行数据库迁移。
7. 检查 `/health/live`。

也可手动执行：

```bash
cd /opt/image-gen/chatgpt2api-bk/deploy/production
docker compose --env-file .env.production config >/dev/null
docker compose --env-file .env.production up -d --build
docker compose --env-file .env.production exec -T api sh -lc \
  'python scripts/migrate_database.py --database-url "$DATABASE_URL"'
docker compose --env-file .env.production exec -T api sh -lc \
  'python scripts/check_production_ready.py'
docker compose --env-file .env.production ps
```

健康检查：

```bash
curl -fsS https://img.example.com/health/live
curl -fsS https://img.example.com/health/ready
curl -fsS -H 'Authorization: Bearer <admin-key>' \
  'https://img.example.com/api/admin/metrics?format=prometheus'
```

## 6. 代理

在管理后台设置主后端全局代理。容器内不能用宿主机 `127.0.0.1`；使用 Docker 网桥可达的宿主机地址、`host.docker.internal`（平台支持时）或同 Compose 网络的代理服务名。

宿主机先验证：

```bash
curl -x http://proxy-host:7897 -I https://chatgpt.com/
curl -x http://proxy-host:7897 -I https://login.microsoftonline.com/
```

Blackcat 使用独立 `config.json` 的 `proxy`，会覆盖 HTTP、Graph/IMAP、Sentinel 与 Playwright。详见 [`blackcat-relogin-dev/docs/DEPLOYMENT.md`](../../blackcat-relogin-dev/docs/DEPLOYMENT.md)。

## 7. 首次业务验收

1. 打开正式域名并使用管理员 key 登录。
2. 导入一个有效 AT。
3. 刷新账号，确认邮箱、类型、状态和图片额度。
4. 创建一个异步 `gpt-image-2` 任务。
5. 确认任务 `queued` → `running` → `succeeded`。
6. 打开对象存储图片 URL。
7. 检查任务、资产、额度账本、审计、指标与告警。
8. 创建并验证备份。

最终上线签署建议运行：

```bash
cd /opt/image-gen/chatgpt2api-bk
python scripts/verify_production_deployment.py \
  --base-url https://img.example.com \
  --admin-key '<admin-key>' \
  --image-job \
  --strict-launch \
  --output launch-evidence.json \
  --upload-evidence
```

## 8. Blackcat 账号配置

```bash
cd /opt/image-gen/blackcat-relogin-dev
npm ci
npx playwright install --with-deps chromium
cp config.example.json config.json
nano config.json
nano accounts.txt
chmod 600 config.json accounts.txt
```

推荐 Outlook 四段格式：

```text
邮箱----邮箱密码----client_id----refresh_token
```

或五/六段：

```text
目标邮箱----登录邮箱----邮箱密码----client_id----refresh_token[----ChatGPT登录密码]
```

首次前台验证：

```bash
node src/cli.js refresh \
  --file accounts.txt \
  --save-login-session \
  --save-dir ./codex_relogin \
  --config config.json \
  --at-check-remote
```

## 9. 桥接 AT 到账号池

复制 gitignored 的运行配置：

```bash
cd /opt/image-gen
cp deploy/personal/token-refresh.env.example \
  deploy/personal/token-refresh.env
chmod 600 deploy/personal/token-refresh.env
nano deploy/personal/token-refresh.env
```

内容：

```env
C2A_BASE_URL=https://img.example.com
C2A_AUTH_KEY=<与 CHATGPT2API_AUTH_KEY 相同>
```

桥接干跑：

```bash
node deploy/personal/blackcat-chatgpt2api-bridge.js \
  --save-dir blackcat-relogin-dev/codex_relogin \
  --base-url https://img.example.com \
  --auth-key '<admin-key>' \
  --state-file deploy/personal/bridge-state.json \
  --dry-run
```

真实刷新同步：

```bash
chmod +x deploy/personal/refresh-and-sync.sh
./deploy/personal/refresh-and-sync.sh
```

脚本只有在删除/导入 API 返回 2xx 后才更新 `bridge-state.json`。管理员 key 不写在脚本中。

### systemd timer

`/etc/systemd/system/image-token-refresh.service`：

```ini
[Unit]
Description=Refresh ChatGPT AT and sync account pool
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=<deploy-user>
Group=<deploy-user>
WorkingDirectory=/opt/image-gen
ExecStart=/opt/image-gen/deploy/personal/refresh-and-sync.sh
UMask=0077
TimeoutStartSec=30min
```

把 `<deploy-user>` 替换为拥有 `/opt/image-gen` 的实际 Linux 用户。

`/etc/systemd/system/image-token-refresh.timer`：

```ini
[Unit]
Description=Run AT refresh every 6 hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now image-token-refresh.timer
sudo systemctl start image-token-refresh.service
journalctl -u image-token-refresh.service -n 200 --no-pager
```

## 10. 备份与恢复演练

创建并验证应用备份：

```bash
cd /opt/image-gen/chatgpt2api-bk/deploy/production
docker compose --env-file .env.production exec -T api sh -lc \
  'python scripts/backup_data.py create --database-url "$DATABASE_URL" --json'
docker compose --env-file .env.production exec -T api sh -lc \
  'python scripts/backup_data.py verify /app/data/backups/<backup>.zip --json'
```

备份还应覆盖：

- PostgreSQL 数据/转储
- MinIO/S3/R2 对象
- `.env.production`
- Blackcat `accounts.txt`、`config.json` 和 `codex_relogin/`
- `token-refresh.env`、`bridge-state.json`

敏感备份必须加密并同步到异机。每月至少做一次临时环境恢复演练。

示例 cron（每天 03:30）：

```cron
30 3 * * * cd /opt/image-gen/chatgpt2api-bk/deploy/production && docker compose --env-file .env.production exec -T api sh -lc 'python scripts/backup_data.py create --database-url "$DATABASE_URL" --json' >> /var/log/image-gen-backup.log 2>&1
```

## 11. 日常运维

```bash
cd /opt/image-gen
./deploy/personal/deploy.sh status
./deploy/personal/deploy.sh logs api

cd chatgpt2api-bk/deploy/production
docker compose --env-file .env.production logs -f api
docker compose --env-file .env.production logs -f caddy
docker compose --env-file .env.production restart api
```

至少监控：

- `/health/live`、`/health/ready`
- 可用账号数和额度
- 队列积压、dead-letter、stale running
- 图片成功率和 SSE 超时
- PostgreSQL、Redis、对象存储
- 磁盘剩余与备份年龄

## 12. 更新与回滚

更新：

```bash
cd /opt/image-gen
./deploy/personal/deploy.sh update
```

脚本使用父仓库锁定的子模块提交。开发机必须先提交/推送子仓库，再提交父仓库指针。

回滚：

```bash
cd /opt/image-gen
git log --oneline -10
git checkout <known-good-parent-commit>
git submodule sync --recursive
git submodule update --init --recursive
./deploy/personal/deploy.sh deploy
```

如果数据库迁移不向后兼容，恢复对应版本备份；不要只回滚容器代码。

## 13. 可选项目

- `image-gen-demo`：独立部署见 [`image-gen-demo/DEPLOY.md`](../../image-gen-demo/DEPLOY.md)。
- `chat2api`：独立 Chat Completions/图片工具链见 [`chat2api/docs/DEPLOYMENT.md`](../../chat2api/docs/DEPLOYMENT.md)。

两者不是主后端生产 Compose 的必需服务。

## 14. 常见故障

- 子模块目录为空：运行 `git submodule sync --recursive && git submodule update --init --recursive`。
- Caddy 无证书：检查 DNS、80/443、防火墙与 `ACME_EMAIL`。
- API unhealthy：检查 `DATABASE_URL`、Redis、迁移状态和对象存储。
- 图片卡住：检查代理、账号额度和 `IMAGE_SSE_TIMEOUT_SECONDS`。
- 容器连不上宿主机代理：不要使用容器内 `127.0.0.1`。
- AT 不刷新：检查 Outlook refresh token、IMAP/Graph 权限、代理和 Playwright Chrome。
- 桥接 401：`C2A_AUTH_KEY` 与生产管理员 key 不一致。
- 更新后版本不对：检查父仓库子模块指针，不要使用 `submodule update --remote`。
