#!/usr/bin/env bash
# relay — one row per live session, fullest first.
#   relay-status.sh            # overview
#   relay-status.sh <project>  # print that project's briefs
set -uo pipefail
R="$HOME/.claude/relay"
# shellcheck disable=SC1090
. "$R/config" 2>/dev/null || true
. "$R/config.local" 2>/dev/null || true

if [ -n "${1:-}" ]; then
  d=$(ls -d "$R/state/"*"$1"*/ 2>/dev/null | head -1)
  [ -n "$d" ] || { echo "relay: no state matches '$1'"; exit 1; }
  for b in "$d"brief.*.md; do
    [ -f "$b" ] || continue
    sid=$(basename "$b" .md); sid=${sid#brief.}
    echo "──────── ${sid:0:8}  ($(date -r "$b" '+%Y-%m-%d %H:%M'))"
    cat "$b"
  done
  exit 0
fi

[ -f "$R/OFF" ] && echo "!! relay is DISABLED (remove $R/OFF to re-enable)"
printf '%5s %8s %7s %-9s %-9s %s\n' 'FULL' 'BRIEF' 'DIGESTS' 'UPDATED' 'SESSION' 'PROJECT'
for d in "$R/state"/*/; do
  [ -d "$d" ] || continue
  for f in "$d"last_tx.*; do
    [ -f "$f" ] || continue
    sid=$(basename "$f"); sid=${sid#last_tx.}
    tx=$(cat "$f" 2>/dev/null); [ -n "$tx" ] && [ -f "$tx" ] || continue
    win=$(cat "$d/window" 2>/dev/null || echo "${RELAY_WINDOW:-200000}")
    cur=$(tail -400 "$tx" | jq -rs 'map(select(.message.usage != null) | .message.usage
          | (.input_tokens + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)))
          | (last // 0)' 2>/dev/null || echo 0)
    pct=$(( cur * 100 / (win > 0 ? win : 200000) ))
    b="$d/brief.$sid.md"
    printf '%4s%% %7sB %7s %-9s %-9s %s%s\n' "$pct" \
      "$([ -f "$b" ] && wc -c < "$b" || echo 0)" \
      "$(grep -c '^### ' "$b" 2>/dev/null || echo 0)" \
      "$(date -r "$tx" '+%H:%M' 2>/dev/null || echo '-')" \
      "${sid:0:8}" \
      "$(basename "$d")" \
      "$([ -f "$d/handover.$sid" ] && echo '  << READY FOR /clear')"
  done
done | sort -rn
