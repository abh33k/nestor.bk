#!/usr/bin/env bash
# GitHub Backup Runner
# Called by GitHub Actions or manual run
set -euo pipefail

# Load .env if present (workspace root)
if [ -f "$(dirname "$0")/.env" ]; then
  set -a
  source "$(dirname "$0")/.env"
  set +a
fi

BACKUP_SOURCE="${HOME}/.openclaw/workspace"
GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_PAT="${GITHUB_PAT:-}"
COMMIT_AUTHOR="${COMMIT_AUTHOR:-Nestor <nestor@openclaw>}"
REDACT_PLACEHOLDER="[REDACTED]"

# If PAT is provided, convert SSH URL to HTTPS with PAT embedded
if [ -n "$GITHUB_PAT" ] && [[ "$GITHUB_REPO" == git@github.com:* ]]; then
  GITHUB_REPO_HTTPS="https://${GITHUB_PAT}@github.com/$(echo "$GITHUB_REPO" | sed 's/git@github.com:\(.*\)\.git/\1/')"
else
  GITHUB_REPO_HTTPS="$GITHUB_REPO"
fi

CHANGES_PUSHED="no"

if [ -z "$GITHUB_REPO" ]; then
  echo "ERROR: GITHUB_REPO environment variable not set"
  exit 1
fi

# Discord notification helper
send_discord() {
  local msg="$1"
  if command -v openclaw >/dev/null 2>&1; then
    echo "--> Discord notification: $msg"
    /home/abheek/.npm-global/bin/openclaw message send --channel discord --target "channel:$DISCORD_MONITORING_CHANNEL" --message "$msg" 2>/dev/null || true
  else
    echo "--> (openclaw CLI not available, skipping Discord notification)"
  fi
}

# Trap errors to send Discord notification
_trap_err() {
  local exit_code=$?
  echo "ERROR: Backup failed with exit code $exit_code"
  send_discord "❌ OpenClaw backup FAILED at $(TZ=Asia/Singapore date). Check logs."
  rm -rf "$backup_dir" 2>/dev/null || true
  exit $exit_code
}
trap _trap_err ERR

timestamp=$(TZ=Asia/Singapore date +%Y-%m-%d_%H-%M-%S)
backup_dir="/tmp/openclaw-backup-$timestamp"
mkdir -p "$backup_dir"

echo "==> Starting OpenClaw workspace backup to $GITHUB_REPO"
echo "    Source: $BACKUP_SOURCE"
echo "    Temp:   $backup_dir"

# Function to copy critical files preserving directory structure
copy_critical() {
  echo "--> Copying critical files..."

  # Core workspace files
  for file in \
    "SOUL.md" \
    "MEMORY.md" \
    "USER.md" \
    "IDENTITY.md" \
    "AGENTS.md" \
    "HEARTBEAT.md" \
    "TOOLS.md" \
    "daily-maintenance.sh"
  do
    if [ -f "$BACKUP_SOURCE/$file" ]; then
      mkdir -p "$backup_dir/$(dirname "$file")"
      cp "$BACKUP_SOURCE/$file" "$backup_dir/$file"
    fi
  done

  # Memory directory
  if [ -d "$BACKUP_SOURCE/memory" ]; then
    cp -r "$BACKUP_SOURCE/memory" "$backup_dir/"
  fi

  # .openclaw workspace config (not credentials)
  if [ -d "$BACKUP_SOURCE/.openclaw" ]; then
    mkdir -p "$backup_dir/.openclaw"
    # Copy only safe config files (exclude credentials/identity/devices)
    for file in workspace-state.json; do
      if [ -f "$BACKUP_SOURCE/.openclaw/$file" ]; then
        cp "$BACKUP_SOURCE/.openclaw/$file" "$backup_dir/.openclaw/$file"
      fi
    done
  fi

  # State directory
  if [ -d "$BACKUP_SOURCE/state" ]; then
    cp -r "$BACKUP_SOURCE/state" "$backup_dir/"
  fi

  # Agent configurations (main agent) - copy entire directory
  if [ -d "$HOME/.openclaw/agents/main/agent" ]; then
    mkdir -p "$backup_dir/agents/main"
    cp -r "$HOME/.openclaw/agents/main/agent" "$backup_dir/agents/main/"
  fi

  # Cron jobs (user crontab)
  crontab -l 2>/dev/null > "$backup_dir/crontab.txt" || echo "# No crontab" > "$backup_dir/crontab.txt"

  # OpenClaw global config (will be redacted)
  if [ -f "$HOME/.openclaw/openclaw.json" ]; then
    cp "$HOME/.openclaw/openclaw.json" "$backup_dir/"
  fi

  # Exec approvals (for audit trail, redacted)
  if [ -f "$HOME/.openclaw/exec-approvals.json" ]; then
    cp "$HOME/.openclaw/exec-approvals.json" "$backup_dir/"
  fi

  # Any custom scripts in workspace root besides daily-maintenance.sh
  for script in "$BACKUP_SOURCE"/*.sh; do
    [ -f "$script" ] && cp "$script" "$backup_dir/"
  done

  echo "    Copied files:"
  find "$backup_dir" -type f | sed 's/^/      /'
}

# Secret scanning and redaction
redact_secrets() {
  echo "--> Scanning and redacting secrets..."

  # Patterns for common secrets (improve as needed)
  # This is a basic set; you can extend it
  declare -a patterns=(
    'Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9_\-\.]+'   # Bearer tokens
    'api[_-]?key["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9]{32,}["'"'"']?'  # API keys
    'token["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9_\-\.]{20,}["'"'"']?'    # tokens
    'password["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[^"'"'"'\n]{8,}'                 # passwords
    'secret["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[^"'"'"'\n]{8,}'                  # secrets
    'sk_live_[A-Za-z0-9]+'   # Stripe secret key
    'sk-or-v1-[A-Za-z0-9]+'   # OpenAI secret key
    'pk_live_[A-Za-z0-9]+'   # Stripe public key
    'AIza[A-Za-z0-9_\-]+'    # Google API key
    'xox[baprs]-[0-9]{12}-[0-9]{12}-[0-9A-Za-z]+'  # Slack tokens
    'ghp_[A-Za-z0-9]{36}'    # GitHub Personal Access Token
    '8744197825:[A-Za-z0-9_-]{35}'  # Telegram bot token
    'github_pat_[A-Za-z0-9_]{22}_[A-Za-z0-9]{59}'   # GitHub fine-grained token
    'ssh-rsa[[:space:]]+[A-Za-z0-9/+=]+'            # RSA public key (private keys start with ----BEGIN)
    'BEGIN[[:space:]]+RSA[[:space:]]+PRIVATE[[:space:]]+KEY'  # Private key marker
    '-----BEGIN[[:space:]]+[A-Za-z0-9 ]+-----'   # PEM block start
    '-----END[[:space:]]+[A-Za-z0-9 ]+-----'     # PEM block end
  )

  # Files to definitely skip redacting (they're already safe or needed as-is)
  declare -A skip_redact=(
    ["$backup_dir/crontab.txt"]=1
    ["$backup_dir/daily-maintenance.sh"]=1  # contains channel ID, not a secret
  )

  find "$backup_dir" -type f | while read -r file; do
    if [[ -n "${skip_redact[$file]:-}" ]]; then
      echo "    Skipping redact for $file"
      continue
    fi
    echo "    Checking $file"
    # For each pattern, replace with placeholder. Use perl for regex.
    for pattern in "${patterns[@]}"; do
      if grep -qiE "$pattern" "$file" 2>/dev/null; then
        echo "      Found secret pattern, redacting..."
        # Replace all matches with [REDACTED]
        perl -pi -e "s/($pattern)/$REDACT_PLACEHOLDER/g" "$file" 2>/dev/null || true
      fi
    done
  done
}

# Generate commit message with changes summary
generate_commit_msg() {
  echo "Generating commit message..."
  now=$(TZ=Asia/Singapore date '+%Y-%m-%d %H:%M:%S %Z')
  msg="Daily backup: $now

Backup of critical OpenClaw configuration and workspace files.

Changed files since last backup:"
  # If this is first commit, will be all files
  git -C "$backup_dir" status --porcelain 2>/dev/null | sed 's/^/  - /' || echo "  (initial commit)"
  echo "
This backup includes:
  - SOUL.md, USER.md, IDENTITY.md (personality and user context)
  - MEMORY.md and memory/ (long-term memory)
  - workspace configuration (AGENTS.md, TOOLS.md, HEARTBEAT.md)
  - agent configurations (agents/main/agent/)
  - cron job definitions
  - OpenClaw gateway config (secrets redacted)
  - custom scripts (daily-maintenance.sh)
  - state snapshots

All detected secrets have been replaced with [$REDACT_PLACEHOLDER].
Review before restoring to reinsert actual credentials."
  echo "$msg"
}

init_git_and_push() {
  echo "--> Initializing git repository"

  cd "$backup_dir"
  git init
  git config user.name "$COMMIT_AUTHOR"
  git config user.email "nestor@openclaw"

  # Add all files
  git add .

  # Check if there are any changes to commit
  if git diff-index --quiet HEAD --; then
    echo "    No changes detected; nothing to commit."
    CHANGES_PUSHED="no"
  else
    echo "--> Committing changes..."
    commit_msg="$(generate_commit_msg)"
    git commit -m "$commit_msg"

    echo "--> Pushing to $GITHUB_REPO_HTTPS"
    git remote add origin "$GITHUB_REPO_HTTPS"
    if git push -u origin master --force; then
      echo "    Push successful."
      CHANGES_PUSHED="yes"
    else
      echo "    Push failed!"
      send_discord "❌ OpenClaw backup FAILED during push at $(TZ=Asia/Singapore date)."
      rm -rf "$backup_dir" 2>/dev/null || true
      exit 4
    fi
  fi
}

# Main
copy_critical
redact_secrets
init_git_and_push

echo "==> Backup complete! Repository: $GITHUB_REPO"
echo "    Backup temp dir: $backup_dir (will be cleaned up)"

# Send success notification to Discord
send_discord "✅ OpenClaw backup completed at $(TZ=Asia/Singapore date). Changes: $CHANGES_PUSHED. Repository: $GITHUB_REPO"

rm -rf "$backup_dir"

exit 0
