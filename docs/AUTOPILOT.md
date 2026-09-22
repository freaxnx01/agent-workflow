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

1. **The allowlist, with its gate.** The repo has a
   `repo=<owner/name>:<test-gate workflow file>` line in
   `~/.config/agent-workflow/autopilot.conf`. This is the outer gate and the
   only one that cannot be flipped from inside a consumer repo — the gate
   workflow is named here too, not in the consumer's `agent.yml`: the
   reusable workflow does not declare that input, and `workflow_call`
   hard-fails on an undeclared one.
2. **`ai-review-ai-merge: true`** in the consumer's
   `.github/workflows/agent.yml`.
3. **The gate named in the allowlist has actually run.** That workflow
   exists in the consumer repo, and it has at least one completed run on the
   default branch. No auto-merge on an unrun gate (#263).

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
   something bootstrap turns on for you. The unit's `TimeoutStartSec=3h` is
   sized for the shipped defaults; raising `max_per_run` or `enrich_timeout`
   in `autopilot.conf` can push a real run past it, and a SIGTERM mid-enrich
   leaves the issue with `enrichment-ongoing` set and no `needs-human` — the
   same silent drop described under "When something is wedged" below. Raise
   `TimeoutStartSec` to match if you raise either config value.
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
| `skipped (<reason>)` | The repo failed one of the `agent.yml` eligibility gates (missing file, `ai-review-ai-merge` not set, unreadable default branch, gate workflow never completed a run on it), or `repo_eligible` itself could not run the check (e.g. `skipped (eligibility check failed (could not read agent.yml))` — a `gh` outage reading `agent.yml`, not an absent gate) — reason names which |
| `no candidates` | The repo is eligible and the candidate query succeeded; genuinely nothing was enrichable |
| `skipped (candidate query failed)` | The repo passed `repo_eligible`, but the candidate query (`gh issue list`) itself failed — distinct from `no candidates` (query succeeded, returned nothing) and distinct from the `skipped (<reason>)` row above (that one is `repo_eligible` failing to read `agent.yml`/its metadata, not `gh issue list` failing to list issues) |
| `skipped (label ensure failed)` | The repo has candidates, but `ensure-issue-labels.sh` could not be run against it before the first dispatch of this run (#380) — the repo is skipped for this run rather than letting a later dispatch or escalation write fail against labels that were never created; no nested enrich session was spent |
| `failed (clone sync)` | The managed clone could not be updated; the issue was never touched |
| `failed (enrich timed out after <n>s)` | The nested enrich session hit `enrich_timeout`; escalated to `needs-human` |
| `failed (enrich exited <rc>)` | The nested enrich session crashed; escalated to `needs-human` |
| `failed (…); ESCALATION FAILED: needs-human not applied, enrichment-ongoing may still be set` | The crash above, AND the escalation call itself failed — the issue may be stuck; fix by hand |
| `needs-human` | The enrich session hit a one-way door or a `[low]` assumption and handed it over |
| `skipped (could not read labels — not dispatching)` | A post-enrich label re-read (`needs-human`, `needs-enrichment`, or `🧊 parked`) failed, or returned a state the driver did not expect; refuses to dispatch rather than guess |
| `skipped (enrich did not complete — needs-enrichment still present)` | The nested session exited 0 but never actually enriched the issue (prose-only reply, a denied tool, a silent no-op) — `needs-enrichment` is the positive evidence `/enrich` clears on genuine success, and it is still there |
| `skipped (parked during enrich — not dispatching)` | A human applied `🧊 parked` while the (up to 30-minute) nested session was running; the driver re-reads it after the session returns and refuses to dispatch |
| `failed (dispatch labels not applied); escalated to needs-human` | The enrich session came out clean, but applying `ai-implement`/`ai-review-ai-merge` failed even after retry; escalated to a human instead of silently dropping the issue |
| `failed (dispatch labels not applied); ESCALATION FAILED: needs-human not applied` | The dispatch write failed, AND the escalation write also failed — the issue is now enriched with no dispatch labels and no `needs-human`; fix by hand |
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
- **An issue is stuck with `enrichment-ongoing` and no run in flight.** Nothing
  releases it automatically: `/enrich`'s staleness check only offers to take
  over a stale lock interactively, which headless mode forbids, and the lane
  skips any issue still carrying `enrichment-ongoing` regardless of its age.
  Remove the label by hand:
  `gh issue edit <n> --repo <owner/repo> --remove-label enrichment-ongoing`.
- **An issue keeps landing in `needs-human`.** That is the design working.
  Enrich it by hand with `/enrich <n>` and remove `needs-human`.
- **An `ESCALATION FAILED` line after a crashed enrich session.** The issue
  may still carry `enrichment-ongoing` with no `needs-human`, which drops it
  out of the lane for good (`autopilot-candidates.sh` excludes
  `enrichment-ongoing`). Apply `needs-human` and remove `enrichment-ongoing`
  by hand.
- **An `ESCALATION FAILED` line after `failed (dispatch labels not
  applied)`.** The issue enriched cleanly (`needs-enrichment` is already
  gone), but neither the dispatch labels nor `needs-human` landed — it has
  dropped out of the lane silently. Apply `needs-human` by hand.

## Prerequisite for the game repos

Before any `game-*` repo is allowlisted it needs re-onboarding with
`onboard-consumer.sh --ai-review-ai-merge`. As of 2026-09-21 game-tschau-sepp is
pinned at `@v2` with a deprecated `pre-preview: true` and a stub still named
`name: Claude` / `jobs: claude`. Tracked under freaxnx01/bridge#218.
