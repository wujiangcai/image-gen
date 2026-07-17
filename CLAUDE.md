# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workspace overview

This directory is not itself a git repository. It contains three related projects:

- `image-gen-demo/`: the active lightweight FastAPI image-generation frontend/proxy used to expose a browser UI, user/admin keys, and a hidden upstream API key.
- `chatgpt2api-bk/`: the main `basketikun/chatgpt2api` service: FastAPI backend plus a Next.js management/image UI, account pool management, image API compatibility, and multiple storage backends.
- `chat2api/`: an upstream/legacy `LanQian528/chat2api` checkout. Treat it as reference unless the user explicitly asks to work there.

## Common commands

### `image-gen-demo/`

```bash
cd image-gen-demo
python -m venv .venv
source .venv/Scripts/activate  # Git Bash on Windows
pip install -r requirements.txt
cp .env.example .env
python main.py
```

The local app serves `http://127.0.0.1:8000`. Docker deployment for the paired `image-gen-demo` + `chatgpt2api` stack is:

```bash
cd image-gen-demo
docker compose up -d --build
docker compose logs -f image-gen-demo
docker compose logs -f chatgpt2api
docker compose down
```

### `chatgpt2api-bk/` backend

This project uses Python 3.13+ and `uv` via `pyproject.toml`/`uv.lock`.

```bash
cd chatgpt2api-bk
uv sync
CHATGPT2API_AUTH_KEY=chatgpt2api uv run python main.py
```

`main.py` starts Uvicorn on `127.0.0.1:8001` for local backend development. Many HTTP tests expect an already-running service at `http://localhost:8000` and `AUTH_KEY = chatgpt2api`, so run the service on that port when using those tests directly, for example:

```bash
CHATGPT2API_AUTH_KEY=chatgpt2api uv run uvicorn main:app --host 127.0.0.1 --port 8000
uv run python -m unittest test.test_config
uv run python -m unittest test.test_v1_images_generations.ImageGenerationsTests.test_image_generation_http
uv run python -m unittest discover -s test -p 'test_*.py'
uv run python scripts/test_storage.py
```

Storage backend checks are controlled by `STORAGE_BACKEND` (`json`, `sqlite`, `postgres`, or `git`) plus `DATABASE_URL` or Git-related environment variables when applicable.

Docker deployment for the backend image:

```bash
cd chatgpt2api-bk
docker compose up -d
docker compose logs -f app
docker compose down
```

### `chatgpt2api-bk/web/` frontend

```bash
cd chatgpt2api-bk/web
bun install
bun run dev
bun run build
bun run start
```

`package.json` does not define lint or test scripts. `bun.lock` is present, so prefer Bun for frontend dependency/script commands.

## Architecture notes

### `image-gen-demo/`

`main.py` is a single FastAPI application. It serves `static/index.html` at `/`, `static/admin.html` at `/admin`, and static assets under `/static`.

The backend has three roles:

- End-user image proxy: `/api/generate` and `/api/edits` require a bearer user/admin key stored in `_auth.json`.
- Admin/account proxy: `/api/accounts*` forwards to a configured `chatgpt2api` service using hidden `C2A_BASE`/`C2A_KEY`.
- User-key management: `/api/users*` creates and manages local `sk-app-*` keys for browser users.

Runtime mode is selected by `MODE`:

- `relay` forwards to an OpenAI-compatible Images API using `IMAGE_API_BASE`, `IMAGE_API_KEY`, and `IMAGE_MODEL`.
- `chat2api` translates image prompts into chat completions via `CHAT_API_BASE`/`CHAT_API_KEY`; image edits are not implemented in this mode.

`docker-compose.yml` in `image-gen-demo/` runs a private `chatgpt2api` container on the Docker network and exposes only `image-gen-demo` on host port `8080`.

### `chatgpt2api-bk/` backend

`main.py` imports `api.create_app()`. `api/app.py` builds the FastAPI app, adds permissive CORS, starts the limited-account watcher in the lifespan hook, mounts `/images` from `data/images`, includes the API routers, and serves the built Next.js web assets as a fallback when present.

Router boundaries:

- `api/ai.py`: OpenAI/Anthropic-compatible AI endpoints, including `/v1/images/generations`, `/v1/images/edits`, image-oriented `/v1/chat/completions`, `/v1/responses`, model listing, and streaming wrappers.
- `api/accounts.py`: account pool CRUD/refresh/import operations.
- `api/system.py`: auth/login, settings, logs, image management, proxy, CPA, and sub2api-related system routes.

Service boundaries:

- `services/chatgpt_service.py` talks to ChatGPT/OpenAI backend flows and performs image generation/editing work.
- `services/account_service.py` owns account selection, refresh, capability/quota state, and persistence calls.
- `services/auth_service.py` manages admin/user authorization keys.
- `services/config.py` loads `config.json`, environment overrides such as `CHATGPT2API_AUTH_KEY`, image retention settings, base URL, and storage backend access.
- `services/storage/` abstracts account/auth-key storage across JSON, SQLite/Postgres, and Git backends via `services/storage/factory.py`.
- `services/log_service.py`, `proxy_service.py`, `cpa_service.py`, and `sub2api_service.py` support logs, upstream proxy settings, CPA imports, and sub2api imports.

Persistent runtime state lives under `chatgpt2api-bk/data/` by default (`accounts.json`, generated images, logs, optional database files). Avoid treating files in `data/` as source code.

### `chatgpt2api-bk/web/` frontend

The frontend is a Next.js 16 / React 19 app under `web/src`. It uses App Router pages in `src/app`, shared UI in `src/components`, client API wrappers in `src/lib/api.ts`, Axios setup in `src/lib/request.ts`, and localforage-backed auth state in `src/store/auth.ts`.

`src/lib/request.ts` automatically attaches the stored bearer key to API requests and redirects 401 responses to `/login`. `src/lib/api.ts` is the typed boundary for backend calls; update it when backend route payloads change.

## Important operational context

`chatgpt2api-bk/README.md` contains explicit warnings that the project is for personal learning/security research/non-commercial technical exchange and must not be used for commercial, bulk, abusive, or illegal activity. Keep that scope in mind when changing behavior or deployment guidance.

Secrets and local state are present in this workspace (`.env`, `config.json`, `_auth.json`, `data/`). Read only what is necessary and do not print or copy secret values into responses, docs, or commits.
