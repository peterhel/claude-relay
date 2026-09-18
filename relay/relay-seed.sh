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
src=$(printf '%s' "$payload"    | jq -r '.source // empty'     2>/dev/null)
cwd=$(printf '%s' "$payload"    | jq -r '.cwd // empty'        2>/dev/null)
newsid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
[ "$src" = "clear" ] || exit 0

enc=$(printf '%s' "${cwd:-$HOME}" | sed 's#/#-#g')
S="$R/state/$enc"
[ -d "$S" ] || exit 0

# Which session are we taking over from? Several may be running in this same
# directory, so "the newest thing in the folder" is not good enough: prefer the
# one that actually reported itself full (that is the one you were told to
# clear), and only then fall back to most-recently-active.
pred=""
newest() {  # newest-first list of sids from files named <prefix>.<sid>
  find "$S" -maxdepth 1 -type f -name "$1.*" -printf '%T@ %f\n' 2>/dev/null \
    | sort -rn | cut -d' ' -f2- | sed "s/^$1\.//"
}
try() {
  [ -n "$1" ] || return 1
  [ "$1" = "$newsid" ] && return 1          # never inherit from ourselves
  [ -s "$S/brief.$1.md" ] || return 1       # nothing to hand over
  pred="$1"; return 0
}
while IFS= read -r c; do try "$c" && break; done < <(newest handover)
[ -n "$pred" ] || while IFS= read -r c; do try "$c" && break; done < <(newest last_tx)
[ -n "$pred" ] || exit 0

brief="$S/brief.$pred.md"
prev=$(cat "$S/last_tx.$pred" 2>/dev/null || true)
# state and transcripts use the same directory encoding, so the path is
# recoverable even if last_tx went missing
[ -n "$prev" ] && [ -f "$prev" ] || prev="$HOME/.claude/projects/$enc/$pred.jsonl"

# Compressed history is lossy exactly where it hurts — the thing you were in
# the middle of. So: digest for the past, raw transcript for the recent tail.
tail_raw=""
if [ -f "$prev" ]; then
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

# Carry the history into this session's own brief, so the NEXT handover still
# knows about everything before this one. The injected copy cannot serve that
# purpose: it is stamped RELAY-BRIEF-V1 and deliberately skipped when digesting.
if [ -n "$newsid" ] && [ ! -f "$S/brief.$newsid.md" ]; then
  cp "$brief" "$S/brief.$newsid.md" 2>/dev/null || true
fi

rm -f "$S/handover.$pred"        # handled — other sessions keep their flags
exit 0
