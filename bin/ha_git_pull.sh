#!/usr/bin/with-contenv bash
set -euo pipefail

LOG="/config/git_pull.log"
REPO="/config"
LOCK="/config/.git_pull.lock"
SSH_KEY="/config/.ssh/id_ed25519"

ts() { date "+%Y-%m-%d %H:%M:%S"; }

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
  echo "$(ts) [INFO] HA Core check will run after pull"
} >> "$LOG"

cd "$REPO"

# Ensure we're on master (adjust if you use main)
BRANCH="master"

# Capture current commit for rollback
PREV_COMMIT="$(git rev-parse HEAD)"
echo "$(ts) [INFO] Current commit: $PREV_COMMIT" >> "$LOG"

# Ensure SSH key is used (no key in repo)
export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"

# Update remote info & pull
echo "$(ts) [INFO] Fetching origin..." >> "$LOG"
git fetch origin "$BRANCH" >> "$LOG" 2>&1

LOCAL="$(git rev-parse "$BRANCH")"
REMOTE="$(git rev-parse "origin/$BRANCH")"

echo "$(ts) [INFO] Local:  $LOCAL" >> "$LOG"
echo "$(ts) [INFO] Remote: $REMOTE" >> "$LOG"

if [ "$LOCAL" = "$REMOTE" ]; then
  echo "$(ts) [INFO] No changes to pull. Exiting." >> "$LOG"
  exit 0
fi

echo "$(ts) [INFO] Pulling changes..." >> "$LOG"
git pull --ff-only origin "$BRANCH" >> "$LOG" 2>&1

NEW_COMMIT="$(git rev-parse HEAD)"
echo "$(ts) [INFO] New commit: $NEW_COMMIT" >> "$LOG"

# Validate HA configuration
echo "$(ts) [INFO] Running: ha core check" >> "$LOG"
if ha core check >> "$LOG" 2>&1; then
  echo "$(ts) [INFO] Config OK. Restarting HA Core..." >> "$LOG"
  ha core restart >> "$LOG" 2>&1
  echo "$(ts) [INFO] Done." >> "$LOG"
else
  echo "$(ts) [ERROR] Config check FAILED. Rolling back to $PREV_COMMIT" >> "$LOG"
  git reset --hard "$PREV_COMMIT" >> "$LOG" 2>&1
  echo "$(ts) [INFO] Rollback complete. Restarting HA Core to recover..." >> "$LOG"
  ha core restart >> "$LOG" 2>&1
  echo "$(ts) [INFO] Recovery done." >> "$LOG"
  exit 1
fi
