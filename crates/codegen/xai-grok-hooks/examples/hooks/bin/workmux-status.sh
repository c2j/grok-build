#!/bin/sh
# workmux-status.sh — bridge grok lifecycle events to workmux status tracking.
#
# Invoked by workmux-status.json with one argument: the status to publish
# (working | waiting | done). Silently no-ops when workmux is not on PATH,
# when no tmux session is attached, or when WORKMUX_DISABLE_SET_WINDOW_STATUS
# is set (so nested agents do not clobber the parent's status).

set -e

STATUS="${1:-}"
[ -z "$STATUS" ] && exit 0

# Respect workmux's own opt-out env var (matches WORKMUX_DISABLE_SET_WINDOW_STATUS
# documented in workmux's status-tracking guide).
[ -n "$WORKMUX_DISABLE_SET_WINDOW_STATUS" ] && exit 0

# No workmux installed → nothing to do.
command -v workmux >/dev/null 2>&1 || exit 0

# No tmux → workmux set-window-status would fail anyway; skip silently.
[ -z "$TMUX" ] && exit 0

# Pass grok's session id as the workmux instance id so concurrent grok
# sessions in the same tmux server do not collide.
WORKMUX_STATUS_INSTANCE="${GROK_SESSION_ID:-}" \
  workmux set-window-status "$STATUS" >/dev/null 2>&1 || true

exit 0
