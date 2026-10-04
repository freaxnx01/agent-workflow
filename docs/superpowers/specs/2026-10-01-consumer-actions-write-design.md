# Catch consumer stubs that grant less than the reusable workflow requests

**Issue:** [#434](https://github.com/freaxnx01/agent-workflow/issues/434)
**Date:** 2026-10-01
**Status:** Draft (quick-mode enrichment — assumptions recorded in the issue body)

## Problem

`agent-implement.yml`'s `implement` job requests `actions: write` (the
retry re-dispatch, #351). A reusable workflow can never be granted more than its
caller, so a consumer `agent.yml` without `actions: write` makes GitHub refuse
**every** `ai-implement` dispatch at `startup_failure` — zero jobs, no logs.
Seen in `freaxnx01/game-sky-fury` after its bump to `@v2`; fixed there by
game-sky-fury#7.

### The issue's premise is half stale

The issue says the template lacks `actions: write`. On `origin/main` it does
not any more:

- `docs/CONSUMER-SETUP.md:159` — added by `58dc477` (2026-09-23).
- `scripts/onboard-consumer.sh:353` (`build_agent_yml`) — added by `d78bc8b`
  (2026-09-24); already asserted by `tests/run-onboard-stub-tests.sh`.

Both predate the issue (filed 2026-09-27). game-sky-fury was onboarded from the
**older** template; the v1→v2 fleet migration only rewrote the `uses:` pin and
never touched `permissions:`.

### The real gap is the fleet, and the missing guard

A read-only sweep on 2026-10-01 (`gh search code` for consumer `agent.yml`
stubs, then grep for `actions: write`) found **38 of 73** consumers pinned to
`@v2` without `actions: write` — every one of them is currently unable to run
the pipeline. All 38 are `freaxnx01/game-*` repos (e.g. `game-tank-toys`,
`game-kick-fury`, `game-space-invaders`).

Two things let this happen and will let it happen again:

1. **Nothing ties the stubs to the workflow.** The onboard test hard-codes four
   scope names. The next time a job in `agent-implement.yml` gains a scope, the
   template, the onboard stub and this repo's own `agent.yml` can all go stale
   with every test green.
2. **The fleet tool cannot see it.** `migrate-consumers.sh` reports which ref
   each consumer pins, but a consumer that pins the right ref and still cannot
   start looks identical to a healthy one.

## Approach

1. **`scripts/check-caller-permissions.sh <caller|-> <reusable>`** — a static
   comparison using GitHub's own rules: a job's effective permissions are its
   own `permissions:` block if present, else the workflow-level one (replace,
   not merge); `read-all`/`write-all` cover every scope; `write` satisfies
   `read`; a caller with no block grants nothing reliable. Prints one line per
   gap, exits 0 / 1 (gap) / 2 (usage). Pure awk + bash, no `yq` — the Layer-1
   suite has no YAML tooling and must stay hermetic.
2. **An invariant test** (`tests/run-caller-permissions-tests.sh`, picked up by
   `tests/run-all.sh` automatically) that runs the checker over every stub this
   repo ships or documents, against the workflow each one calls:
   - the complete `agent.yml` stub in `docs/CONSUMER-SETUP.md` → `agent-implement.yml`
   - the `chain-dispatch.yml` stub in `docs/CONSUMER-SETUP.md` → `chain-dispatch.yml`
   - `build_agent_yml` / `build_chain_yml` from `onboard-consumer.sh` (extracted
     from the shipped script, as the existing onboard test does)
   - this repo's own `.github/workflows/agent.yml`

   Each is derived from the workflow, not from a hard-coded scope list, so a new
   scope in a reusable job fails the suite until every stub is updated.
3. **`migrate-consumers.sh` reports permissions.** Every per-repo line in
   inventory, dry-run and already-on-target output gains `perms:ok` or
   `perms:MISSING <scopes>`. This *is* the "check the other consumers" task:
   `bash scripts/migrate-consumers.sh --owner freaxnx01` lists the broken ones.
   Read-only; it does not fix them.
4. **Docs.** `CONSUMER-SETUP.md`'s fleet section shows the new column and says
   what to do about `perms:MISSING`.

The template and onboard stub need **no** content change — they are already
correct; the work is making sure they stay so.

## Acceptance criteria

- `scripts/check-caller-permissions.sh` exists, is shellcheck-clean, and reports
  `actions: needs write, caller grants none` for a stub shaped like
  game-sky-fury's pre-#7 `agent.yml`.
- `tests/run-caller-permissions-tests.sh` passes on the branch and is run by
  `just test`.
- Deleting `actions: write` from the `CONSUMER-SETUP.md` stub (or from
  `build_agent_yml`, or from this repo's `agent.yml`) makes `just test` fail.
- The invariant cannot pass vacuously: it fails if no documented stub is found.
- `migrate-consumers.sh` inventory lines end in `perms:ok` / `perms:MISSING …`,
  covered by a hermetic test through the `gh` mock.
- `docs/CONSUMER-SETUP.md` documents the column and the remedy.

## Out of scope

- **Editing the 38 consumer repos.** A mass write across other repos is a
  one-way-door-ish operator action; it stays with the human. The inventory
  makes the list; a follow-up issue (or a `--fix-permissions` mode for
  `migrate-consumers.sh`) can carry the rollout.
- Teaching `migrate-consumers.sh --apply` to add missing permissions.
- The `chain-dispatch.yml@v1` pin in the documented chain stub
  (`CONSUMER-SETUP.md:436`) — a separate discovery, parked.
- `docs/ai-notes/quicktask-vikunja-pipeline-runbook.md:264-268` — a dated
  working note quoting the stub as it was; history, not a template.
- Partial `jobs:`-only snippets in `docs/DESIGN.md` and
  `docs/PIPELINE-APP-SETUP.md` — they show no `permissions:` block on purpose.
