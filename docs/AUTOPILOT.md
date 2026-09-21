# The unattended enrich lane

`/autopilot` quick-enriches `needs-enrichment` issues in an allowlisted set of
repos and dispatches the ones that came out clean, on a timer, with nobody
watching. This page is how to run it, and how to stop it.

Design and rationale:
[`docs/superpowers/specs/2026-09-21-autopilot-design.md`](superpowers/specs/2026-09-21-autopilot-design.md).
The decision to drive `/enrich` through a nested session is ADR-015 in
[`DECISIONS.md`](DECISIONS.md).

## The kill switch

Two layers. The flag file is the panic button — one `touch`, no unit knowledge,
and it shows up in the log as the reason nothing happened:

```bash
touch ~/.config/agent-workflow/autopilot.disabled
```

It is checked at the top of every run, before a single issue is read, so it
takes effect from the next firing. Remove the file to re-enable.

To stop the schedule properly:

```bash
systemctl --user disable --now agent-autopilot.timer
```

A run already in flight is stopped with
`systemctl --user stop agent-autopilot.service`.

## What it takes for a repo to be touched

Three gates, all required. Failing any one is logged with its reason:

1. **The allowlist.** The repo has a `repo=` line in
   `~/.config/agent-workflow/autopilot.conf`. This is the outer gate and the
   only one that cannot be flipped from inside a consumer repo.
2. **`ai-review-ai-merge: true`** in the consumer's
   `.github/workflows/agent.yml`.
3. **A test gate that has actually run.** The same `agent.yml` declares
   `autopilot-test-gate: <workflow-file>`, that workflow exists, and it has at
   least one completed run on the default branch. No auto-merge on an unrun
   gate (#263).

And per issue: open, `needs-enrichment`, a non-empty body, and none of
`🧊 parked`, `enrichment-ongoing`, `needs-human`, `ai-implement`.

## Setup

1. **Config.** `cp setup/autopilot.conf.example ~/.config/agent-workflow/autopilot.conf`
   and edit. Start with `agent-action-sandbox` only.
2. **Credentials.** Create `~/.config/agent-workflow/autopilot.env`, mode
   `0600`, with `CLAUDE_CODE_OAUTH_TOKEN=` and `GH_TOKEN=`. A `--user` unit
   inherits nothing from a shell, so this file is not optional — both tokens
   missing is the most likely first-run failure.
3. **Dry run.** `scripts/autopilot.sh --dry-run`. Nothing is written. Read every
   line before going further.
4. **One real issue.** `scripts/autopilot.sh --max 1` against the sandbox.
5. **The units.** Follow the install block at the top of
   `setup/agent-autopilot.service`. Both paths in it need editing for your
   clone. Neither unit is installed by `setup/bootstrap.sh` — enabling an
   unattended lane that opens and merges PRs is a deliberate per-host act, not
   something bootstrap turns on for you.
6. **Only then** add a real repo to the allowlist.

## Reading the log

```bash
journalctl --user -u agent-autopilot.service -n 50 --no-pager
```

One line per decision. `scripts/autopilot.sh` is the source of truth for this
table — every line below is a literal `log`/`log_repo`/`log_issue` call in that
script:

| Outcome | Meaning |
|---|---|
| `disabled: <path> present` | The kill switch is on; nothing was read |
| `already running — exiting` | Another run (timer or shell) holds the lock |
| `skipped (<reason>)` | The repo failed one of the two `agent.yml` eligibility gates — reason names which one |
| `no candidates` | The repo is eligible; nothing was enrichable |
| `failed (clone sync)` | The managed clone could not be updated; the issue was never touched |
| `failed (enrich timed out after <n>s)` | The nested enrich session hit `enrich_timeout`; escalated to `needs-human` |
| `failed (enrich exited <rc>)` | The nested enrich session crashed; escalated to `needs-human` |
| `failed (…); ESCALATION FAILED: needs-human not applied, enrichment-ongoing may still be set` | The crash above, AND the escalation call itself failed — the issue may be stuck; fix by hand |
| `needs-human` | The enrich session hit a one-way door or a `[low]` assumption and handed it over |
| `skipped (could not read labels — not dispatching)` | The issue's labels could not be re-read after a clean enrich; refuses to dispatch rather than guess |
| `failed (dispatch labels not applied)` | The enrich session came out clean, but applying `ai-implement`/`ai-review-ai-merge` failed |
| `enriched` | Spec, plan and issue body written; `ai-implement` + `ai-review-ai-merge` applied |
| `would: enrich headless, then dispatch (clone <dir>)` | `--dry-run` only — what a real run would attempt next |

A `failed` line for a specific issue points at
`~/.cache/agent-workflow/autopilot/logs/enrich-<n>.log` for the nested
session's own output.

### Exit codes

The process's own exit code, distinct from the per-line outcomes above:

| Code | Meaning |
|---|---|
| `0` | Ran (this includes "disabled" and "already running" — neither is an error) |
| `1` | A SIGPIPE landed after the run had already written something — a truncated run that already mutated state. A clean, no-write SIGPIPE still exits `0` |
| `2` | Usage error |
| `3` | A missing dependency (`gh`, `jq`, `git`, `flock`, `timeout`) |
| `4` | The config is invalid or unreadable — the message names the offending file and line |

## When something is wedged

- **A clone is in a bad state.** Delete it:
  `rm -rf ~/.cache/agent-workflow/autopilot/<owner>__<name>`. The next run
  re-clones.
- **An issue is stuck with `enrichment-ongoing` and no run in flight.** The
  label is released automatically after 24h by `/enrich`'s own staleness check,
  or remove it by hand.
- **An issue keeps landing in `needs-human`.** That is the design working.
  Enrich it by hand with `/enrich <n>` and remove `needs-human`.
- **An `ESCALATION FAILED` line.** The issue may still carry
  `enrichment-ongoing` with no `needs-human`, which drops it out of the lane for
  good (`autopilot-candidates.sh` excludes `enrichment-ongoing`). Apply
  `needs-human` and remove `enrichment-ongoing` by hand.

## Prerequisite for the game repos

Before any `game-*` repo is allowlisted it needs re-onboarding with
`onboard-consumer.sh --ai-review-ai-merge`. As of 2026-09-21 game-tschau-sepp is
pinned at `@v2` with a deprecated `pre-preview: true` and a stub still named
`name: Claude` / `jobs: claude`. Tracked under freaxnx01/bridge#218.
