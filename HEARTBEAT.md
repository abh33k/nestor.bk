# HEARTBEAT.md Template

```markdown
# Keep this file empty (or with only comments) to skip heartbeat API calls.

# Add tasks below when you want the agent to check something periodically.

## 🔧 Scheduled Checks
- [x] Verify OpenClaw executable path (/home/abheek/.npm-global/bin/openclaw)
- [x] Check PATH configuration in cron environment
- [x] Test which openclaw in cron context
  * Issue: openclaw not found in minimal PATH (/usr/bin:/bin)
  * Solution: Add /home/abheek/.npm-global/bin to PATH
- [x] Get logs from daily maintenance script (partial output available)
- [x] Restart OpenClaw gateway after fixes
- [x] Confirm successful completion of maintenance tasks
```
