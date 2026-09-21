---
description: Unattended enrich lane — show what the next timer run would do, or drive one now
---

Report what the unattended enrich lane would do, or drive a real run.

`$ARGUMENTS` may be empty (the default), or contain `--run`, `--max <n>`, or
`--config <path>`.

## Default: show, don't do

With no arguments, this is **read-only**. It prints the decisions a timer run
would make and writes nothing — no labels, no comments, no clone sync:

```bash
"$HOME/.claude/scripts/autopilot.sh" --dry-run
```

That default is deliberate. The lane's real trigger is
`agent-autopilot.timer`; a slash command that started an unattended batch of
paid Claude sessions as its default behaviour is too easy to fire by accident
from a chat prompt.

Render the output as-is — one line per decision, already timestamped. Then say
in one line how many issues **would** be enriched, and how many repos were
skipped with why.

## `--run`: actually do it

Only when `$ARGUMENTS` contains `--run`, drop `--dry-run`:

```bash
"$HOME/.claude/scripts/autopilot.sh"
```

Before doing so, state what it is about to do and confirm: a real run spends a
nested Claude session per issue and applies `ai-implement` +
`ai-review-ai-merge`, which starts the implement pipeline. Pass `--max <n>` and
`--config <path>` straight through if given.

## Exit codes

- `0` — ran (this includes "disabled" and "already running"; neither is an error)
- `1` — a SIGPIPE after the run had already written something (a clean,
  no-write SIGPIPE still exits `0`)
- `2` — usage error
- `3` — a missing dependency (`gh`, `jq`, `git`, `flock`, `timeout`)
- `4` — the config is invalid or unreadable

On `4`, the script names the offending file and line. The most common cause on a
fresh host is that no config exists yet — point at
`setup/autopilot.conf.example` and `docs/AUTOPILOT.md`.

## When nothing happens

Two outcomes look like a no-op and are not failures:

- `disabled: …/autopilot.disabled present` — the kill switch is on. Remove the
  flag file to re-enable.
- `already running — exiting` — another run (timer or shell) holds the lock.

See [`docs/AUTOPILOT.md`](../docs/AUTOPILOT.md) for the lane's operating
instructions, the allowlist, and the kill switch.

---

If you run into blockers, find a solution and update this command for the future.
