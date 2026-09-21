# /autopilot — unattended quick-enrich and dispatch for auto-lane repos

**Issue:** [#373](https://github.com/freaxnx01/agent-workflow/issues/373)
**Date:** 2026-09-21
**Status:** approved

## Problem

Enrichment is the narrowest part of the funnel. `ai-funnel.sh` exists precisely
because issues pile up behind it: on one consumer repo only 5 of 30 open
milestone issues were dispatchable, every other one waiting on a human to run
`/enrich`. Quick mode (`--quick`) removed the clarifying questions and the
approval gate, but it still cannot run unattended — it stops and asks on a
one-way door, and there is nothing to drive it on a schedule.

This spec defines v1 of an unattended lane for an explicit allowlist of repos:
capture → quick-mode enrichment → implementation → AI review → AI merge, driven
by a systemd timer on agent-dev LXC 201.

It is deliberately the fast path, not the end state. The bridge dispatch enrich
lane (phase 2 of freaxnx01/bridge#304) supersedes it once that exists.

## Non-goals

Explicitly out of scope for v1, parked rather than built:

- bridge#304's phase-2 dispatch lane — this is the interim fast path.
- Repeat-failure backoff, attempt counters, or cost accounting across runs.
- Parallel enrichment (#332). Runs are sequential.
- Recording the baseline commit in the plan (#274).

**Blocked by:** freaxnx01/bridge#303 is still open as of 2026-09-21. This spec
and its plan are safe to write and implement now, but the lane must not be
switched on (timer enabled against a real game repo) until #303 lands.

## Architecture

```
agent-autopilot.timer  (systemd --user)
 └─ agent-autopilot.service  Type=oneshot, EnvironmentFile=…
     └─ scripts/autopilot.sh
         flock -n            → already running?      exit 0
         autopilot.disabled  → present?              exit 0
         load config         → allowlist, max_per_run
         for each allowlisted repo:
           repo_eligible?    → no: log skip + reason, next repo
           candidates        → oldest first, global cap
           for each issue:
             sync clone cache  (fetch, checkout main, reset --hard, clean -fdx)
             ENRICH_CMD        → claude --print "/enrich N --quick --headless"
             re-read labels:
               needs-human?  → log needs-human
               else          → gh issue edit N --add-label ai-implement,ai-review-ai-merge
             log one line
```

A systemd timer runs a process, not a slash command, so the driver is a shell
script. `/autopilot` exists as a thin, human-facing slash command that shells
out to the same script in dry-run mode.

**The write side lives only in the driver.** Config parsing, repo eligibility
and candidate selection are query-only libs with no side effects, which is what
makes them fixture-testable with no network. This follows the repo's
command-query separation rule and the existing `ai-funnel.sh` / `ai-stats.sh`
split between a read-only lib and a writing caller.

Each issue is enriched by its **own** nested Claude session. One long-lived
session enriching N issues would share a single context across all of them, and
a mid-run context exhaustion would lose the whole batch.

## Components

### `scripts/lib/autopilot-config.sh` (sourced, pure)

`load_autopilot_config <file>` parses the config and validates it. Reads
`${AUTOPILOT_CONFIG:-$HOME/.config/agent-workflow/autopilot.conf}`, so fixture
tests override it with an env var.

Format — `key=value`, one per line, `#` comments, blank lines ignored:

```conf
# maximum issues enriched per run, across all repos
max_per_run=3
# per-issue timeout for the nested enrich session, seconds
enrich_timeout=1800
# allowlisted repos, one line each
repo=freaxnx01/agent-action-sandbox
repo=freaxnx01/game-tschau-sepp
```

The real file is **host-local and not in git**: the allowlist is host policy
("which repos do I let merge AI PRs unattended"), not library content, and
agent-workflow is a public repo. `setup/autopilot.conf.example` is committed as
the documented shape.

Validation is fail-fast: an unknown key, a non-numeric `max_per_run`, a `repo=`
value that is not `owner/name`, or a missing config file is an error, not a
default. A silently-defaulted allowlist is the one failure mode that could aim
the lane at a repo that was never approved.

### `scripts/lib/autopilot-eligible.sh` (query-only)

`repo_eligible <owner/repo>` — exit 0 if the repo may be auto-laned, non-zero
otherwise, with a human-readable reason on stdout either way.

Three conditions, all required:

1. The repo is on the allowlist. Checked by the driver before this is called —
   an outer gate that cannot be flipped from inside a consumer repo.
2. The consumer's `.github/workflows/agent.yml` declares **both**
   `ai-review-ai-merge: true` and `autopilot-test-gate: <workflow-file>`.
3. That named workflow exists and has at least one **completed** run on the
   default branch.

Condition 3 is what #263 demands: no auto-merge on a gate that has never run.
The repo names its own gate rather than the driver guessing which workflow is
"the tests" — a heuristic guarding auto-merge would mean a workflow rename
silently changes eligibility.

```
gh api repos/O/R/contents/.github/workflows/agent.yml
  ai-review-ai-merge: true          ✓
  autopilot-test-gate: ci.yml       ✓
gh api repos/O/R/actions/workflows/ci.yml/runs?branch=<default>&per_page=1
  ≥1 completed run                  ✓  → eligible
  no runs / 404                     ✗  → "test gate ci.yml has never completed a run"
```

### `scripts/lib/autopilot-candidates.sh` (query-only)

`autopilot_candidates <owner/repo> <limit>` emits candidate issue numbers,
oldest `created_at` first.

An issue is a candidate iff **all** hold:

- state is open
- carries `needs-enrichment`
- carries **none** of `🧊 parked`, `enrichment-ongoing`, `needs-human`,
  `ai-implement`
- body is non-empty

`enrichment-ongoing` is an exclusion only. The driver never applies it —
`/enrich` owns that lock and acquires it itself in its Step 2.5. A driver that
pre-applied it would make every enrich session think it had lost a race.

`needs-human` as an exclusion is what stops the lane re-enriching an issue a
human has already been asked to decide on.

### `scripts/lib/agent-cmd-enrich.sh` (the nested session)

Mirrors `agent-cmd-claude-fix.sh`: `claude --print` with a tool allowlist, the
prompt on stdin, `MODEL` passed through `allowed_model_or_fallback` so a
denylisted id is substituted. Runs with the working directory set to the target
repo's clone.

Indirected through an `ENRICH_CMD` env var, the same contract shape as the
existing `AGENT_CMD` / `FIX_AGENT_CMD` wrappers. Tests point `ENRICH_CMD` at a
stub, so **no test ever spawns a real Claude session.**

### The clone cache

`/enrich` commits a spec and a plan and pushes them, so a headless enrich needs
a checkout of the *target* repo. The driver keeps one clone per allowlisted repo
under `~/.cache/agent-workflow/autopilot/<owner>__<repo>`.

Before each enrich: clone if absent, else

```bash
git fetch origin
git checkout main
git reset --hard origin/main
git clean -fdx
```

Every enrich therefore starts from a known-clean `main`, no state is carried
between runs, and a wedged clone is repaired by deleting the directory. The
cache is deliberately **not** the user's own working clones under
`~/repos/github/…` — an unattended timer running `reset --hard` in a directory
a human also works in by hand is how a stray uncommitted change gets destroyed
at 3am.

### `scripts/autopilot.sh` (the driver)

Options: `--dry-run`, `--config <file>`, `--max <n>` (overrides config), `-h`.

Exit codes: `0` success (including "disabled" and "already running"), `2` usage
error, `3` missing dependency, `4` config invalid or unreadable.

Order of operations, with the two cheapest guards first:

1. `flock -n` on `~/.cache/agent-workflow/autopilot/run.lock`; a second
   invocation logs `already running` and exits 0. This lives in the driver, not
   the unit, so it protects a manual shell run and a timer run alike.
2. The disable flag. `~/.config/agent-workflow/autopilot.disabled` present →
   log and exit 0, before a single issue is touched.
3. Load and validate config.
4. Per repo: eligibility, then candidates, honouring the remaining global cap.
5. Per issue: sync clone, run enrich, re-read labels, act, log.

### `commands/autopilot.md`

A thin slash command. **Defaults to `--dry-run`** — the ergonomic use from a
Claude session is "show me what the next run would do", and an unattended lane
should not be startable by accident from a chat prompt. Real runs come from the
timer, or from an explicit shell invocation.

## `--headless` for `/enrich`

`--headless` **implies** `--quick`. Parsing them independently creates a
meaningless combination (`--headless` without quick mode would hit the approval
gate and hang forever), so `parse_enrich_args` sets `QUICK=yes` whenever
`HEADLESS=yes`.

`AskUserQuestion` is forbidden outright in headless mode.

Quick mode today stops and asks on a [one-way door](../../glossary.md#one-way-door).
Headless cannot ask. So on a one-way door, a ⛔ blocked assumption, **or any
`[low]`-confidence assumption**, headless enrich:

- writes the Assumptions block into the issue body as usual, including the ⛔
  items, so the human has the open decision in front of them;
- pushes whatever spec exists, and skips the plan if brainstorming never got far
  enough to have one;
- applies `needs-human`;
- releases the `enrichment-ongoing` lock;
- does **not** apply `ai-implement`;
- exits 0, so the driver's loop continues to the next issue.

`[low]` routing to a human follows #252: until async review of a quick-mode
assumptions block is proven reviewable, a low-confidence guess gets a human.
Confidence is "how likely is the human to disagree", so `[low]` is exactly the
set of decisions worth a human's attention.

## Dispatch

On success the driver applies both labels in **one** `gh issue edit` call:

```bash
gh issue edit "$n" --repo "$repo" --add-label ai-implement,ai-review-ai-merge
```

Two separate calls spawn two workflow runs that race and can cancel each other's
review job (#365). One call, one event, one run.

The driver decides by **re-reading the issue's labels** after the enrich session
exits, rather than trusting the session's exit code or a sentinel line on
stdout. The headless enrich already has `gh` and already does its own labeling,
so the issue is the single source of truth — and this survives the driver being
killed mid-run, because the state is on the issue rather than in the driver's
memory.

## Logging

One line per decision, on stdout, captured by journald. Machine-greppable prefix
and a free-text reason:

```
2026-09-21T19:40:02Z freaxnx01/game-tschau-sepp#41 enriched
2026-09-21T19:52:18Z freaxnx01/game-tschau-sepp#52 needs-human (low-confidence assumption)
2026-09-21T19:52:19Z freaxnx01/game-jass#7 skipped (test gate ci.yml has never completed a run)
2026-09-21T19:52:19Z freaxnx01/game-tschau-sepp#63 skipped (cap reached)
2026-09-21T20:10:44Z freaxnx01/game-tschau-sepp#71 failed (enrich timed out after 1800s)
```

`--dry-run` prints exactly the lines it *would* act on, each prefixed `would:`,
and makes zero writes — no labels, no comments, no clone sync.

## Error handling

| Condition | Driver behaviour |
|---|---|
| Nested enrich exits non-zero | log `failed (enrich exited N)`, release lock, apply `needs-human` |
| Nested enrich exceeds `enrich_timeout` | `timeout` kills it; log `failed (timed out)`, release lock, apply `needs-human` |
| Clone sync fails | log `failed (clone sync)`, skip the issue, do not touch labels |
| `repo_eligible` API call fails | log `skipped (eligibility check failed)`, next repo |
| Config invalid | exit 4 before touching anything |
| Another run holds the flock | log `already running`, exit 0 |

The driver releases `enrichment-ongoing` itself on a failed nested run: it knows
the session died, so there is no reason to make the issue wait out the 24-hour
staleness window that `/enrich`'s own lock detection uses for an abandoned lock.

Applying `needs-human` on a *crash* — not just on a design question — is
deliberate. Without it, a poison issue that reliably kills the enrich session
re-spawns a paid Claude session on every single run, forever. Handing it to a
human is both cheaper and the correct escalation. Repeat-failure counters and
backoff are the more nuanced answer and are explicitly out of scope for v1.

## Kill switch

Two layers, documented in `docs/CONSUMER-SETUP.md` and in the unit file's own
comments:

```bash
# panic button — one touch, no unit knowledge needed, greppable in the log
touch ~/.config/agent-workflow/autopilot.disabled

# proper stop
systemctl --user disable --now agent-autopilot.timer
```

The flag file is checked at the top of every run, so it takes effect from the
next firing without needing the unit's name or systemd at all.

## systemd units

`setup/agent-autopilot.service` — `Type=oneshot`, `EnvironmentFile=` supplying
`CLAUDE_CODE_OAUTH_TOKEN` and `GH_TOKEN`. A `--user` unit inherits nothing from
an interactive shell, so an env file is not optional; both tokens missing is the
most likely first-run failure.

`setup/agent-autopilot.timer` — `OnCalendar=hourly` with
`RandomizedDelaySec=300` and `Persistent=false`. Hourly against a cap of 3 is a
bounded upper rate; the randomized delay keeps a run off the exact top of the
hour. `Persistent=false` matters: a missed run must **not** fire a catch-up
burst of enrichments the moment the host comes back up.

Neither unit is installed by `setup/bootstrap.sh`. Enabling an unattended lane
is a deliberate per-host act, documented as manual steps.

## Testing

**Layer 0** — `shellcheck -x` on every new script, via the existing `lint.yml`.

**Layer 1** — `tests/run-autopilot-tests.sh`, fixture-driven, no network,
registered in `tests/run-all.sh`:

- config: valid, unknown key, non-numeric `max_per_run`, malformed `repo=`,
  missing file, comments and blank lines
- eligibility, one fixture each: no `agent.yml`, `ai-review-ai-merge: false`,
  no `autopilot-test-gate` key, gate workflow 404, gate workflow with zero
  completed runs, all conditions met
- candidates, one fixture per exclusion rule: closed, missing
  `needs-enrichment`, `🧊 parked`, `enrichment-ongoing`, `needs-human`,
  `ai-implement`, empty body — plus ordering (oldest first) and the cap
- driver end-to-end in `--dry-run` against the `gh` mock with `ENRICH_CMD`
  pointed at a stub: the happy path, the needs-human path, the failure path,
  the disable flag, and the flock

Every branch gets a fixture. The suite runs in seconds and never reaches the
network or spawns a real agent.

**Layer 3** — one real end-to-end run against `agent-action-sandbox` before any
game repo is added to the allowlist. This is an acceptance criterion, not an
optional smoke test.

## Risks

1. **Does `claude --print` expand a custom slash command?** The whole design
   rests on `claude --print "/enrich 41 --quick --headless"` resolving the
   custom command rather than treating it as literal text. This is verified
   **first**, before anything else is built. If it does not work, the fallback
   is inlining `commands/enrich.md` into the prompt, which changes the enrich
   wrapper but no other component.
2. **Auth in a `--user` unit.** `CLAUDE_CODE_OAUTH_TOKEN` and `GH_TOKEN` must
   come from `EnvironmentFile=`; nothing is inherited.
3. **Lock ownership.** The driver must never apply `enrichment-ongoing`. It only
   excludes issues already carrying it.

## Prerequisite (tracked elsewhere)

Game repos need re-onboarding with `onboard-consumer.sh --ai-review-ai-merge`
before they can be allowlisted. Observed on game-tschau-sepp on 2026-09-21:
pinned at `@v2`, a deprecated `pre-preview: true`, and the stub still named
`name: Claude` / `jobs: claude`. Tracked under freaxnx01/bridge#218, scoped to
`game-*`. Not part of this change.

## Acceptance criteria

- [ ] `/enrich --quick --headless` never prompts; a one-way door, a ⛔
      assumption, or any `[low]` assumption routes to `needs-human` with the
      lock released and `ai-implement` withheld
- [ ] `/autopilot` applies `ai-implement` and `ai-review-ai-merge` in one
      `gh issue edit` call
- [ ] Non-allowlisted repos are never touched, even if they match every other
      rule
- [ ] Per-run cap enforced globally across repos; `--dry-run` lists what it
      would do and writes nothing
- [ ] systemd unit + timer committed under `setup/` with a documented kill
      switch
- [ ] One end-to-end run against `agent-action-sandbox` before any game repo

## Relates

#252 (async assumption review), #332 (parallel enrich), #274 (baseline commit),
#365 (label race), #263 (unrun gate), freaxnx01/bridge#304 (successor lane),
freaxnx01/bridge#303 (blocker), freaxnx01/bridge#218 (game repo re-onboarding).
