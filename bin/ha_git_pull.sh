#!/usr/bin/with-contenv bash
set -euo pipefail

LOG="/config/git_pull.log"
REPO="/config"
LOCK="/config/.git_pull.lock"
SSH_KEY="/config/.ssh/id_ed25519"
BRANCH="master"   # change to "main" if you ever switch branches

ts() { date "+%Y-%m-%d %H:%M:%S"; }

# Load local secrets (NOT committed)
# /config/.optionb_env should contain:
#   HA_URL="http://homeassistant:8123"
#   HA_TOKEN="YOUR_LONG_LIVED_ACCESS_TOKEN"
if [ -f /config/.optionb_env ]; then
  # shellcheck disable=SC1091
  . /config/.optionb_env
fi

notify_fail() {
  # $1 = title, $2 = message
  if [ -z "${HA_TOKEN:-}" ] || [ -z "${HA_URL:-}" ]; then
    echo "$(ts) [WARN] Notification skipped (HA_TOKEN/HA_URL not set)" >> "$LOG"
    return 0
  fi

  # Persistent notification (local, safe). Never fails the script.
  curl -sS -X POST \
    -H "Authorization: Bearer ${HA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"$1\",\"message\":\"$2\"}" \
    "${HA_URL}/api/services/persistent_notification/create" \
    >> "$LOG" 2>&1 || true
}

render_go2rtc() {
  if [ ! -f /config/go2rtc.yaml.tpl ]; then
    echo "$(ts) [WARN] go2rtc template not found; skipping render" >> "$LOG"
    return 0
  fi
  if [ ! -f /config/.go2rtc_env ]; then
    echo "$(ts) [WARN] /config/.go2rtc_env missing; skipping go2rtc render" >> "$LOG"
    return 0
  fi

  # shellcheck disable=SC1091
  . /config/.go2rtc_env

  if [ -z "${RTSP_USER:-}" ] || [ -z "${RTSP_PASS:-}" ]; then
    echo "$(ts) [WARN] RTSP_USER/RTSP_PASS not set; skipping go2rtc render" >> "$LOG"
    return 0
  fi

  sed \
    -e "s|__RTSP_USER__|${RTSP_USER}|g" \
    -e "s|__RTSP_PASS__|${RTSP_PASS}|g" \
    /config/go2rtc.yaml.tpl > /config/go2rtc.yaml

  echo "$(ts) [INFO] Rendered /config/go2rtc.yaml from template" >> "$LOG"
}

check_config_api() {
  # Uses the same endpoint as the HA UI "Check Configuration"
  # POST /api/config/core/check_config -> {"result":"valid","errors":null} or {"result":"invalid","errors":"..."} :contentReference[oaicite:1]{index=1}
  if [ -z "${HA_TOKEN:-}" ] || [ -z "${HA_URL:-}" ]; then
    echo "$(ts) [ERROR] Cannot validate config: HA_URL/HA_TOKEN not set" >> "$LOG"
    return 2
  fi

  # Capture body + HTTP code without requiring jq
  local resp http body
  resp="$(curl -sS -X POST \
    -H "Authorization: Bearer ${HA_TOKEN}" \
    -H "Content-Type: application/json" \
    -w "\n%{http_code}\n" \
    "${HA_URL}/api/config/core/check_config" 2>>"$LOG" || true)"

  http="$(printf "%s" "$resp" | tail -n 1)"
  body="$(printf "%s" "$resp" | sed '$d')"

  echo "$(ts) [INFO] Config check HTTP: $http" >> "$LOG"
  echo "$(ts) [INFO] Config check body: $body" >> "$LOG"

  if [ "$http" != "200" ]; then
    return 2
  fi

  # Determine valid/invalid
  if printf "%s" "$body" | grep -q '"result"[[:space:]]*:[[:space:]]*"valid"'; then
    return 0
  fi

  return 1
}

# Simple lock to avoid concurrent pulls
if [ -e "$LOCK" ]; then
  echo "$(ts) [WARN] Lock exists ($LOCK). Aborting." >> "$LOG"
  exit 0
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

{
  echo "============================================================"
  echo "$(ts) [INFO] Starting git pull workflow"
  echo "$(ts) [INFO] Repo: $REPO"
  echo "$(ts) [INFO] Host: $(hostname)"
  echo "$(ts) [INFO] Config validation will run after pull"
} >> "$LOG"

cd "$REPO"

# Capture current commit for rollback
PREV_COMMIT="$(git rev-parse HEAD)"
echo "$(ts) [INFO] Current commit: $PREV_COMMIT" >> "$LOG"

# Ensure SSH key is used (no key in repo)
export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"

echo "$(ts) [INFO] Fetching origin/$BRANCH..." >> "$LOG"
git fetch origin "$BRANCH" >> "$LOG" 2>&1

LOCAL="$(git rev-parse "$BRANCH")"
REMOTE="$(git rev-parse "origin/$BRANCH")"

echo "$(ts) [INFO] Local:  $LOCAL" >> "$LOG"
echo "$(ts) [INFO] Remote: $REMOTE" >> "$LOG"

if [ "$LOCAL" = "$REMOTE" ]; then
  echo "$(ts) [INFO] No changes to pull. Exiting." >> "$LOG"
  exit 0
fi

echo "$(ts) [INFO] Pulling changes (ff-only)..." >> "$LOG"
if ! git pull --ff-only origin "$BRANCH" >> "$LOG" 2>&1; then
  echo "$(ts) [ERROR] git pull failed. Keeping repo at $PREV_COMMIT" >> "$LOG"
  notify_fail "HA Git Pull: git pull FAILED" \
    "git pull failed (ff-only). Repo remains at $PREV_COMMIT. See /config/git_pull.log"
  exit 1
fi

NEW_COMMIT="$(git rev-parse HEAD)"
echo "$(ts) [INFO] New commit: $NEW_COMMIT" >> "$LOG"

# Render go2rtc.yaml from template using local secrets (after pull)
render_go2rtc

# Validate HA configuration via REST API (UI-equivalent)
echo "$(ts) [INFO] Running config validation via REST API" >> "$LOG"
if check_config_api >> "$LOG" 2>&1; then
  echo "$(ts) [INFO] Config OK. Restarting HA Core..." >> "$LOG"
  ha core restart >> "$LOG" 2>&1
  echo "$(ts) [INFO] Done." >> "$LOG"
else
  rc=$?
  echo "$(ts) [ERROR] Config validation FAILED (rc=$rc). Rolling back to $PREV_COMMIT" >> "$LOG"
  notify_fail "HA Git Pull: Config FAILED (rolled back)" \
    "Config validation failed after pulling changes. Rolled back to $PREV_COMMIT. See /config/git_pull.log"
  git reset --hard "$PREV_COMMIT" >> "$LOG" 2>&1

  # Re-render go2rtc after rollback so cameras recover too
  render_go2rtc

  echo "$(ts) [INFO] Rollback complete. Restarting HA Core to recover..." >> "$LOG"
  ha core restart >> "$LOG" 2>&1
  echo "$(ts) [INFO] Recovery done." >> "$LOG"
  exit 1
fi
