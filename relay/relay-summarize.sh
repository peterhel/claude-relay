#!/usr/bin/env bash
# relay — incremental transcript digester.
#
#   relay-summarize.sh <transcript.jsonl> <cwd> [force]
#
# Runs DETACHED from the Stop hook (setsid), so its cost never lands on the
# turn: measured 8.11s no-op turn vs 8.41s detached vs 13.02s in-foreground.
# Digests only the lines added since the last run, appends to a rolling brief,
# and raises the handover flag when the context crosses RELAY_PCT.
set -uo pipefail   # deliberately no -e: a half-failed digest must still leave
                   # a consistent checkpoint rather than abort mid-write.

R="$HOME/.claude/relay"
# shellcheck disable=SC1090
. "$R/config" 2>/dev/null || true
. "$R/config.local" 2>/dev/null || true   # ntfy topic etc — kept out of git

tx="${1:-}"; cwd="${2:-}"; force="${3:-}"
[ -f "$tx" ] || exit 0
[ -f "$R/OFF" ] && exit 0

sid=$(basename "$tx" .jsonl)
enc=$(printf '%s' "${cwd:-$HOME}" | sed 's#/#-#g')
S="$R/state/$enc"; mkdir -p "$S"
brief="$S/brief.md"

# one digest per session at a time; a slow model call must not stack up
exec 9>"$S/.lock.$sid"
flock -n 9 || exit 0

printf '%s\n' "$tx" > "$S/last_tx"

# ---- context fullness (no model call — just the newest usage record) --------
win=$(cat "$S/window" 2>/dev/null || echo "$RELAY_WINDOW")
cur=$(tail -400 "$tx" | jq -rs '
        map(select(.message.usage != null) | .message.usage
            | (.input_tokens + (.cache_read_input_tokens // 0)
                             + (.cache_creation_input_tokens // 0)))
        | (last // 0)' 2>/dev/null || echo 0)
# a 200k-window session can never report >190k, so seeing it proves the 1M window
if [ "${cur:-0}" -gt 190000 ] && [ "$win" -le 200000 ]; then
  win=1000000; printf '%s\n' "$win" > "$S/window"
fi
pct=$(( cur * 100 / (win > 0 ? win : 200000) ))

if [ "$pct" -ge "$RELAY_PCT" ]; then
  force=1                                  # never hand over on a stale brief
  if [ ! -f "$S/notified.$sid" ]; then
    : > "$S/notified.$sid"
    printf '%s\n' "$sid" > "$S/handover_ready"
    if [ -n "${RELAY_NTFY:-}" ]; then
      curl -fsS -m 10 -H "Title: Session ${pct}% full" \
        -d "$(basename "$cwd") — /clear now hands over via the brief (${cur}/${win} tokens)" \
        "https://ntfy.sh/$RELAY_NTFY" >/dev/null 2>&1 || true
    fi
  fi
fi

# ---- incremental digest ----------------------------------------------------
total=$(wc -l < "$tx" 2>/dev/null || echo 0)
ck=$(cat "$S/ckpt.$sid" 2>/dev/null || echo 0)
[ "$total" -gt "$ck" ] || exit 0

# RELAY-BRIEF-V1 marks our own injected brief — digesting it would compound a
# summary of a summary every cycle.
view=$(tail -n +$((ck + 1)) "$tx" 2>/dev/null \
       | jq -r -f "$R/view.jq" 2>/dev/null \
       | grep -v 'RELAY-BRIEF-V1' || true)
bytes=$(printf '%s' "$view" | wc -c)

if [ "$bytes" -lt "$RELAY_MIN_BYTES" ] && [ -z "$force" ]; then
  exit 0                                    # let it accumulate; checkpoint stands
fi
[ "$bytes" -gt 200 ] || { printf '%s\n' "$total" > "$S/ckpt.$sid"; exit 0; }

digest=$(cd "$HOME" && printf '%s' "$view" \
         | RELAY_CHILD=1 timeout 180 "$RELAY_CLAUDE" -p --model "$RELAY_MODEL" \
           "$RELAY_DIGEST_PROMPT" 2>/dev/null)

if [ -n "$digest" ]; then
  { printf '\n### %s · %s · %s%% full\n' "$(date '+%Y-%m-%d %H:%M')" "${sid:0:8}" "$pct"
    printf '%s\n' "$digest"; } >> "$brief"
fi
printf '%s\n' "$total" > "$S/ckpt.$sid"

# ---- fold the brief if it has outgrown its cap -----------------------------
if [ -f "$brief" ] && [ "$(wc -c < "$brief")" -gt "$RELAY_BRIEF_CAP" ]; then
  folded=$(cd "$HOME" && RELAY_CHILD=1 timeout 240 "$RELAY_CLAUDE" -p --model "$RELAY_MODEL" \
    "$RELAY_FOLD_PROMPT" < "$brief" 2>/dev/null)
  if [ -n "$folded" ] && [ "${#folded}" -gt 500 ]; then
    { printf '# relay brief (folded %s)\n' "$(date '+%Y-%m-%d %H:%M')"
      printf '%s\n' "$folded"; } > "$brief.tmp" && mv "$brief.tmp" "$brief"
  fi
fi
exit 0
