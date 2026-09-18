#!/usr/bin/env bash
# relay — what the relay currently holds, fullest session first.
#   relay-status.sh            # overview
#   relay-status.sh <project>  # print that project's brief
set -uo pipefail
R="$HOME/.claude/relay"
# shellcheck disable=SC1090
. "$R/config" 2>/dev/null || true
. "$R/config.local" 2>/dev/null || true

if [ -n "${1:-}" ]; then
  b=$(ls -d "$R/state/"*"$1"*/ 2>/dev/null | head -1)
  [ -n "$b" ] || { echo "relay: no brief matches '$1'"; exit 1; }
  echo "── $b"; cat "$b/brief.md" 2>/dev/null; exit 0
fi

[ -f "$R/OFF" ] && echo "!! relay is DISABLED (remove $R/OFF to re-enable)"
printf '%5s %8s %7s %-9s %s\n' 'FULL' 'BRIEF' 'DIGESTS' 'UPDATED' 'PROJECT'
for d in "$R/state"/*/; do
  [ -d "$d" ] || continue
  tx=$(cat "$d/last_tx" 2>/dev/null); [ -n "$tx" ] && [ -f "$tx" ] || continue
  win=$(cat "$d/window" 2>/dev/null || echo "${RELAY_WINDOW:-200000}")
  cur=$(tail -400 "$tx" | jq -rs 'map(select(.message.usage != null) | .message.usage
        | (.input_tokens + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)))
        | (last // 0)' 2>/dev/null || echo 0)
  pct=$(( cur * 100 / (win > 0 ? win : 200000) ))
  b="$d/brief.md"
  printf '%4s%% %7sB %7s %-9s %s%s\n' "$pct" \
    "$([ -f "$b" ] && wc -c < "$b" || echo 0)" \
    "$(grep -c '^### ' "$b" 2>/dev/null || echo 0)" \
    "$(date -r "$b" '+%H:%M' 2>/dev/null || echo '-')" \
    "$(basename "$d")" \
    "$([ -f "$d/handover_ready" ] && echo '  << READY FOR /clear')"
done | sort -rn
