#!/usr/bin/env bash
# relay — SessionStart hook. Turns a bare `/clear` into a full handover: the
# cleared session wakes up holding the rolling brief plus the raw tail of what
# it was doing. Only fires on source=clear (startup/resume already have their
# context, and compact is the backstop we are trying to avoid).
set -uo pipefail

R="$HOME/.claude/relay"
# shellcheck disable=SC1090
. "$R/config" 2>/dev/null || true
. "$R/config.local" 2>/dev/null || true
[ -f "$R/OFF" ] && exit 0

payload=$(timeout 5 cat 2>/dev/null || true)
src=$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty'   2>/dev/null)
[ "$src" = "clear" ] || exit 0

enc=$(printf '%s' "${cwd:-$HOME}" | sed 's#/#-#g')
S="$R/state/$enc"
brief="$S/brief.md"
[ -s "$brief" ] || exit 0

prev=$(cat "$S/last_tx" 2>/dev/null || true)

# Compressed history is lossy exactly where it hurts — the thing you were in
# the middle of. So: digest for the past, raw transcript for the recent tail.
tail_raw=""
if [ -n "$prev" ] && [ -f "$prev" ]; then
  tail_raw=$(tail -n "$RELAY_TAIL_LINES" "$prev" 2>/dev/null \
             | jq -r -f "$R/view.jq" 2>/dev/null \
             | grep -v 'RELAY-BRIEF-V1' | tail -c 18000 || true)
fi

ctx=$(printf '%s\n\n%s\n%s\n\n%s\n%s\n' \
        "$RELAY_SEED_HEADER" \
        "$RELAY_SEED_PAST" "$(cat "$brief")" \
        "$RELAY_SEED_TAIL" "$tail_raw" | tail -c "$RELAY_SEED_CAP")

jq -n --arg c "$ctx" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'

# handled — the next session's own digests start a fresh chain
rm -f "$S/handover_ready"
exit 0
