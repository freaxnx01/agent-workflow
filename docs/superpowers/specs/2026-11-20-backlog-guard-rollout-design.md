# Roll the backlog milestone guard out to existing consumers (#653)

## Intent

`freaxnx01/ai-instructions` `conventions/milestones.md` (#62) says that in
**every repo** every open issue has a milestone and `backlog` exists as the
default. #646 shipped the guard that enforces it (`backlog-milestone.yml`,
released in v2.3.0, live under `@v2`). New consumers get the caller stub from
`scripts/onboard-consumer.sh`; agent-workflow and ai-instructions have it.
Every other existing consumer does not. This change adds a supported,
repeatable way to roll the stub out to them, one PR per repo, and to make sure
each of them has a `backlog` milestone.

## Goals

- One operator command that, per consumer repo: reports whether the guard is
  present, whether `backlog` exists, and how many open issues lack a milestone;
  and with `--apply` creates a missing `backlog` milestone and opens a PR that
  adds `.github/workflows/issue-milestone.yml`.
- Dry run by default, a per-repo verdict line, a closing tally, and a non-zero
  exit when any repo could not be handled — the `--fix-perms` contract (#441).
- The stub is byte-identical to what `onboard-consumer.sh` writes, from one
  source.

## Non-goals

- **Backfilling issues.** The rollout only counts un-milestoned issues. The
  backfill stays a separate, per-repo step with
  `scripts/backfill-backlog-milestone.sh` (dry run first).
- **Merging the PRs.** The rollout opens them; merging is the operator's step.
- **Repos under other owners.** The rollout run covers consumers under the
  personal account only (`--owner freaxnx01`). Repos under other owners can use
  their own milestone schemes (for example milestones that scope customer
  releases), where an automatic `backlog` would change what a release contains.
  The tool still accepts `--repo` for any repo, but the documented rollout does
  not target them.
- Forgejo / Azure DevOps: the guard is GitHub-only (#646).

## Anti-goals

- A silent write: no milestone creation and no PR without `--apply`.
- A second copy of the stub text that can drift from `onboard-consumer.sh`.
- A direct push to a consumer's default branch.

## Approaches

- **A — new mode in `scripts/migrate-consumers.sh` (chosen).** It already does
  fleet discovery (`--owner`, `--repo`, `CONSUMERS`), dry run vs `--apply`,
  per-repo PRs and the counters, and `--fix-perms` (#441) is the same shape:
  add something to each repo, one PR each. Trade-off: the script grows a fourth
  mode.
- B — a separate `rollout-milestone-guard.sh`. Cleaner separation, but
  discovery, dry-run and PR handling would be duplicated or first extracted into
  `lib/` — more refactoring than the task.
- C — a one-off loop run from a session. Cheapest, but not repeatable or
  tested; the issue's ACs want a per-repo report including skipped repos, and
  the CI stack requires tests for scripts.

The user picked A.

## Decisions

1. **Flag:** `--add-milestone-guard`. Not combinable with `--to`,
   `--rename-flow` or `--fix-perms` (usage error, exit 2) — like `--fix-perms`,
   it is a separate PR. Always via PR: the mode sets `USE_PR=true`; branch
   defaults to `ci/backlog-milestone-guard`.
2. **Stub source:** move `build_milestone_yml` out of
   `scripts/onboard-consumer.sh` into a new `scripts/lib/milestone-stub.sh`
   (taking the pipeline repo and ref as arguments) and source it from both
   scripts. `tests/run-onboard-stub-tests.sh` must stay green unchanged.
3. **Ref in the stub:** the consumer's current `agent-implement.yml` ref, read
   with the existing `current_ref`. Only a `v2`-or-later version pin
   (`^v([2-9]|[1-9][0-9])`) qualifies — the guard does not exist on `v1` or
   before `v2.3.0`; for an exact pin `vX.Y.Z` the guard needs `>= v2.3.0`.
   Anything else (`v1`, `main`, a SHA, an older exact pin) → skipped with the
   reason; `--force` does **not** override this (a stub pointing at a ref
   without the workflow fails on every issue event).
4. **Per-repo verdicts** (one line each, `<repo>  <ref>  <verdict>  <detail>`):
   - `guard present` — `.github/workflows/issue-milestone.yml` exists → skipped.
   - `PR already open <url>` — an open PR from the branch → skipped. A failed
     PR lookup fails the repo (same reasoning as `--fix-perms`).
   - `skipped (pins <ref>; guard needs v2.3.0+)` → skipped.
   - `would add guard` / `added guard → PR <url>`, with
     `backlog:<present|would create|created|CLOSED>` and `unmilestoned:<N>`.
   - `backlog:CLOSED` — a closed `backlog` exists → the repo is skipped and
     counted as failed: reopening is a decision for the operator, not the tool.
   - Read or write failure → `… FAILED`, counted as failed.
5. **`backlog` creation:** with `--apply`, a missing `backlog` milestone is
   created (`POST repos/<repo>/milestones`, title `backlog`, no due date,
   description pointing at ai-instructions#61) **before** the stub PR. This is
   an explicit operator action; the "never create silently" rule applies to the
   guard and the commands, not to this rollout.
6. **Count:** open issues without a milestone, pull requests excluded, all
   pages. Reuse the listing the backfill script uses if it can be shared
   without changing that script's behaviour; otherwise a small helper in
   `scripts/lib/backlog-milestone.sh`.
7. **Exit codes:** `0` all handled (including "nothing to do"), `1` at least
   one repo failed, `2` bad arguments.

## Constraints

- CI-stack rules: `set -euo pipefail`, quoted expansions, shellcheck clean,
  every branch covered by a fixture with `gh` mocked — no real API calls in
  tests.
- Tests go in a **new** runner `tests/run-migrate-guard-tests.sh` (picked up by
  `tests/run-all.sh`), not in `tests/run-script-tests.sh`, which other open work
  edits.
- Public repo: no names of repos under other owners in code, fixtures, docs or
  commit messages.
- The `--fix-perms`, `--to` and `--rename-flow` behaviour and output must not
  change.

## Docs

- Header of `migrate-consumers.sh`: the new mode, its branch default, and a
  "Rolling out the backlog guard (#653)" operator block like the #441 one.
- `docs/CONSUMER-SETUP.md` §3d: how existing consumers get the stub (the
  command) besides onboarding.
- `CHANGELOG.md`: one `Added` entry.

## Post-merge (manual, not the pipeline)

An interactive session, on the user's yes:

1. `bash scripts/migrate-consumers.sh --owner freaxnx01 --add-milestone-guard`
   (dry run) and show the report.
2. `--apply`, then merge the opened PRs.
3. Per repo with `unmilestoned > 0`: `backfill-backlog-milestone.sh` dry run,
   then `--apply`.
4. Report counts on #653.

## Left to the builder

- Exact helper names and where the count helper lives (Decision 6).
- Fixture layout under `tests/fixtures/`.
- Wording of PR title/body, as long as it names #646 and ai-instructions#61.
