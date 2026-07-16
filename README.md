---
title: HuggingMes Hermes WebUI
emoji: 🪽
colorFrom: blue
colorTo: indigo
sdk: docker
app_port: 7861
pinned: true
license: mit
---

Run your own AI agent with a chat interface on Hugging Face Spaces — for free.

> **This is not original work.** It combines three great open-source projects into one easy-to-deploy package:
> - [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research — the AI brain
> - [Hermes WebUI](https://github.com/nesquena/hermes-webui) by @nesquena — the chat interface
> - [HuggingMes](https://github.com/somratpro/HuggingMes) by @somratpro — the Hugging Face wrapper

All credit goes to the original creators. This repo just wires them together.

---

## ⚠️ Read this before you deploy

**Hugging Face accounts are getting suspended for running this kind of always-on agent on free Spaces.** It is not hypothetical — people (myself included) have had Spaces flagged and accounts warned or suspended, sometimes with no warning and no usable appeal path.

This project runs Hermes Agent, a WebUI, and a Cloudflare keep-alive worker specifically to defeat the free-tier sleep timer. Treat it accordingly:

- **Do not deploy this on an account you cannot afford to lose.** Use a throwaway HF account, or pay for a Pro/Spaces Compute tier and follow their ToS. Do not put your main account, your models, your datasets, or your other Spaces at risk.
- **Free-tier always-on hosting of a personal agent is against the spirit (and increasingly the letter) of HF's ToS.** The Cloudflare keep-alive worker in this repo exists to keep a free Space awake 24/7 — that is the part most likely to trigger a suspension.
- **Your private backup Dataset may also be at risk.** If the account is suspended you can lose access to your chats, memory, and workspace along with the Space. Keep an off-platform backup if any of that matters to you.
- **I am not responsible if your account gets suspended.** You are. This is a personal project shared as-is; deploying it is your decision and your risk.

If you want a safer alternative, run the same stack on any cheap VPS ($2–5/mo) — the Dockerfile and `start.sh` work outside HF with minor env changes. See the discussion in the repo for migration notes.

---

## Quick Setup (5 minutes)

### 1. Duplicate the Space

[![Duplicate this Space](https://huggingface.co/datasets/huggingface/badges/resolve/main/duplicate-this-space-xl.svg)](https://huggingface.co/spaces/f4b404/hermes?duplicate=true)

Click the badge above, name your space → pick **CPU Basic (Free)** → and keep it public (else the `.hf.space` URLs won't work).

### 2. Add Your Secrets

Go to **Settings → Variables and secrets** in your new Space and add these:

| Secret | What It's For | How to Get It |
|--------|---------------|---------------|
| `GATEWAY_TOKEN` | Your password for logging into the chat | Make up any strong password |
| `HF_TOKEN` | Saves your chats and settings so they don't disappear | [Go here](https://huggingface.co/settings/tokens) → Create new token → Pick write |
| `CLOUDFLARE_WORKERS_TOKEN` | Keeps your Space awake and lets Telegram work | [Create a token here](https://dash.cloudflare.com/profile/api-tokens) choose **Edit Cloudflare Workers** template |

### 3. Add an AI Provider

Your agent needs an AI model to talk to. The simplest way is to set `LLM_MODEL` and `LLM_API_KEY` as secrets — `start.sh` parses the `provider/model` prefix and exports the right provider env var automatically:

```
LLM_MODEL=openrouter/anthropic/claude-sonnet-4
LLM_API_KEY=sk-or-...
```

Supported prefixes include `openrouter/`, `anthropic/`, `openai/`, `huggingface/` (`hf/`), `google/` (`gemini/`), `deepseek/`, `zai/` (`glm/`), `kimi-coding/` (`moonshot/`), `minimax/`, `nvidia/`, `xai/` (`grok/`), and `ollama/` (Session 2+).

Or set the provider-specific key directly (e.g. `ANTHROPIC_API_KEY`) and configure the model later at `/hm/app/config` inside your Space.

### 4. Start It Up

Hit **Restart this Space** in Hugging Face. Wait 5–8 minutes for the first build.

When you see this in the Logs tab, you're ready:
```
HuggingMes + Hermes WebUI router listening on 0.0.0.0:7861
```

Open your Space URL (`https://your-name.hf.space`) in a **new tab**, enter your `GATEWAY_TOKEN`, and start chatting.
Open the Hermes Dashboard from `https://your-name.hf.space/hm/app`.

> **Pro tip:** Bookmark the direct `*.hf.space` URL — it works better on mobile than the Hugging Face embed.

---

## What You Get

| URL | What It Is |
|-----|------------|
| `/` | **Chat UI** — main interface for talking to your agent |
| `/hm` | Status dashboard — see what's running, backup state, desktop-app token |
| `/hm/app/` | Hermes dashboard — add AI models, set up cron jobs, manage profiles, config editor |
| `/hm/logs` | In-browser log viewer (dashboard / gateway / webui logs) — no HF Pro SSH needed |
| `/hm/desktop-app-setup` | One-page setup guide for the Hermes desktop app with copy-paste token |
| `/hmd` | Passthrough to the dashboard for the Hermes desktop app (uses its own session token) |
| `/v1/*` | OpenAI-compatible API endpoint — connect other apps to your agent |
| `/telegram` | Telegram bot webhook (if you added `TELEGRAM_BOT_TOKEN`) |
| `/health` `/status` | Health probe + JSON status dump (public) |

---

## Connecting the Hermes Desktop App

The Hermes desktop app (v0.16.0+) can connect to your Space as a remote gateway. The session token is **stable across restarts**, so you configure once and it persists.

1. Open `https://your-name.hf.space/hm/desktop-app-setup` — log in with `GATEWAY_TOKEN`. It shows the Remote Gateway URL and the session token, ready to copy-paste.
2. In the desktop app: Settings → Gateway → Remote gateway.
   - URL: `https://your-name.hf.space/hmd`
   - Session token: paste from step 1.
3. Verify: WebSocket connects, chat works, model picker loads.

The token is auto-generated on first boot and persisted to your HF Dataset. To pin your own value, set `HERMES_DASHBOARD_SESSION_TOKEN` as a Space Secret.

Note: the desktop app is a **chat-first thin client** — chat and settings work remotely; the file browser and terminal panel show your *local* machine. For remote file/terminal access, use the WebUI in a browser.

---

## Your Data Is Safe (on the Space — see the disclaimer above)

When `HF_TOKEN` is set:

- All your chats, files, settings, agent memory, OAuth tokens, and config are backed up to a **private** Hugging Face Dataset within seconds of each change (change-driven, capped at 60 s).
- If the Space restarts, everything comes back exactly as you left it — including OAuth logins done via the dashboard (Claude, ChatGPT, xAI, Nous Portal, etc.), since the entire `~/.hermes` directory is backed up.
- `config.yaml` is backed up too, with `model.api_key` stripped from the staged copy before upload — the real key comes from the process environment at runtime.

**Reminder:** the dataset lives on your HF account. If the account is suspended (see the disclaimer at the top), you can lose access to it along with the Space. Keep an off-platform copy of anything you can't afford to lose.

---

## Common Issues

| Problem | Fix |
|---------|-----|
| Login keeps looping | Open the Space URL in a new tab (Hugging Face iframe blocks cookies) |
| Space goes to sleep after a few hours | Make sure `CLOUDFLARE_WORKERS_TOKEN` is set — but note this is also what tends to trigger suspensions |
| Agent doesn't reply to questions | Check that you added an AI provider API key |
| Dashboard shows blank pages | Hard-refresh and clear service workers in browser dev tools |
| `/api/model/options` 500 | Known upstream issue; use `/hm/debug/model-options-trace` to see the traceback |

---

## Want It on Your Phone?

Use the same `https://your-name.hf.space` URL on Android, then install it as a Progressive Web App (PWA), or just use the URL in any mobile browser for normal chat.

---

# 🔧 Advanced Setup & Technical Details

> **Skip this section if you just want to chat.** The steps above are enough to get started. This part is for developers, power users, and anyone who wants to customize or understand the internals.

## Optional Secrets (Power Users)

| Secret | What It Does |
|--------|--------------|
| `CLOUDFLARE_ACCOUNT_ID` | Explicit Cloudflare account ID if you have multiple |
| `TELEGRAM_BOT_TOKEN` | Enables the Telegram bridge so you can chat with Hermes from Telegram |
| `TELEGRAM_ALLOWED_USERS` | Comma-separated numeric Telegram user IDs allowed to use the bot |
| `PRIMARY_UI` | Set to `dashboard` to make `/` show the HuggingMes status page instead of the chat UI. Default is `webui`. |
| `SYNC_INTERVAL` | Backup cadence in seconds (default 600, range 60–86400) |
| `HERMES_AGENT_VERSION` | Pin the upstream Hermes Agent base image to a specific tag for reproducibility (default `latest`) |
| `BACKUP_DATASET_NAME` | Name of the private HF Dataset used for persistence (default `huggingmes-backup`) |
| `HERMES_DASHBOARD_SESSION_TOKEN` | Pin the desktop-app session token to a known value (otherwise auto-generated and persisted) |
| `WRITE_SECRETS_TO_ENV` | Opt-in (Space Variable) — materialize provider keys from env into the dashboard's `.env` so they show up in the Env tab. Default off. |

## Ollama Support

`LLM_MODEL=ollama/llama3` works out of the box. The `ollama/` prefix sets `CUSTOM_BASE_URL` to `http://127.0.0.1:11434/v1`, strips the prefix from the model name, and passes `LLM_API_KEY` through as `OPENAI_API_KEY` (Ollama ignores it).

Ollama is not bundled in the container. For a remote Ollama server:
```
LLM_MODEL=ollama/llama3
CUSTOM_BASE_URL=http://your-ollama-host:11434/v1
```

## Configure LLM Provider via Config Editor

> ### ⚠️ Provider keys go in HF Space Secrets, not the dashboard's Env tab
>
> The Hermes dashboard exposes an "Env" editor that writes to `/opt/data/.env`
> inside the container. **That file is *not* backed up to your HF Dataset.**
> On every Space sleep / rebuild the container's filesystem is wiped, the
> `.env` is gone, and your `OLLAMA_API_KEY` / `OPENROUTER_API_KEY` /
> `ANTHROPIC_API_KEY` / etc. disappear with it. The Space then 500s on the
> first chat with `Provider 'X' is set in config.yaml but no API key was
> found`.
>
> **Always add provider keys as HF Space Secrets** (Settings → Variables and
> secrets → New secret). HF injects them as env vars at boot, never writes
> them to disk on the Space, and they survive every restart.
>
> Use the dashboard's Env tab only for non-secret tweaks. The status page's
> Backup tile will show a yellow warning whenever it detects keys sitting in
> the ephemeral `.env` so you don't have to remember this on your own.
>
> If you accept the security tradeoff and want `.env` backed up anyway, set
> `SYNC_INCLUDE_ENV=1` as a Space Variable. The dataset is private, but a
> leak of that dataset URL is then a leak of every key in `.env`.

If you prefer not to add API keys as HF Secrets, you can configure providers directly in Hermes after the Space starts:

1. Open `/hm/app/config` in your Space
2. Add your provider under the `llm` section:

```yaml
llm:
  openai:
    api_key: "${OPENAI_API_KEY}"
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"
  moonshot:
    api_key: "${MOONSHOT_API_KEY}"
    base_url: "https://api.moonshot.cn/v1"
```

If you set the API keys as HF Secrets, you can reference them with `${VAR_NAME}` as shown above. Hermes supports many providers — see the [Hermes Agent docs](https://github.com/NousResearch/hermes-agent) for the full list.

## Using the API from Code

Your Space exposes an OpenAI-compatible API at `/v1/*`:

```shell
curl https://<you>-<name>.hf.space/v1/chat/completions \
  -H "Authorization: Bearer $GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "hermes",
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://<you>-<name>.hf.space/v1",
    api_key="<your GATEWAY_TOKEN>",
)
resp = client.chat.completions.create(
    model="hermes",
    messages=[{"role": "user", "content": "hello"}],
)
```

## Adding MCP Servers

MCP (Model Context Protocol) servers extend your agent's capabilities. Add them via the config editor at `/hm/app/config`:

```yaml
mcp:
  servers:
    fetch:
      command: uvx
      args: ["mcp-server-fetch"]
    filesystem:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-filesystem", "/opt/data/workspace"]
```

`uvx` and `npx` are pre-installed in the image.

## Debugging Without HF Pro SSH

HF Free tier doesn't allow SSH. Browser-based debug endpoints (all gated by `GATEWAY_TOKEN`):

| URL | What |
|-----|------|
| `/hm/logs` | List and view `dashboard.log` / `gateway.log` / `webui.log`. Append `?tail=N` to limit lines. |
| `/hm/debug/model-options` | Probes the dashboard's `/api/model/options` and shows raw HTTP status/headers/body. |
| `/hm/debug/model-options-trace` | Runs `build_models_payload()` inline with a full Python traceback — reveals the cause of the 500. |
| `/status` | JSON dump of gateway/dashboard/webui connectivity, uptime, ports, telegram config, backup status. |

## Persistence Details

When `HF_TOKEN` is set:

*   **On boot**, the Space downloads the latest snapshot from your private HF Dataset and restores it into `/opt/data/` (atomic per-entry, with rollback on failure).
*   **Every `SYNC_INTERVAL` seconds** (default 600), it detects state changes and uploads a new snapshot. The hot path prunes `node_modules`/`.venv`/`__pycache__` so it doesn't walk them every poll.
*   **On graceful shutdown** (SIGTERM, forwarded by Tini), it does one final sync before exit. A file lock prevents the loop and the shutdown sync from racing.

What gets backed up: chat sessions, agent memory, workspace files, profiles, skills, cron jobs, OAuth tokens (`~/.hermes`), and Hermes `config.yaml` (with `model.api_key` redacted from the staged copy). `config.yaml`'s secret and the Telegram webhook secret are explicitly excluded from the upload. The dataset is private to your HF account.

## Architecture

Single port (7861) Node.js router fronts multiple backends:

```
HF Space port 7861
        │
        ▼
   health-server.js  (router + auth + status page + WS proxy)
        │
        ├─► /                  → Hermes WebUI         (127.0.0.1:8787)
        ├─► /hm, /hm/logs,     → HuggingMes status    (in-process)
        │     /hm/debug/*        + log/debug viewers
        ├─► /hm/app/*          → Hermes dashboard     (127.0.0.1:9119)  [SPA-rewritten]
        ├─► /hmd/*             → Hermes dashboard     (127.0.0.1:9119)  [passthrough, desktop app]
        ├─► /v1/*              → Hermes gateway API   (127.0.0.1:8642)  [bearer auth]
        ├─► /telegram          → Telegram webhook     (127.0.0.1:8765)
        └─► /health, /status   → in-process JSON
```

`start.sh` boots Hermes Agent's gateway + dashboard + WebUI as subprocesses under Tini (PID 1, forwards SIGTERM, reaps zombies), then the router on top. A `wait -n` watchdog kills the container if any child dies after boot, so a broken UI no longer hides behind a green `/health`. `hermes-sync.py` runs the periodic HF Dataset upload loop. Cloudflare and Telegram setup runs once at boot if their respective secrets are set.

## Local Testing

```shell
git clone https://github.com/F4bC0d3/huggingmes-hermes-webui.git
cd huggingmes-hermes-webui
cp .env.example .env
# edit .env with GATEWAY_TOKEN and provider API keys (e.g., OPENAI_API_KEY, ANTHROPIC_API_KEY)
docker build -t huggingmes-hermes-webui .
docker run --rm -p 7861:7861 --env-file .env huggingmes-hermes-webui
# open http://localhost:7861
```

## Extended Troubleshooting

| Symptom | Cause / Fix |
| --- | --- |
| Account suspended / Space flagged | See the disclaimer at the top. Running always-on agents on free Spaces is being flagged as abuse. Use a throwaway account or a paid tier, or move to a VPS. |
| Build fails on `nousresearch/hermes-agent:latest` | Set `HERMES_AGENT_VERSION` to a specific tag and restart |
| Container Running but `/` returns 502 | Hermes WebUI didn't bind. Check `/hm/logs` for `webui.log` — usually missing/wrong provider API key or LLM config |
| `/v1/*` returns 401 | Need `Authorization: Bearer <GATEWAY_TOKEN>` header |
| `/api/status` 404s in logs | Cosmetic — old browser tab polling. Ignored. |
| Login loops on `/login` | Browser embedded in HF iframe blocks cookies. Open the Space in a new tab. |
| Dashboard pages blank or 404 on refresh | Should be fixed by the SPA rewriter in health-server.js. Hard-refresh and unregister service worker if cached: DevTools → Application → Service Workers → Unregister |
| Space sleeps after a few hours | Free tier limitation. Add `CLOUDFLARE_WORKERS_TOKEN` to provision a keep-alive cron worker. Note: this is also what tends to trigger suspensions. |
| Telegram bot doesn't respond | HF Spaces blocks `api.telegram.org` egress. Add `CLOUDFLARE_WORKERS_TOKEN` to auto-provision an outbound proxy |
| Two Spaces overwriting each other's backup | Set different `BACKUP_DATASET_NAME` on each |
| Agent responds but cannot answer questions | No LLM provider configured. Add provider API keys and restart, or configure via `/hm/app/config` |
| Desktop app can't connect | Token rotated? Re-fetch from `/hm/desktop-app-setup`. WebSocket Origin must match — Electron `file://` and `localhost:port` origins are allowed. |

## Credits

*   **[Nous Research](https://nousresearch.com/)** for **[Hermes Agent](https://github.com/NousResearch/hermes-agent)** — the agent runtime, the persistent memory system, the multi-provider LLM routing, the cron and skills systems. None of this exists without their work.
*   **[@nesquena](https://github.com/nesquena)** for **[Hermes WebUI](https://github.com/nesquena/hermes-webui)** — the chat interface you actually see and use. Three-panel layout, SSE streaming, slash commands, profile management, theme system, mobile responsive design — all theirs.
*   **[@somratpro](https://github.com/somratpro)** for **[HuggingMes](https://github.com/somratpro/HuggingMes)** — the HF Space packaging, the HF Dataset backup engine (`hermes-sync.py`), the Cloudflare proxy and keepalive setup, the Telegram integration, and the gateway auth wrapper.

This repo's contribution is the integration layer: a Node.js router that fronts both UIs on a single HF Space port, unified auth where one `GATEWAY_TOKEN` gates everything, a stable persisted session token for the desktop app, OAuth/token persistence across restarts, browser-based log/debug endpoints for no-SSH debugging, and a security/robustness hardening pass (WebSocket auth, Origin validation, atomic restore, Tini + watchdog, secret-redaction on backup). If you find this useful, star the upstream projects.

## License

MIT — same as all upstream projects.
