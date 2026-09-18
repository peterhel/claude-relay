# relay — continuous handover for Claude Code, instead of compaction stalls

When a Claude Code session fills its context window, auto-compact stops
everything and rewrites the whole conversation into a summary. On a long,
heavy session that is a wall you hit repeatedly, and every time you hit it you
wait.

relay takes the other route. It summarises **while you work**, a little after
every turn, in a detached background process that costs the session nothing.
When the window is nearly full it pings you. You type `/clear`. The fresh
session starts already holding a compressed log of everything that happened
plus the last ~160 turns verbatim — and carries on mid-task.

No fork of Claude Code, no wrapper, no MCP server. Two hooks and five shell
scripts.

```
every turn ──Stop hook──▶ detached digester ──▶ rolling brief (state/<project>/brief.md)
                                │
                     context ≥ 85% ──▶ ntfy push: "session is full"
                                │
        you type /clear ──SessionStart hook──▶ brief + verbatim tail injected
```

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code) on your `PATH`
- `jq`, `curl`, `flock`, `setsid` (all standard on Linux; on macOS:
  `brew install jq flock coreutils` and see *macOS* below)
- Bash 4+

## Install

```bash
git clone <this-repo> claude-relay
cd claude-relay
./install.sh
```

That copies the scripts to `~/.claude/relay/` and registers two hooks in
`~/.claude/settings.json` (a timestamped backup is written first). It is
idempotent: re-running replaces the relay hook entries rather than adding a
second copy, and it never touches your `config.local` or your existing briefs.

Open a **new** session for the hooks to load.

To get the "session is nearly full" push notification, pick any unguessable
topic name and put it in the local config:

```bash
echo 'RELAY_NTFY=some-unguessable-topic-name' >> ~/.claude/relay/config.local
```

Then subscribe to `https://ntfy.sh/some-unguessable-topic-name` in the ntfy app
or in a browser tab. The topic name is the only access control ntfy has, so
treat it as a password — that is why `config.local` is git-ignored. Leave
`RELAY_NTFY` empty and relay simply doesn't notify.

## Using it

Work normally. Then:

```bash
~/.claude/relay/relay-status.sh
```

```
 FULL    BRIEF DIGESTS UPDATED   PROJECT
  87%   41233B      22 14:02     -home-me-src-bigproject  << READY FOR /clear
  31%    9120B       6 13:41     -home-me-src-other
```

When a project says `READY FOR /clear` (or the push arrives), type `/clear` in
that session. The next thing you type continues the work.

`relay-status.sh bigproject` prints that project's brief, which is a decent
"what have I actually done today" log in its own right.

### Turning it off

```bash
touch ~/.claude/relay/OFF     # every hook exits immediately
rm ~/.claude/relay/OFF        # back on
```

Full removal: `./uninstall.sh` (add `--purge` to delete the briefs too).

## Configuration

Defaults live in `~/.claude/relay/config`; put your overrides in
`~/.claude/relay/config.local`, which is never committed and survives
re-installs. In `config.local` use plain assignments (`RELAY_PCT=90`) — it is
sourced *after* `config`, so the `${VAR:-default}` form there would be a no-op.

| Variable | Default | What it does |
|---|---|---|
| `RELAY_PCT` | `85` | Context % that triggers the handover flag + push |
| `RELAY_WINDOW` | `200000` | Assumed window; self-corrects to 1M when it sees >190k |
| `RELAY_MODEL` | `claude-haiku-4-5-20251001` | Model used for digesting |
| `RELAY_CLAUDE` | `claude` | Path to the binary; the installer pins it when `claude` lives outside `PATH` |
| `RELAY_MIN_BYTES` | `20000` | Don't call the model until this much new transcript exists |
| `RELAY_BRIEF_CAP` | `60000` | Brief is re-compressed once it passes this size |
| `RELAY_SEED_CAP` | `35000` | Max chars injected into the cleared session |
| `RELAY_TAIL_LINES` | `160` | Transcript lines carried over **verbatim** |
| `RELAY_NTFY` | *(empty)* | ntfy.sh topic; empty = no notification |
| `RELAY_DIGEST_PROMPT` | *(English)* | The map-step prompt |
| `RELAY_FOLD_PROMPT` | *(English)* | The re-compression prompt |
| `RELAY_SEED_HEADER` | *(English)* | First lines the cleared session reads |

**Working in another language?** Override the three prompt variables in
`config.local` and the entire brief is produced in that language. Keep the
literal string `RELAY-BRIEF-V1` in `RELAY_SEED_HEADER` — it is the sentinel
that stops relay from summarising its own summaries.

## Why it is built this way

Everything below was measured against Claude Code 2.1.258, not assumed.

- **The Stop hook blocks the turn for its entire runtime.** A no-op turn took
  8.11s; the same turn with a 5s foreground sleep in the hook took 13.02s; with
  the work `setsid`-detached, 8.41s. So the hook does nothing but detach.
  Detaching also means the work outlives the `claude` process — which is what
  lets the final digest complete *while the session is being cleared*.
- **The Stop payload already carries `transcript_path` and `cwd`**, so there is
  no guessing which JSONL file belongs to the session.
- **`/clear` fires `SessionStart` with `source=clear`** and a new session id.
  relay seeds on that source only: `startup` and `resume` already have their
  context, and `compact` is the thing we are trying to avoid.
- **`hookSpecificOutput.additionalContext` genuinely reaches the model** —
  verified end-to-end: a cleared session correctly answered a question whose
  answer existed only inside the injected brief.
- **Digest the past, but carry the present verbatim.** Summaries are lossy
  exactly where it hurts most — the thing you were in the middle of. The last
  `RELAY_TAIL_LINES` transcript lines, including tool calls and their results,
  are passed through raw.
- **`RELAY_CHILD=1` is not optional.** The digester calls `claude -p`, which
  fires the Stop hook again. Without the guard that is an unbounded fork bomb.
- **Auto-compact is deliberately left on.** relay is the fast path, not a
  safety system. If you ignore the notification, Claude Code's own compaction
  still catches you. That is also why the trigger is 85% and not 90%: the final
  digest needs a few seconds of headroom before compaction fires.
- **Incremental, not repeated.** Each run digests only the transcript lines
  added since its own checkpoint, so cost grows with new work, not with session
  length. A `flock` per session keeps a slow model call from stacking up.

## What it does not do

- It does not clear for you. Auto-clearing a live session out from under
  someone is worse than a stall; you type the three keystrokes.
- It does not keep a second warm session standing by. Once `SessionStart`
  reseeds, one session clearing itself *is* the handover; a standby would only
  save startup time.
- It does not touch your history or transcripts. It reads them; it writes only
  under `~/.claude/relay/`.

## Files

```
~/.claude/relay/
├── config              defaults (overwritten on re-install)
├── config.local        your overrides + secrets (never touched, git-ignored)
├── relay-stop.sh       Stop hook — detaches the digester, exits 0, always
├── relay-summarize.sh  the digester itself
├── relay-seed.sh       SessionStart hook — injects the brief on /clear
├── relay-status.sh     what the relay currently holds
├── view.jq             JSONL transcript → compact lines
├── relay.log           detached stdout/stderr
├── OFF                 create to disable everything
└── state/<project>/
    ├── brief.md        the rolling compressed log
    ├── ckpt.<sid>      how far into each transcript we have digested
    ├── last_tx         path of the most recent transcript
    ├── window          detected context window
    └── handover_ready  present when this project is waiting for /clear
```

Projects are keyed by working directory, so two sessions in the same repo share
one brief and continue each other's log.

## macOS

`setsid` and `flock` are not in the base system. `brew install flock
util-linux` provides both (you may need to add
`/opt/homebrew/opt/util-linux/bin` to `PATH`). Everything else is portable.

## Troubleshooting

- **No brief appears.** Check `~/.claude/relay/relay.log`, and confirm the
  hooks are registered: `jq .hooks ~/.claude/settings.json`. Hooks only load in
  sessions started *after* install.
- **Nothing injected after `/clear`.** The brief must be non-empty — a session
  short enough to never hit `RELAY_MIN_BYTES` has nothing to hand over. Test
  the hook directly:
  `echo '{"source":"clear","cwd":"'"$PWD"'"}' | bash ~/.claude/relay/relay-seed.sh`
- **Percentage looks wrong.** Delete `state/<project>/window` and let it
  redetect.
- **Costs more than you want.** Raise `RELAY_MIN_BYTES` (fewer, larger digests)
  or lower `RELAY_TAIL_LINES`.

## License

MIT — see `LICENSE`.
