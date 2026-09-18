#!/usr/bin/env bash
# relay — uninstaller. Removes the hook entries; leaves your briefs in
# ~/.claude/relay/state/ alone unless you pass --purge.
set -euo pipefail

DEST="$HOME/.claude/relay"
SETTINGS="$HOME/.claude/settings.json"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak-relay-$(date +%Y%m%d%H%M%S)"
  tmp=$(mktemp)
  jq '
    def strip($ev; $needle):
      if (.hooks[$ev] // null) == null then .
      else .hooks[$ev] |= (map(.hooks |= map(select((.command // "") | contains($needle) | not))
                              ) | map(select((.hooks | length) > 0)))
      end;
    strip("Stop"; "relay-stop.sh") | strip("SessionStart"; "relay-seed.sh")
    # leave no empty husks behind
    | if (.hooks | type) == "object"
      then .hooks |= with_entries(select((.value | length) > 0))
           | if (.hooks | length) == 0 then del(.hooks) else . end
      else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "relay: hooks removed from $SETTINGS"
fi

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$DEST"
  echo "relay: $DEST removed (briefs and config.local included)"
else
  echo "relay: kept $DEST — run with --purge to delete briefs and config too"
fi
