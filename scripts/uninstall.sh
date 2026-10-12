#!/usr/bin/env bash
# Stop and remove the touchscreen-display-mapper launchd agent. Touches go back
# to macOS's default handling as soon as the agent exits. The binary and logs
# under ~/.touchscreen-display-mapper (or $TSDM_HOME) are left in place; delete
# that directory to remove them too.

set -euo pipefail

LABEL="io.github.chendrizzy.touchscreen-display-mapper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SERVICE="gui/$(id -u)/$LABEL"

note() { printf '[uninstall] %s\n' "$*"; }

if launchctl print "$SERVICE" >/dev/null 2>&1; then
  launchctl bootout "$SERVICE" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$SERVICE" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if launchctl print "$SERVICE" >/dev/null 2>&1; then
    note "ERROR: agent is still loaded; run: launchctl bootout $SERVICE" >&2
    exit 1
  fi
fi

rm -f "$PLIST"
note "removed $LABEL"
note "permission entries remain in System Settings > Privacy & Security; remove them there if wanted."
