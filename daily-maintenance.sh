#!/usr/bin/env bash
# OpenClaw Daily Maintenance Routine
# Runs at 04:00 Singapore time

set -euo pipefail

# Load .env if present (workspace root)
if [ -f "$(dirname "$0")/.env" ]; then
  set -a
  source "$(dirname "$0")/.env"
  set +a
fi

# Configuration
export PATH="/home/abheek/.npm-global/bin:$PATH"
NESTOR_BOT_ID="1490542590154768465"
LOG_DIR="/home/abheek/.openclaw/logs"
LOG_FILE="$LOG_DIR/maintenance-$(date +%Y-%m-%d).log"
mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== OpenClaw Daily Maintenance Starting: $(TZ=Asia/Singapore date) ==="

# 1. Show initial status
echo "Current gateway status:"
openclaw gateway status || true
echo ""

# 2. Run update with JSON output for parsing
echo "Running openclaw update..."
UPDATE_JSON=$(mktemp)
set +e
openclaw update --yes --json > "$UPDATE_JSON" 2>&1
UPDATE_EXIT=$?
set -e

if [ $UPDATE_EXIT -eq 0 ]; then
    echo "Update completed successfully."
    # Display summary if jq is available
    if command -v jq &> /dev/null; then
        echo "Update details:"
        jq -r '
          . as $root |
          "Version: \(.version // "unknown")",
          "Channel: \(.channel // "unknown")",
          "Updates:",
          (.git // {}) | if type=="object" then
            "  Git: \(.remote // "none") @ \(.revision // "unknown")"
          else empty end,
          (.plugins // [])[] | "  Plugin: \(.name) \(.action // "updated") -> \(.version // "?")",
          (.dependencies // [])[] | "  Dep: \(.name) \(.action // "updated") -> \(.version // "?")"
        ' "$UPDATE_JSON" || cat "$UPDATE_JSON"
    else
        echo "Update output (jq not installed for pretty-print):"
        cat "$UPDATE_JSON"
    fi
else
    echo "Update failed with exit code $UPDATE_EXIT"
    echo "Full update output:"
    cat "$UPDATE_JSON"

    # Prepare failure message
    FAILURE_SUMMARY="⚠️ OpenClaw update FAILED at $(TZ=Asia/Singapore date)\nExit code: $UPDATE_EXIT\nFirst 200 chars: $(head -c 200 "$UPDATE_JSON" | tr -d '\n')"

    # Send failure report to monitoring channel
    echo "Sending failure notification to #monitoring..."
    openclaw message send --channel discord --target "channel:$DISCORD_MONITORING_CHANNEL" --message "$FAILURE_SUMMARY" || true

    rm -f "$UPDATE_JSON"
    echo "=== Maintenance aborted due to update failure ==="
    exit 1
fi
rm -f "$UPDATE_JSON"
echo ""

# 3. Restart gateway
echo "Restarting gateway service..."
if openclaw gateway restart; then
    echo "Gateway restart initiated."
else
    echo "Gateway restart command failed!"
    openclaw message send --channel discord --target "channel:$DISCORD_MONITORING_CHANNEL" --message "❌ OpenClaw gateway restart FAILED after update at $(TZ=Asia/Singapore date). Manual intervention needed."
    exit 2
fi

# Wait for systemd to show active first
echo "Waiting for systemd service to become active..."
for i in {1..12}; do
    if systemctl --user is-active openclaw-gateway.service >/dev/null 2>&1; then
        echo "Systemd service is active."
        break
    fi
    sleep 2
    echo "Still waiting for systemd... ($i/12)"
done

# Now wait for gateway RPC/health to be ready
 echo "Waiting for gateway to become healthy..."
 for i in {1..36}; do
     if openclaw gateway status > /dev/null 2>&1; then
         echo "Gateway is back online."
         break
     fi
     sleep 5
     echo "Still waiting... ($i/36)"
 done

if ! openclaw gateway status > /dev/null 2>&1; then
    echo "Gateway did not recover after restart!"
    openclaw message send --channel discord --target "channel:$DISCORD_MONITORING_CHANNEL" --message "❌ OpenClaw gateway did NOT recover after restart at $(TZ=Asia/Singapore date). Manual intervention needed."
    exit 3
fi

echo ""
echo "Gateway status after restart:"
openclaw gateway status || true
echo ""

# 4. Get current version info
VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
REVISION=$(git -C "$(dirname "$(which openclaw)")/../.." rev-parse --short HEAD 2>/dev/null || echo "unknown")

# 5. Send success report to monitoring channel
SUCCESS_MSG="✅ OpenClaw daily maintenance completed at $(TZ=Asia/Singapore date)\nVersion: $VERSION\nRevision: $REVISION\nGateway restarted successfully.\nLog: $LOG_FILE"
echo "Sending success notification to #monitoring..."
openclaw message send --channel discord --target "channel:$DISCORD_MONITORING_CHANNEL" --message "$SUCCESS_MSG" || true

echo "=== Maintenance Finished ==="
