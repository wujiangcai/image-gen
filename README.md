# image-gen

`image-gen` 是四个独立图片/账号项目的父仓库，负责锁定版本、说明架构并提供服务器部署与 AT 自动刷新脚本。核心生产后端是 `chatgpt2api-bk`。

## 1. 子仓库与职责

| 子模块 | 个人仓库 | 职责 | 推荐场景 |
|---|---|---|---|
| `chatgpt2api-bk` | <https://github.com/wujiangcai/chat2api-bk> | OpenAI 兼容图片 API、账号池、异步任务、用户/额度/订单、管理后台、PostgreSQL/Redis/对象存储 | **生产主线** |
| `image-gen-demo` | <https://github.com/wujiangcai/gpt-image> | 轻量用户门户、模型路由、服务端任务、作品库、审计 CSV、账号池管理代理 | 小团队门户/演示 |
| `blackcat-relogin-dev` | <https://github.com/wujiangcai/re-login> | Outlook/API 接码重登、Sentinel/浏览器兜底、AT 检测与刷新 | 自动维护账号池 |
| `chat2api` | <https://github.com/wujiangcai/chat2api> | Chat Completions 代理、官网图片 f/conversation 适配、Token 轮询 | 独立聊天代理/兼容链路 |

原 `chat2api` 上游为 <https://github.com/LanQian528/chat2api>，个人子仓库中配置为 `upstream`；父仓库只引用个人仓库，保证递归克隆包含全部二开。

### 推荐生产链路

```text
用户 / OpenAI SDK
        │ HTTPS
      Caddy
        │
  chatgpt2api-bk
   ├─ PostgreSQL：业务主数据
   ├─ Redis：任务队列、锁、限流
   ├─ MinIO/S3/R2：图片资产
   └─ ChatGPT Web（按代理出站）

blackcat-relogin-dev ──刷新 AT──> bridge ──导入──> 账号池
```

`image-gen-demo` 和 `chat2api` 是可独立部署的补充项目，不是生产主后端的必选依赖。

## 2. 克隆与初始化

```bash
git clone --recurse-submodules https://github.com/wujiangcai/image-gen.git
cd image-gen
git submodule status
```

若已普通 clone：

```bash
git submodule sync --recursive
git submodule update --init --recursive
```

`git submodule status` 四行均不应以 `-` 开头。父仓库锁定子模块提交；服务器更新默认使用锁定提交，而不是擅自追踪各子仓库最新分支。

## 3. 已验证功能

### Blackcat

- HTTP、Microsoft OAuth/Graph、IMAP、API 接码和 Playwright 共用 HTTP(S) 代理。
- 支持 Outlook 四段与五/六段账号格式。
- OTP 只接受 OpenAI/ChatGPT 发件域与验证码主题，避免误读旧邮件或邮件头数字。
- Sentinel Cookie 注入过滤陈旧认证状态 Cookie。
- 协议失败时真实 Chrome 浏览器兜底。
- 两个目标 Outlook 账号均完成 OTP 注册、AT 保存与远程有效性/额度刷新。

### chatgpt2api-bk

- 后端 172 项测试通过，15 项需外部服务的集成测试按设计跳过。
- 前端 ESLint、TypeScript、Next.js 静态构建通过。
- 真实 `gpt-image-2` 生图、资产保存和账号池刷新通过。
- 图片 SSE 有总超时，连接无事件时不会永久占用 Worker。

### image-gen-demo

- 29 项后端/API 测试通过。
- 首页、管理员页和共享脚本语法检查通过。
- `/livez`、鉴权健康接口、首页和管理员页本地运行冒烟通过。
- 支持任务轮询、作品隔离、使用审计、CSV 导出和持久数据卷。

### chat2api

- 图片别名与文本模型回归、敏感日志脱敏共 5 项测试通过。
- `/healthz` 本地运行冒烟通过。
- 使用目标账号 AT 和本地 `127.0.0.1:7897` 代理，真实图片 Chat Completions 请求返回 HTTP 200 与 Markdown 图片链接。

## 4. 本地测试门禁

### Blackcat

```bash
cd blackcat-relogin-dev
npm ci
npm test
npm run check
```

### 主后端

```bash
cd chatgpt2api-bk
python -m unittest discover -v

cd web
npm ci
npx eslint .
npx tsc --noEmit
npm run build
npm audit
```

后端测试必须从仓库根运行默认 discovery；不要使用 `-s test`，否则 `test/utils.py` 可能遮蔽项目 `utils` 包。

### 轻量门户

```bash
cd image-gen-demo
python -m py_compile main.py tests/test_admin_features.py
python -m unittest tests.test_admin_features -v
node --check static/auth.js
```

### Chat2api

```bash
cd chat2api
python -m py_compile app.py chatgpt/ChatService.py
python -m unittest discover -v
```

### 父仓库桥接

```bash
node --test deploy/personal/test-bridge.js
node --check deploy/personal/blackcat-chatgpt2api-bridge.js
```

## 5. 推荐服务器部署

详细步骤见 [`deploy/personal/README.md`](deploy/personal/README.md)。最短流程：

```bash
git clone --recurse-submodules https://github.com/wujiangcai/image-gen.git /opt/image-gen
cd /opt/image-gen
cp deploy/personal/.env.personal.example \
  chatgpt2api-bk/deploy/production/.env.production
# 编辑所有 change-me、域名、数据库和对象存储配置
./deploy/personal/deploy.sh update
```

生产模板位于 [`chatgpt2api-bk/deploy/production`](chatgpt2api-bk/deploy/production/README.md)，包括：

- PostgreSQL 16
- Redis 7
- MinIO
- FastAPI + 静态 Web
- Caddy HTTPS
- 数据库迁移、健康/就绪探针、指标、告警、备份与上线证据

## 6. 代理

- `blackcat-relogin-dev/config.json` 的 `proxy`：用于重登、Outlook 和 Playwright。
- `chatgpt2api-bk`：在管理后台设置全局代理；容器网络说明见其运维手册。
- `image-gen-demo/.env` 的 `OUTBOUND_HTTP_PROXY`：用于外部 Relay；内置账号池代理在 `c2a-config.json`。
- `chat2api/.env` 的 `PROXY_URL` / `EXPORT_PROXY_URL`：用于 ChatGPT 和图片/文件出口。

容器内 `127.0.0.1` 指向容器自身。宿主机代理应使用容器可达地址、`host.docker.internal`（平台支持时）或同一 Compose 网络中的服务名。本机验证使用的代理端口是 `127.0.0.1:7897`，服务器需按实际代理重新配置。

## 7. AT 自动刷新与同步

1. 在 `blackcat-relogin-dev` 创建 gitignored 的 `accounts.txt`、`config.json`。
2. 复制刷新环境模板：

```bash
cp deploy/personal/token-refresh.env.example deploy/personal/token-refresh.env
chmod 600 deploy/personal/token-refresh.env
```

3. 填写 `C2A_BASE_URL` 和与生产 `CHATGPT2API_AUTH_KEY` 相同的 `C2A_AUTH_KEY`。
4. 手动验证：

```bash
./deploy/personal/refresh-and-sync.sh
```

5. 再配置每 6 小时运行的 systemd timer 或 cron。

桥接逻辑会按邮箱记录上次导入 AT，先删除变化前的旧 Token，再导入新 Token；仅在后台 API 返回 2xx 后更新 `bridge-state.json`。

## 8. 数据与密钥

以下内容不得提交：

- Outlook 密码、client secret/refresh token、ChatGPT AT/session token
- `.env` / `.env.production` / `token-refresh.env`
- `accounts.txt`、Blackcat `config.json`
- `codex_relogin/`、`bridge-state.json`
- 数据库、对象存储资产、日志和备份

运行文件均已加入父仓库或子仓库 `.gitignore`。示例文件只能保留占位符。

## 9. 更新与回滚

开发机先在各子仓库提交并推送，再提交父仓库子模块指针：

```bash
git -C chatgpt2api-bk push origin main
git -C image-gen-demo push origin main
git -C blackcat-relogin-dev push origin main
git -C chat2api push origin main
git add chatgpt2api-bk image-gen-demo blackcat-relogin-dev chat2api .gitmodules
git commit -m "Update component revisions"
git push origin main
```

服务器：

```bash
cd /opt/image-gen
./deploy/personal/deploy.sh update
```

回滚时 checkout 已知稳定的父仓库提交，再执行：

```bash
git submodule sync --recursive
git submodule update --init --recursive
./deploy/personal/deploy.sh deploy
```

父提交同时锁定四个组件版本，可完整复现。

## 10. 文档索引

- [个人生产部署总指南](deploy/personal/README.md)
- [商业化设计与进度](COMMERCIALIZATION_DESIGN.md)
- [Blackcat 部署与代理](blackcat-relogin-dev/docs/DEPLOYMENT.md)
- [Blackcat AT 生命周期](blackcat-relogin-dev/docs/AT_LIFECYCLE.md)
- [主后端生产 Compose](chatgpt2api-bk/deploy/production/README.md)
- [主后端中文运维手册](chatgpt2api-bk/docs/OPERATIONS.zh-CN.md)
- [轻量门户部署](image-gen-demo/DEPLOY.md)
- [Chat2api 图片接入](chat2api/docs/IMAGE_INTEGRATION.md)
- [Chat2api 部署](chat2api/docs/DEPLOYMENT.md)
