#!/usr/bin/env bash
# relay — Stop hook. Fires after every turn, in EVERY session, so the one hard
# rule is: never block, never fail loudly, always exit 0.
set -uo pipefail

# The digester itself runs `claude -p`, which fires this same hook again.
# Without this guard that is an unbounded fork bomb.
[ -n "${RELAY_CHILD:-}" ] && exit 0

R="$HOME/.claude/relay"
[ -f "$R/OFF" ] && exit 0                     # kill switch

payload=$(timeout 5 cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

tx=$(printf '%s' "$payload"  | jq -r '.transcript_path // empty' 2>/dev/null)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$tx" ] && [ -f "$tx" ] || exit 0

# setsid + closed fds: the work must outlive both this hook and the session
# itself — the final digest happens as the session is being cleared.
setsid bash "$R/relay-summarize.sh" "$tx" "$cwd" \
  </dev/null >>"$R/relay.log" 2>&1 &

exit 0
