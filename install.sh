#!/usr/bin/env bash
# relay — installer. Safe to re-run: it replaces the relay hook entries in
# ~/.claude/settings.json rather than appending a second copy, and it never
# overwrites your config.local or existing state.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relay"
DEST="$HOME/.claude/relay"
SETTINGS="$HOME/.claude/settings.json"

# ---- prerequisites ---------------------------------------------------------
missing=()
for c in jq curl flock setsid; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "relay: missing required commands: ${missing[*]}" >&2
  echo "  install them via your package manager (util-linux provides flock/setsid)" >&2
  exit 1
fi

# `claude` is often outside a non-login PATH; find it and pin it if so.
CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
if [ -z "$CLAUDE_BIN" ]; then
  for p in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
           /usr/local/bin/claude /opt/homebrew/bin/claude; do
    [ -x "$p" ] && { CLAUDE_BIN="$p"; break; }
  done
fi
if [ -z "$CLAUDE_BIN" ]; then
  echo "relay: claude not found — install it first:" >&2
  echo "  https://docs.claude.com/en/docs/claude-code" >&2
  exit 1
fi

# ---- files -----------------------------------------------------------------
mkdir -p "$DEST/state"
for f in config view.jq relay-stop.sh relay-seed.sh relay-summarize.sh relay-status.sh; do
  cp "$SRC/$f" "$DEST/$f"
done
chmod +x "$DEST"/*.sh

if [ ! -f "$DEST/config.local" ]; then
  cat > "$DEST/config.local" <<'EOF'
# Local overrides — never committed. Plain assignments (this file is sourced
# after config, so `RELAY_PCT=90` wins; `${RELAY_PCT:-90}` would not).
# RELAY_NTFY=your-ntfy-topic
EOF
  chmod 600 "$DEST/config.local"
fi

# pin the binary only when bare `claude` would not resolve
if [ "$CLAUDE_BIN" != "$(command -v claude 2>/dev/null || true)" ] \
   && ! grep -q '^RELAY_CLAUDE=' "$DEST/config.local"; then
  printf 'RELAY_CLAUDE=%s\n' "$CLAUDE_BIN" >> "$DEST/config.local"
  echo "relay: pinned RELAY_CLAUDE=$CLAUDE_BIN (not on PATH)"
fi

# ---- hook registration -----------------------------------------------------
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-relay-$(date +%Y%m%d%H%M%S)"

tmp=$(mktemp)
jq --arg stop  "bash $DEST/relay-stop.sh" \
   --arg seed  "bash $DEST/relay-seed.sh" '
  # drop any previous relay entries so re-running cannot double-register
  def strip($ev; $needle):
    if (.hooks[$ev] // null) == null then .
    else .hooks[$ev] |= (map(.hooks |= map(select((.command // "") | contains($needle) | not))
                            ) | map(select((.hooks | length) > 0)))
    end;
  (. // {})
  | .hooks //= {}
  | strip("Stop";         "relay-stop.sh")
  | strip("SessionStart"; "relay-seed.sh")
  | .hooks.Stop         = ((.hooks.Stop // [])
      + [{hooks: [{type: "command", command: $stop, timeout: 10}]}])
  | .hooks.SessionStart = ((.hooks.SessionStart // [])
      + [{hooks: [{type: "command", command: $seed, timeout: 15}]}])
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "relay installed in $DEST"
echo "  hooks registered in $SETTINGS (backup alongside it)"
echo "  status:      $DEST/relay-status.sh"
echo "  kill switch: touch $DEST/OFF"
echo
echo "Open a new Claude Code session for the hooks to take effect."
