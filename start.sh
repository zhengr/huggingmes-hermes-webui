#!/bin/bash
set -euo pipefail

umask 0077

# ══════════════════════════════════════════════════════════════════════
# HuggingMes + Hermes WebUI — integrated Hermes Agent stack for HF Spaces
#   Based on github.com/somratpro/HuggingMes, with Hermes WebUI
#   (github.com/nesquena/hermes-webui) as the primary UI.
# ══════════════════════════════════════════════════════════════════════

APP_DIR="${HUGGINGMES_APP_DIR:-/opt/huggingmes}"
WEBUI_REPO="${HERMES_WEBUI_REPO:-/opt/hermes-webui}"
HERMES_HOME="${HERMES_HOME:-/opt/data}"

PUBLIC_PORT="${PORT:-7861}"
GATEWAY_API_PORT="${API_SERVER_PORT:-8642}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
TELEGRAM_WEBHOOK_PORT="${TELEGRAM_WEBHOOK_PORT:-8765}"
WEBUI_PORT="${HERMES_WEBUI_PORT:-8787}"

SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
BACKUP_DATASET="${BACKUP_DATASET_NAME:-huggingmes-backup}"
CF_PROXY_ENV_FILE="/tmp/huggingmes-cloudflare-proxy.env"

export HERMES_HOME
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-true}"
export API_SERVER_HOST="${API_SERVER_HOST:-127.0.0.1}"
export API_SERVER_PORT="$GATEWAY_API_PORT"
export GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_URL:-http://127.0.0.1:${GATEWAY_API_PORT}}"
export TELEGRAM_WEBHOOK_PORT
export HERMES_WEBUI_PORT="$WEBUI_PORT"

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  🪽 HuggingMes + Hermes WebUI Gateway    ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ── Unified auth: GATEWAY_TOKEN drives everything ─────────────────────
if [ -z "${API_SERVER_KEY:-}" ]; then
  if [ -n "${GATEWAY_TOKEN:-}" ]; then
    export API_SERVER_KEY="$GATEWAY_TOKEN"
  else
    API_SERVER_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
    export API_SERVER_KEY
    echo "GATEWAY_TOKEN not set - generated an ephemeral token for this boot."
  fi
fi

# Same token becomes Hermes WebUI's login password (unified auth).
if [ -n "${GATEWAY_TOKEN:-}" ]; then
  export HERMES_WEBUI_PASSWORD="${HERMES_WEBUI_PASSWORD:-$GATEWAY_TOKEN}"
fi

# ── Setup state dirs ──────────────────────────────────────────────────
mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home,plugins,webui}

# Ensure the dashboard PTY starts in the workspace dir so the desktop app's
# file browser sees a valid directory (not /opt/hermes or /).
cd "$HERMES_HOME/workspace" || cd "$HERMES_HOME"

# Rotate on-disk logs at boot. The router + WebUI + dashboard tee their
# stdout into $HERMES_HOME/logs/*.log via `tee -a`, which means without
# rotation those files grow forever and end up in the HF Dataset backup.
# Strategy: if a log is >5MB, rename to .1 (overwriting any previous .1)
# and start fresh. Cheap, deterministic, no cron needed.
if [ -d "$HERMES_HOME/logs" ]; then
  for f in "$HERMES_HOME/logs"/*.log; do
    [ -f "$f" ] || continue
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt 5242880 ]; then
      mv -f "$f" "${f}.1"
      : > "$f"
      echo "rotated $(basename "$f") ($sz bytes -> .1)"
    fi
  done
fi

# Expose hermes CLI to login shells
mkdir -p "$HERMES_HOME/.local/bin"
ln -sfn /opt/hermes/.venv/bin/hermes "$HERMES_HOME/.local/bin/hermes"

# Redirect Hermes plugin dir into volume
if [ ! -L "${HOME}/.hermes/plugins" ]; then
  mkdir -p "${HOME}/.hermes"
  rm -rf "${HOME}/.hermes/plugins"
  ln -sfn "$HERMES_HOME/plugins" "${HOME}/.hermes/plugins"
fi

# ── Restore state from HF Dataset ─────────────────────────────────────
if [ -n "${HF_TOKEN:-}" ]; then
  echo "Restoring Hermes state from HF Dataset..."
  python3 "$APP_DIR/hermes-sync.py" restore || true
else
  echo "HF_TOKEN not set - dataset persistence is disabled."
fi

# ── Cloudflare proxy (optional) ───────────────────────────────────────
CLOUDFLARE_WORKERS_TOKEN="${CLOUDFLARE_WORKERS_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
export CLOUDFLARE_WORKERS_TOKEN
if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ] || [ -n "${CLOUDFLARE_PROXY_URL:-}" ]; then
  export CLOUDFLARE_PROXY_DEBUG="${CLOUDFLARE_PROXY_DEBUG:-false}"
  echo "Preparing Cloudflare Telegram proxy..."
  python3 "$APP_DIR/cloudflare-proxy-setup.py" || echo "WARNING: Cloudflare Telegram proxy setup failed; Telegram outbound proxy will be unavailable."
  if [ -f "$CF_PROXY_ENV_FILE" ]; then
    . "$CF_PROXY_ENV_FILE"
  fi
fi

if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ]; then
  echo "Preparing Cloudflare Keepalive worker..."
  python3 "$APP_DIR/cloudflare-keepalive-setup.py" || echo "WARNING: Cloudflare Keepalive setup failed; the Space may fall asleep without periodic pings."
fi

# ── Telegram env normalisation (aliases + webhook URL + secret) ───────
if [ -n "${TELEGRAM_USER_IDS:-}" ] && [ -z "${TELEGRAM_ALLOWED_USERS:-}" ]; then
  export TELEGRAM_ALLOWED_USERS="$TELEGRAM_USER_IDS"
elif [ -n "${TELEGRAM_USER_ID:-}" ] && [ -z "${TELEGRAM_ALLOWED_USERS:-}" ]; then
  export TELEGRAM_ALLOWED_USERS="$TELEGRAM_USER_ID"
fi

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${SPACE_HOST:-}" ] && [ -z "${TELEGRAM_WEBHOOK_URL:-}" ]; then
  if [ "${TELEGRAM_MODE:-webhook}" != "polling" ]; then
    export TELEGRAM_WEBHOOK_URL="https://${SPACE_HOST}/telegram"
  fi
fi

if [ -n "${TELEGRAM_WEBHOOK_URL:-}" ] && [ -z "${TELEGRAM_WEBHOOK_SECRET:-}" ]; then
  SECRET_FILE="$HERMES_HOME/.huggingmes-telegram-webhook-secret"
  if [ -f "$SECRET_FILE" ]; then
    TELEGRAM_WEBHOOK_SECRET="$(cat "$SECRET_FILE")"
  else
    TELEGRAM_WEBHOOK_SECRET="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
    printf '%s' "$TELEGRAM_WEBHOOK_SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
  fi
  export TELEGRAM_WEBHOOK_SECRET
fi

# ── Provider-prefix mapping (HuggingMes convention) ───────────────────
MODEL_INPUT="${HERMES_MODEL:-${LLM_MODEL:-}}"
MODEL_FOR_CONFIG="$MODEL_INPUT"
PROVIDER_FOR_CONFIG="${HERMES_INFERENCE_PROVIDER:-auto}"
LLM_API_KEY="${LLM_API_KEY:-}"

if [ -n "$MODEL_INPUT" ]; then
  MODEL_PREFIX="${MODEL_INPUT%%/*}"
else
  MODEL_PREFIX=""
fi

case "$MODEL_PREFIX" in
  openrouter)
    [ -n "$LLM_API_KEY" ] && export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$LLM_API_KEY}"
    [ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="openrouter"
    MODEL_FOR_CONFIG="${MODEL_INPUT#openrouter/}"
    ;;
  huggingface|hf)
    [ -n "$LLM_API_KEY" ] && export HF_TOKEN="${HF_TOKEN:-$LLM_API_KEY}"
    [ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="huggingface"
    MODEL_FOR_CONFIG="${MODEL_INPUT#huggingface/}"
    ;;
  vercel-ai-gateway|ai-gateway)
    [ -n "$LLM_API_KEY" ] && export AI_GATEWAY_API_KEY="${AI_GATEWAY_API_KEY:-$LLM_API_KEY}"
    [ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="ai-gateway"
    MODEL_FOR_CONFIG="${MODEL_INPUT#*/}"
    ;;
  anthropic)
    [ -n "$LLM_API_KEY" ] && export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$LLM_API_KEY}"
    ;;
  openai|openai-codex)
    [ -n "$LLM_API_KEY" ] && export OPENAI_API_KEY="${OPENAI_API_KEY:-$LLM_API_KEY}"
    ;;
  google|gemini)
    [ -n "$LLM_API_KEY" ] && export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$LLM_API_KEY}" GEMINI_API_KEY="${GEMINI_API_KEY:-$LLM_API_KEY}"
    PROVIDER_FOR_CONFIG="gemini"
    MODEL_FOR_CONFIG="${MODEL_INPUT#*/}"
    ;;
  deepseek)
    [ -n "$LLM_API_KEY" ] && export DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-$LLM_API_KEY}"
    ;;
  kimi-coding|moonshot)
    [ -n "$LLM_API_KEY" ] && export KIMI_API_KEY="${KIMI_API_KEY:-$LLM_API_KEY}"
    ;;
  kimi-coding-cn|moonshot-cn|kimi-cn)
    [ -n "$LLM_API_KEY" ] && export KIMI_CN_API_KEY="${KIMI_CN_API_KEY:-$LLM_API_KEY}"
    ;;
  minimax)
    [ -n "$LLM_API_KEY" ] && export MINIMAX_API_KEY="${MINIMAX_API_KEY:-$LLM_API_KEY}"
    ;;
  minimax-cn)
    [ -n "$LLM_API_KEY" ] && export MINIMAX_CN_API_KEY="${MINIMAX_CN_API_KEY:-$LLM_API_KEY}"
    ;;
  xiaomi)
    [ -n "$LLM_API_KEY" ] && export XIAOMI_API_KEY="${XIAOMI_API_KEY:-$LLM_API_KEY}"
    ;;
  zai|z-ai|z.ai|glm)
    [ -n "$LLM_API_KEY" ] && export GLM_API_KEY="${GLM_API_KEY:-$LLM_API_KEY}"
    ;;
  arcee|arcee-ai|arceeai)
    [ -n "$LLM_API_KEY" ] && export ARCEEAI_API_KEY="${ARCEEAI_API_KEY:-$LLM_API_KEY}"
    ;;
  gmi|gmi-cloud|gmicloud)
    [ -n "$LLM_API_KEY" ] && export GMI_API_KEY="${GMI_API_KEY:-$LLM_API_KEY}"
    ;;
  alibaba|alibaba-coding-plan|alibaba_coding)
    [ -n "$LLM_API_KEY" ] && export DASHSCOPE_API_KEY="${DASHSCOPE_API_KEY:-$LLM_API_KEY}"
    ;;
  tencent-tokenhub|tencent|tokenhub|tencentmaas)
    [ -n "$LLM_API_KEY" ] && export TOKENHUB_API_KEY="${TOKENHUB_API_KEY:-$LLM_API_KEY}"
    ;;
  nvidia)
    [ -n "$LLM_API_KEY" ] && export NVIDIA_API_KEY="${NVIDIA_API_KEY:-$LLM_API_KEY}"
    ;;
  xai|grok)
    [ -n "$LLM_API_KEY" ] && export XAI_API_KEY="${XAI_API_KEY:-$LLM_API_KEY}"
    ;;
  kilocode)
    [ -n "$LLM_API_KEY" ] && export KILOCODE_API_KEY="${KILOCODE_API_KEY:-$LLM_API_KEY}"
    ;;
  opencode-zen)
    [ -n "$LLM_API_KEY" ] && export OPENCODE_ZEN_API_KEY="${OPENCODE_ZEN_API_KEY:-$LLM_API_KEY}"
    ;;
  opencode-go)
    [ -n "$LLM_API_KEY" ] && export OPENCODE_GO_API_KEY="${OPENCODE_GO_API_KEY:-$LLM_API_KEY}"
    ;;
esac

if [ -n "${CUSTOM_BASE_URL:-}" ]; then
  PROVIDER_FOR_CONFIG="${CUSTOM_PROVIDER:-custom}"
  [ -n "$LLM_API_KEY" ] && export OPENAI_API_KEY="${OPENAI_API_KEY:-$LLM_API_KEY}"
fi

export MODEL_FOR_CONFIG PROVIDER_FOR_CONFIG
export CUSTOM_BASE_URL="${CUSTOM_BASE_URL:-}"
export CUSTOM_API_KEY="${CUSTOM_API_KEY:-${LLM_API_KEY:-}}"
export CUSTOM_MODEL_CONTEXT_LENGTH="${CUSTOM_MODEL_CONTEXT_LENGTH:-131072}"
export CUSTOM_MODEL_MAX_TOKENS="${CUSTOM_MODEL_MAX_TOKENS:-8192}"
export TELEGRAM_BASE_URL="${TELEGRAM_BASE_URL:-}"
export TELEGRAM_BASE_FILE_URL="${TELEGRAM_BASE_FILE_URL:-}"

if [ -n "${CLOUDFLARE_PROXY_URL:-}" ] && [ -z "$TELEGRAM_BASE_URL" ]; then
  CLOUDFLARE_PROXY_URL="${CLOUDFLARE_PROXY_URL%/}"
  export TELEGRAM_BASE_URL="${CLOUDFLARE_PROXY_URL}/bot"
  export TELEGRAM_BASE_FILE_URL="${CLOUDFLARE_PROXY_URL}/file/bot"
fi

# ── Build Hermes config.yaml ──────────────────────────────────────────
python3 - <<'PY'
import os
from pathlib import Path
import yaml

home = Path(os.environ["HERMES_HOME"])
path = home / "config.yaml"
try:
    config = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
except FileNotFoundError:
    config = {}

model_name = os.environ.get("MODEL_FOR_CONFIG", "").strip()
provider_name = os.environ.get("PROVIDER_FOR_CONFIG", "").strip()

if model_name:
    model = config.setdefault("model", {})
    model["default"] = model_name
    if provider_name and provider_name != "auto":
        model["provider"] = provider_name
    else:
        model.pop("provider", None)
else:
    model = config.get("model", {})
    print("No LLM_MODEL/HERMES_MODEL set; leaving Hermes model config unchanged.")

custom_base = os.environ.get("CUSTOM_BASE_URL", "").strip()
if custom_base and model_name:
    model.setdefault("base_url", custom_base.rstrip("/"))
    # Do NOT write the api_key into config.yaml — it would be backed up to the
    # HF Dataset in plaintext (hermes-sync.py excludes config.yaml as
    # defense-in-depth, but the root fix is to never persist the secret).
    # Hermes reads ${OPENAI_API_KEY} (set from LLM_API_KEY above) from the
    # environment at runtime, so the key does not need to live in config.yaml.
    try:
        model.setdefault("context_length", int(os.environ.get("CUSTOM_MODEL_CONTEXT_LENGTH", "131072")))
        model.setdefault("max_tokens", int(os.environ.get("CUSTOM_MODEL_MAX_TOKENS", "8192")))
    except ValueError:
        pass

config.setdefault("terminal", {}).setdefault("cwd", os.environ.get("MESSAGING_CWD", str(home / "workspace")))
config.setdefault("compression", {}).setdefault("enabled", True)
config.setdefault("display", {}).setdefault("background_process_notifications", os.environ.get("HERMES_BACKGROUND_NOTIFICATIONS", "result"))
config.setdefault("security", {}).setdefault("redact_secrets", True)

platforms = config.setdefault("platforms", {})

if os.environ.get("TELEGRAM_BOT_TOKEN"):
    telegram = platforms.setdefault("telegram", {})
    telegram.setdefault("enabled", True)
    extra = telegram.setdefault("extra", {})
    if os.environ.get("TELEGRAM_BASE_URL"):
        extra.setdefault("base_url", os.environ["TELEGRAM_BASE_URL"])
        extra.setdefault("base_file_url", os.environ.get("TELEGRAM_BASE_FILE_URL") or os.environ["TELEGRAM_BASE_URL"])
    if os.environ.get("TELEGRAM_ALLOWED_USERS"):
        config.setdefault("telegram", {}).setdefault("allow_from", [
            item.strip()
            for item in os.environ["TELEGRAM_ALLOWED_USERS"].split(",")
            if item.strip()
        ])

path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
path.chmod(0o600)

# config.yaml now carries terminal.cwd (above), so TERMINAL_CWD in .env is
# redundant. Hermes v0.17.0 deprecated it and warns on every gateway
# start ("Deprecated .env settings detected: TERMINAL_CWD=..."). The
# dashboard Env tab / older Hermes versions may re-add it; strip it on
# every boot so the warning stays gone.
env_file = home / ".env"
if env_file.exists():
    try:
        lines = env_file.read_text(encoding="utf-8", errors="replace").splitlines()
        kept = [ln for ln in lines if not ln.strip().startswith("TERMINAL_CWD=")]
        if len(kept) != len(lines):
            env_file.write_text("\n".join(kept).rstrip() + "\n", encoding="utf-8")
            env_file.chmod(0o600)
            print(f"Removed deprecated TERMINAL_CWD from {env_file}")
    except OSError as exc:
        print(f"Warning: could not clean {env_file}: {exc}")
PY

# ── Startup summary ───────────────────────────────────────────────────
echo ""
echo "Primary UI : ${PRIMARY_UI:-webui}"
echo "Model      : ${MODEL_FOR_CONFIG:-unset}"
echo "Provider   : ${PROVIDER_FOR_CONFIG:-unset}"
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "Telegram   : enabled"
else
  echo "Telegram   : not configured"
fi
if [ -n "${HF_TOKEN:-}" ]; then
  echo "Backup     : ${BACKUP_DATASET} (poll ${SYNC_POLL_INTERVAL:-2}s, debounce ${SYNC_DEBOUNCE_SECONDS:-3}s, max ${SYNC_INTERVAL:-60}s)"
else
  echo "Backup     : disabled"
fi
if [ -n "${CLOUDFLARE_PROXY_URL:-}" ]; then
  echo "CF Proxy   : ${CLOUDFLARE_PROXY_URL}"
fi
echo "Router     : 0.0.0.0:${PUBLIC_PORT}"
echo "WebUI      : 127.0.0.1:${WEBUI_PORT}"
echo "Gateway    : 127.0.0.1:${GATEWAY_API_PORT}"
echo "Dashboard  : 127.0.0.1:${DASHBOARD_PORT}"
echo ""

# ── Graceful shutdown ─────────────────────────────────────────────────
# Stop the sync loop FIRST (so its STOP_EVENT fires and it releases the
# sync lock before we run the final sync-once), then run a single bounded
# sync, then kill the process groups of every supervised child.
graceful_shutdown() {
  echo "Shutting down..."
  if [ -n "${LOOP_PID:-}" ]; then
    kill -TERM "$LOOP_PID" 2>/dev/null || true
    # Give the loop up to 10s to drain and release the sync lock.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$LOOP_PID" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$LOOP_PID" 2>/dev/null || true
  fi
  if [ -n "${HF_TOKEN:-}" ]; then
    # Bound the final sync so a hung HF Hub call doesn't block HF's exit
    # grace period (HF SIGKILLs after ~30s on Free tier).
    timeout 25 python3 "$APP_DIR/hermes-sync.py" sync-once || echo "Warning: shutdown sync failed."
  fi
  # Kill process groups, not just job PIDs. The services are pipelines
  # (cmd | tee), so killing the subshell PID leaves hermes/tee alive and
  # the port bound. setsid (below) makes each child its own session/group
  # leader, so kill -- -PGID takes down the whole group.
  for pid in "${HEALTH_PID:-}" "${DASHBOARD_PID:-}" "${GATEWAY_PID:-}" "${WEBUI_PID:-}" "${LOOP_PID:-}"; do
    [ -n "$pid" ] || continue
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  done
  exit 0
}
trap graceful_shutdown SIGTERM SIGINT

# ── Start the public-facing router (port 7861) ────────────────────────
# setsid makes each service a session/process-group leader so graceful_shutdown
# can kill -- -PGID and take down the whole pipeline (hermes + tee), not just
# the subshell. Without this, kill $(jobs -p) left hermes bound to its port.
setsid node "$APP_DIR/health-server.js" &
HEALTH_PID=$!

# Optional startup webhook. Validate the URL is https:// (SSRF defense — an
# attacker who can set Space Variables could otherwise point this at an
# internal address) and bound the request so a hung endpoint doesn't leak a
# zombie. Failures are logged, not fatal.
if [ -n "${WEBHOOK_URL:-}" ]; then
  case "$WEBHOOK_URL" in
    https://*)
      python3 - <<'PY' >/dev/null 2>&1 &
import json, os, urllib.request
body = json.dumps({
    "event": "restart",
    "status": "success",
    "message": "HuggingMes + Hermes WebUI has started.",
    "model": os.environ.get("MODEL_FOR_CONFIG", ""),
}).encode()
req = urllib.request.Request(os.environ["WEBHOOK_URL"], data=body, method="POST",
                             headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=10).read()
PY
      ;;
    *)
      echo "WARNING: WEBHOOK_URL must start with https:// — skipping startup webhook."
      ;;
  esac
fi

# ── Launch Hermes dashboard (private; proxied via /hm/app) ────────────
echo "Launching Hermes dashboard on 127.0.0.1:${DASHBOARD_PORT}..."
setsid bash -c '(cd "$HERMES_HOME/workspace" && hermes dashboard --host 127.0.0.1 --insecure 2>&1 | tee -a "$HERMES_HOME/logs/dashboard.log")' &
DASHBOARD_PID=$!

# ── Launch Hermes gateway ─────────────────────────────────────────────
# v0.17.0 (v2026.6.19) reworked gateway supervision: "gateway run" is no
# longer documented, and "gateway restart" now probes for s6 → falls back
# to a systemd user service (→ "linger is not enabled" error). In the HF
# Space container there is no s6 and no systemd, so the only supported path
# is foreground mode: `hermes gateway`. See:
# https://hermes-agent.nousresearch.com/docs/user-guide/messaging
#
# Explicitly cd into a known-good directory before launching. The HF
# Dataset restore at the top of start.sh wipes/recreates dirs under
# $HERMES_HOME, so start.sh's inherited CWD may have been deleted — and
# v0.17.0's `hermes gateway` calls getcwd() more eagerly than the old
# `gateway run` did, producing "sh: 0: getcwd() failed: No such file or
# directory" and causing the gateway to fail/loop on startup.
mkdir -p "$HERMES_HOME/workspace" "$HERMES_HOME/logs"
echo "Launching Hermes gateway..."
setsid bash -c '(cd "$HERMES_HOME/workspace" && hermes gateway 2>&1 | tee -a "$HERMES_HOME/logs/gateway.log")' &
GATEWAY_PID=$!

GATEWAY_READY_TIMEOUT="${GATEWAY_READY_TIMEOUT:-120}"
ready=false
for ((i=0; i<GATEWAY_READY_TIMEOUT; i++)); do
  # Real HTTP probe instead of a bare TCP connect: a wedged backend can
  # accept the socket while never responding. curl -fsS returns non-zero
  # on any non-2xx or connection failure.
  if curl -fsS "$GATEWAY_HEALTH_URL/health" >/dev/null 2>&1; then
    ready=true
    break
  fi
  if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

if [ "$ready" != "true" ]; then
  echo ""
  echo "Hermes gateway failed to expose the API health port. Last 40 log lines:"
  echo "----------------------------------------"
  tail -40 "$HERMES_HOME/logs/gateway.log" || true
  exit 1
fi

# ── Launch Hermes WebUI (nesquena/hermes-webui) ───────────────────────
# Points WebUI at the already-running Hermes agent venv and persists state
# under $HERMES_HOME/webui so hermes-sync.py backs it up.
export HERMES_WEBUI_AGENT_DIR="/opt/hermes"
export HERMES_WEBUI_PYTHON="/opt/hermes/.venv/bin/python"
export HERMES_WEBUI_HOST="127.0.0.1"
export HERMES_WEBUI_PORT
export HERMES_WEBUI_STATE_DIR="${HERMES_WEBUI_STATE_DIR:-$HERMES_HOME/webui}"
export HERMES_WEBUI_DEFAULT_WORKSPACE="${HERMES_WEBUI_DEFAULT_WORKSPACE:-$HERMES_HOME/workspace}"
export HERMES_WEBUI_AUTO_INSTALL="0"
mkdir -p "$HERMES_WEBUI_STATE_DIR"

echo "Launching Hermes WebUI on 127.0.0.1:${WEBUI_PORT}..."
setsid bash -c '(cd "$WEBUI_REPO" && \
   "$HERMES_WEBUI_PYTHON" "$WEBUI_REPO/server.py" 2>&1 | \
   tee -a "$HERMES_HOME/logs/webui.log")' &
WEBUI_PID=$!

# Wait for WebUI to bind its port. Previously this was "non-fatal" (warn +
# continue), which left / broken with the router 502ing on every page load.
# Treat bind failure as fatal like the gateway: retry once after a short
# sleep, then exit 1 so HF restarts the Space.
WEBUI_READY_TIMEOUT="${WEBUI_READY_TIMEOUT:-60}"
webui_ready=false
for ((i=0; i<WEBUI_READY_TIMEOUT; i++)); do
  if curl -fsS "http://127.0.0.1:${WEBUI_PORT}/" >/dev/null 2>&1; then
    echo "Hermes WebUI is up."
    webui_ready=true
    break
  fi
  if ! kill -0 "$WEBUI_PID" 2>/dev/null; then
    echo "Warning: Hermes WebUI exited during startup. Last 20 log lines:"
    tail -20 "$HERMES_HOME/logs/webui.log" || true
    break
  fi
  sleep 1
done
if [ "$webui_ready" != "true" ]; then
  echo ""
  echo "Hermes WebUI failed to bind 127.0.0.1:${WEBUI_PORT}. Last 20 log lines:"
  echo "----------------------------------------"
  tail -20 "$HERMES_HOME/logs/webui.log" || true
  exit 1
fi

# ── Periodic backup loop ──────────────────────────────────────────────
if [ -n "${HF_TOKEN:-}" ]; then
  python3 -u "$APP_DIR/hermes-sync.py" loop &
  LOOP_PID=$!
fi

# ── Supervise all children ─────────────────────────────────────────────
# Previously we only waited on GATEWAY_PID, so if the dashboard or WebUI
# crashed after boot, the container kept "running" with a broken UI while
# /health still returned green. wait -n (bash 4.3+, present in the Debian
# base image) returns when ANY tracked child exits; we then sync + exit so
# HF restarts the whole Space rather than running half-broken.
PIDS=()
for pid in "${HEALTH_PID:-}" "${DASHBOARD_PID:-}" "${GATEWAY_PID:-}" "${WEBUI_PID:-}" "${LOOP_PID:-}"; do
  [ -n "$pid" ] && PIDS+=("$pid")
done
wait -n "${PIDS[@]}" 2>/dev/null || true
EXIT_CODE=$?

if [ -n "${HF_TOKEN:-}" ] && [ -n "${LOOP_PID:-}" ]; then
  echo "A supervised service exited - syncing state before shutdown..."
  timeout 25 python3 "$APP_DIR/hermes-sync.py" sync-once || echo "Warning: final sync failed."
fi
exit "$EXIT_CODE"
