#!/usr/bin/env bash

# Discord notification helper
send_discord() {
  local msg="$1"
  if command -v openclaw >/dev/null 2>&1; then
    echo "--> Discord notification: $msg"
    echo "Sending message to Discord channel ID {$DISCORD_MONITORING_CHANNEL}"
    /home/abheek/.npm-global/bin/openclaw message send --channel discord --target "channel:$DISCORD_MONITORING_CHANNEL" --message "$msg" 2>/dev/null || true
  else
    echo "--> (openclaw CLI not available, skipping Discord notification)"
  fi
}

# Test function to send a hello message
test_hello() {
  local test_msg="Hello from OpenClaw workspace test at $(TZ=Asia/Singapore date)"
  echo "Sending test message to Discord: $test_msg"
  send_discord "👋 $test_msg    "  
}

# Run the test
source .env
test_hello
