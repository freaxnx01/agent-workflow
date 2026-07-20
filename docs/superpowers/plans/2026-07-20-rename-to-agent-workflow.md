# Rename `agent-pipeline` → `agent-workflow` — Implementation Plan

**Date:** 2026-07-20
**Answers:** open decision §1 of
`docs/superpowers/specs/2026-07-20-consolidate-command-surface-design.md`
**Supersedes:** ADR-005's naming consequence

## Why

ADR-005 reframed this repo as "CI + operator console," and the consolidation
spec proposes moving the remaining 11 commands here — `/wt:status`, `/wrap-up`,
`/handoff`. None of those are a pipeline. The name would describe a shrinking
fraction of the contents, which is the same failure `config` has.

`agent-workflow` covers both halves: the CI that implements issues, and the
console that feeds it.

## Global constraints

1. **Consumer CI must not break at any point.** Six repos depend on this one.
2. **Never rewrite history documents.** Files under `docs/superpowers/**` in
   either repo are dated records of what was true when written. A spec titled
   *"move … into `agent-pipeline`"* stays that way. Only **live** references
   change: scripts, READMEs, command bodies, `CONSUMER-SETUP.md`, workflow YAML.

   **One carve-out:** `2026-07-20-consolidate-command-surface-design.md` is an
   *open* decision document, not a record — its §2–§4 still drive future work,
   and it names this repo as the consolidation target. It gets updated (target
   repo, §1 marked resolved). The test is status, not directory: **open
   documents track reality; closed ones preserve it.**
3. **Do not rely on GitHub's rename redirect as the end state.** It is the safety
   net during the migration, not the destination — it dies silently the day any
   repo claims the name `freaxnx01/agent-pipeline`.
4. Every step has a `verify:` that must pass before the next begins.

## Current state — surveyed 2026-07-20

Ten workflow files across six consumer repos, in **three inconsistent pinning
styles**:

| Repo | File | Reference | Pin |
|---|---|---|---|
| `flowhub` | `claude.yml` | `claude-implement.yml` | `@main` ⚠ |
| `flowhub` | `quality.yml` | `.github/actions/dotnet-quality` | `@c3977e1` |
| `FlowHub-CAS-AISE` | `claude.yml` | `claude-implement.yml` | `@main` ⚠ |
| `FlowHub-CAS-AISE` | `quality.yml` | `.github/actions/dotnet-quality` | `@c3977e1` |
| `quotes` | `claude.yml` | `claude-implement.yml` | `@38875ee` |
| `quotes` | `chain-dispatch.yml` | `chain-dispatch.yml` | `@bae2aa2` |
| `quicktask-vikunja` | `claude.yml` | `claude-implement.yml` | `@v1` |
| `quicktask-vikunja` | `vuln-scan.yml` | prose reference only | — |
| `bridge` | `claude.yml` | `claude-implement.yml` | `@v1` |
| `agent-action-sandbox` | `agent.yml` | `claude-implement.yml` | `@main` ⚠ |

Two findings that predate this work:

- **`.github/actions/dotnet-quality` is a second public entry point.** It is a
  composite action consumed by two repos and is not mentioned in
  `CONSUMER-SETUP.md`. It must be covered by the rename and should be documented.
- **Three consumers pin `@main`**, which the CI stack overlay explicitly forbids
  (*"Do not pin actions to floating tags. Always full SHA + comment"*). Out of
  scope to fix here — but it means those three will silently follow whatever
  lands on `main` during this migration. **Do them first** (Task 4a).

Internal: 184 references across 28 files here, ~170 in `config` (mostly history
docs, which stay).

## Tasks

### Task 1 — ADR-006 recording the rename

Add to `docs/DECISIONS.md`: context (ADR-005 + consolidation spec), decision
(`agent-workflow`, why the name fits both halves), consequences (redirect is
transitional; `dotnet-quality` is a second entry point; consumers must be
updated explicitly; per-file history unaffected).

`verify:` `docker run … markdownlint-cli2` clean; ADR numbering contiguous.

### Task 2 — internal live references

Update the 28 files here **except** `docs/superpowers/**` and `CHANGELOG.md`
entries describing past releases. Includes `setup/link-commands.sh`
(`REPO_URL`, `REPO_DIR`), `scripts/onboard-consumer.sh`, `justfile`,
`docs/DESIGN.md`, `docs/CONSUMER-SETUP.md`, `commands/**`, `commands/README.md`.

Also update the consolidation spec per the carve-out above: its target repo
becomes `agent-workflow`, and open decision §1 is marked resolved by ADR-006.

`verify:` `rg 'agent-pipeline' --glob '!docs/superpowers/**' --glob '!CHANGELOG.md'`
returns only intentional historical mentions; `shellcheck -x` clean;
`just test` (Layer-1 fixtures) green; lint + gate-selftest green in CI.

### Task 3 — `config`'s live references

`setup/01-claude-commands.sh` (`AP_REPO_URL`, `AP_REPO_DIR`), `README.md`,
`claude/commands/README.md`, `claude/commands/update-commands.md`,
`claude/commands/commands.md`, `claude/commands/todo.md`. **Not**
`config/docs/superpowers/**`.

`verify:` fresh-clone bootstrap in a scratch container reaches a working
46-command install from the documented URL.

### Task 4 — the rename itself

Merge Tasks 1–3 first, then:

```bash
gh repo rename agent-workflow --repo freaxnx01/agent-pipeline
git -C ~/repos/github/freaxnx01/public/agent-pipeline remote set-url origin \
  https://github.com/freaxnx01/agent-workflow.git
mv ~/repos/github/freaxnx01/public/{agent-pipeline,agent-workflow}
```

The local move invalidates the `.worktrees/div` worktree's gitdir pointer —
the exact orphaning that produced `.worktrees/misc`. Re-point or remove it
deliberately; do not leave it dangling.

`verify:` `gh repo view freaxnx01/agent-workflow` resolves; old URL redirects;
`git -C … fetch` works from the moved path; `git worktree list` clean;
re-run the install → 46 commands, 0 broken.

### Task 4a — the three `@main` consumers, immediately after

`flowhub`, `FlowHub-CAS-AISE`, `agent-action-sandbox`. They track `main`, so
they are the most exposed. One PR each changing the org/repo segment.

`verify:` trigger one real run per repo and confirm green before proceeding.

### Task 5 — remaining consumers

`quotes` (×2), `quicktask-vikunja`, `bridge`. Same change; SHA and `@v1` pins
keep working via redirect while these land, so they are lower-risk.

`verify:` `rg -l 'freaxnx01/agent-pipeline'` across all six repos returns
nothing outside history docs.

### Task 6 — release

Cut `v1.7.0`, move the `v1` tag. Update `CHANGELOG.md` under `[Unreleased]`
with the rename and a migration note for external readers.

`verify:` `@v1` resolves under the new name; `git-cliff` output includes the
migration note.

## Rollback

Before Task 4, everything is ordinary PRs — revert them. After Task 4,
`gh repo rename agent-pipeline` restores the old name and its redirects invert.
The irreversible boundary is **someone else claiming `freaxnx01/agent-pipeline`**,
so do not create a placeholder repo under the old name. If a stub is ever wanted
to catch stale references, it must come *after* Task 5 verifies zero remaining
consumers.

## Success criteria

1. All six consumer repos run green against `freaxnx01/agent-workflow`.
2. No live reference to `agent-pipeline` outside dated history docs.
3. Fresh-machine bootstrap works from the documented URL.
4. `@v1` resolves; `CHANGELOG.md` carries the migration note.
5. `docs/DECISIONS.md` has ADR-006; the consolidation spec's §1 is marked resolved.
6. No orphaned worktrees left by the local directory move.

## Not in this plan

- The consolidation itself (spec decisions §2–§4 remain open).
- Fixing the three `@main` pins to SHAs — real, pre-existing, tracked separately.
- Documenting `dotnet-quality` in `CONSUMER-SETUP.md` — surfaced here, fixed separately.
- Renaming `config`. Its naming problem is spec decision §3's business.
