# Backlog Guard Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--add-milestone-guard` to `scripts/migrate-consumers.sh` so an operator can roll the #646 backlog milestone guard out to existing consumer repos — one PR per repo, `backlog` created where missing, un-milestoned issues counted.

**Architecture:** The stub text moves into `scripts/lib/milestone-stub.sh`, shared by `onboard-consumer.sh` and `migrate-consumers.sh`. Milestone and issue queries live in `scripts/lib/backlog-milestone.sh`. The new mode is a fourth branch in `migrate-consumers.sh`'s per-repo loop, shaped like `--fix-perms` (#441): dry run by default, `--apply` writes, always via PR, one verdict line per repo, tally, exit 1 on any failure.

**Tech Stack:** Bash 5, `gh` CLI, `jq`; Layer-1 tests with `tests/mocks/gh`.

**Spec:** `docs/superpowers/specs/2026-11-20-backlog-guard-rollout-design.md`

## Global Constraints

- Every script: `set -euo pipefail`, `IFS=$'\n\t'`, quoted expansions; `shellcheck -x -e SC1091` clean.
- Tests never call the real GitHub API; `gh` is `tests/mocks/gh` on `PATH`.
- New tests go in a NEW runner `tests/run-migrate-guard-tests.sh`. Do not edit `tests/run-script-tests.sh`.
- `--fix-perms`, `--to`, `--rename-flow` and inventory output must not change; `tests/run-script-tests.sh`, `tests/run-onboard-stub-tests.sh` and `tests/run-backlog-milestone-guard-tests.sh` stay green unchanged.
- Public repo: no repo names under owners other than `freaxnx01` and the fixture owner `o` in code, fixtures, docs or commits.
- Branch default for the mode: `ci/backlog-milestone-guard`. Stub path: `.github/workflows/issue-milestone.yml`.
- Qualifying ref: a moving major `vN` with N ≥ 2, or an exact pin `vX.Y.Z` ≥ `v2.3.0`. Nothing else, `--force` included.
- Exit codes of the mode: `0` all handled, `1` at least one repo failed, `2` bad arguments.

## Review Focus

- A consumer whose `agent.yml` pins `v2.2.1` (exact, older than the guard) → skipped, never given a stub that 404s. Test in Task 3.
- `issue-milestone.yml` lookup fails with something other than 404 (outage) → repo FAILED, not "guard absent → add". Test in Task 3.
- A closed `backlog` milestone → repo counted failed, no milestone created, no PR. Test in Task 3.
- Milestone creation succeeds but the stub write fails → repo FAILED and the line says the milestone was created (so a re-run doesn't surprise). Test in Task 4.
- Two pages of un-milestoned issues with a PR among them → count spans pages and excludes the PR. Test in Task 2.

---

### Task 1: Shared stub library

**Files:**
- Create: `scripts/lib/milestone-stub.sh`
- Modify: `scripts/onboard-consumer.sh` (remove `build_milestone_yml`, ~lines 429-453; source the lib near its other `source` lines; both call sites ~535 and ~550)
- Test: `tests/run-migrate-guard-tests.sh` (create; same `section`/`assert_*` helper style as `tests/run-backlog-milestone-guard-tests.sh`)

**Interfaces:**
- Produces: `build_milestone_yml <pipeline-repo> <ref>` — prints the stub to stdout. Text identical to today's function with `$PIPELINE_REPO`/`$REF` replaced by the two arguments. Query.

- [ ] **Step 1: Write the failing test** in the new runner, section `milestone stub`:
  - `out="$(source scripts/lib/milestone-stub.sh; build_milestone_yml freaxnx01/agent-workflow v2)"`
  - assert `out` contains `uses: freaxnx01/agent-workflow/.github/workflows/backlog-milestone.yml@v2`
  - assert `out` contains `      pipeline-ref: v2`
  - assert `out` contains `issue-number: ${{ github.event.issue.number }}` (literal, unexpanded)
  - assert `out` contains `types: [opened, reopened]` and `      issues: write`
  - assert `actionlint -` accepts it when actionlint is on PATH (skip with a note otherwise): `printf '%s\n' "$out" > "$tmp/issue-milestone.yml" && actionlint "$tmp/issue-milestone.yml"`

- [ ] **Step 2: Run** `bash tests/run-migrate-guard-tests.sh` — Expected: FAIL (lib file does not exist).

- [ ] **Step 3: Implement** `scripts/lib/milestone-stub.sh` (no `set -e` at top level — it is sourced; header comment naming #646/#653) and switch `onboard-consumer.sh` to `build_milestone_yml "$PIPELINE_REPO" "$REF"`.

- [ ] **Step 4: Verify**
  Run: `bash tests/run-migrate-guard-tests.sh && bash tests/run-onboard-stub-tests.sh`
  Expected: both end with 0 failed.

- [ ] **Step 5: Commit** — `refactor(onboard): move the milestone guard stub into scripts/lib (#653)`

### Task 2: Milestone and issue queries

**Files:**
- Modify: `scripts/lib/backlog-milestone.sh`
- Modify: `scripts/backfill-backlog-milestone.sh` (`list_unmilestoned` → call the lib function; behaviour unchanged)
- Create: fixtures under `tests/fixtures/migrate-guard/`
- Test: `tests/run-migrate-guard-tests.sh`

**Interfaces:**
- Produces (all in `scripts/lib/backlog-milestone.sh`):
  - `list_unmilestoned_issues <repo>` — open issue numbers without a milestone, all pages (`--paginate`, `jq -s`), pull requests dropped; one per line; returns 1 if the list cannot be read. Query. (This is today's `list_unmilestoned` with `$REPO` as a parameter.)
  - `backlog_milestone_state <repo>` — prints `open <number>`, `closed <number>` or `missing`, from `repos/<repo>/milestones?state=all&per_page=100 --paginate`, exact title match on `$BACKLOG_MILESTONE`; an open one wins over a closed one; returns 1 if unreadable. Query.
  - `create_backlog_milestone <repo>` — `gh api -X POST repos/<repo>/milestones -f title=backlog -f description=<text naming freaxnx01/ai-instructions#61>`; prints the new number (`--jq .number`); returns 1 on failure. Command.
- Consumes: `BACKLOG_MILESTONE` (existing).

- [ ] **Step 1: Write the failing tests**, section `milestone queries`, each run with `PATH="$MOCKS:$PATH" GH_MOCK_LOG=… GH_MOCK_STDOUT_MAP=…`:
  - `list_unmilestoned_issues o/r` over a two-page fixture (page 1: issues 1, 2 and a PR 3; page 2: issue 4) prints exactly `1\n2\n4`.
  - `backlog_milestone_state o/r` → `open 7` (fixture has open `backlog` #7 and closed `v1.0`); → `closed 5` (only a closed `backlog` #5); → `missing` (only `v1.2 · goal`); → `open 7` when both an open #7 and a closed #5 `backlog` exist.
  - `backlog_milestone_state` with the milestones call in `GH_MOCK_FAIL_MAP` returns 1.
  - `create_backlog_milestone o/r` with a fixture `{"number": 9}` prints `9`, and the mock log contains `api -X POST repos/o/r/milestones -f title=backlog`.

- [ ] **Step 2: Run** the runner — Expected: FAIL (functions not defined).

- [ ] **Step 3: Implement** the three functions; make `backfill-backlog-milestone.sh`'s `list_unmilestoned` a one-line call to `list_unmilestoned_issues "$REPO"` (or replace its call site).

- [ ] **Step 4: Verify**
  Run: `bash tests/run-migrate-guard-tests.sh && bash tests/run-backlog-milestone-guard-tests.sh`
  Expected: both 0 failed.

- [ ] **Step 5: Commit** — `feat(milestone): milestone state, creation and un-milestoned listing in the backlog lib (#653)`

### Task 3: `--add-milestone-guard` — arguments and dry run

**Files:**
- Modify: `scripts/migrate-consumers.sh` (flag parsing ~260-290; per-repo loop ~380-450; header usage block)
- Create: fixtures under `tests/fixtures/migrate-guard/` (agent.yml stubs pinned `v2`, `v2.2.1`, `v2.3.0`, `v1`, `main`)
- Test: `tests/run-migrate-guard-tests.sh`

**Interfaces:**
- Consumes: `build_milestone_yml` (Task 1); `backlog_milestone_state`, `list_unmilestoned_issues` (Task 2); existing `current_ref`, `with_backoff`, `USE_PR`, `BRANCH`, `APPLY`, counters `changed/skipped/failed`.
- Produces:
  - `guard_ref_ok <ref>` — exit 0 iff the ref qualifies (Global Constraints). Query.
  - `add_guard_repo <repo> <cur>` — the mode's verdict for one repo, and with `--apply` the writes (Task 4). Updates the counters. Command.
  - Variable `ADD_GUARD=true` set by `--add-milestone-guard`; `GUARD_PATH='.github/workflows/issue-milestone.yml'`.

Verdict lines (two spaces between columns, exact text the tests assert):
- `<repo>  <cur>  guard present` — skipped
- `<repo>  <cur>  skipped (pins <cur>; guard needs v2.3.0+)` — skipped
- `<repo>  <cur>  PR already open <url>` — skipped
- `<repo>  <cur>  backlog:CLOSED  not edited` — failed
- `<repo>  <cur>  CHECK FAILED (<what>)` — failed (guard lookup not a 404, milestone list, issue list, or PR list unreadable)
- `<repo>  <cur>  would add guard  backlog:<present|would create>  unmilestoned:<N>` — changed (dry run)

Order of checks per repo: ref → guard file (`gh api repos/<repo>/contents/<GUARD_PATH>`; a 404 means absent, any other failure is CHECK FAILED) → open PR on `$BRANCH` → `backlog_milestone_state` → `list_unmilestoned_issues` count.

- [ ] **Step 1: Write the failing tests**, section `add-milestone-guard — dry run`, driving `CONSUMERS=… bash scripts/migrate-consumers.sh --add-milestone-guard` with the gh mock:
  - `guard_ref_ok`: true for `v2`, `v3`, `v2.3.0`, `v2.10.0`, `v3.0.0`; false for `v1`, `v2.2.1`, `main`, a 40-hex SHA, empty.
  - Repo pinned `v2`, guard 404, no open PR, `backlog` open, 3 un-milestoned → line `o/a  v2  would add guard  backlog:present  unmilestoned:3`; log has no `-X POST` and no `-X PUT`.
  - Same with `backlog` missing → `backlog:would create`.
  - Guard file exists → `o/a  v2  guard present`.
  - Pinned `v2.2.1` → `o/a  v2.2.1  skipped (pins v2.2.1; guard needs v2.3.0+)`; also with `--force` added.
  - Guard lookup fails with stderr `HTTP 500` (FAIL_MAP) → `CHECK FAILED`, exit 1.
  - Closed `backlog` → `o/a  v2  backlog:CLOSED  not edited`, exit 1, no POST.
  - Open PR on `ci/backlog-milestone-guard` → `PR already open <url>`.
  - Tally line `1 changed, 0 skipped, 0 failed` for the first case; exit 0.
  - `--add-milestone-guard --to v2`, `--add-milestone-guard --fix-perms`, `--add-milestone-guard --rename-flow` → exit 2 each.

- [ ] **Step 2: Run** the runner — Expected: FAIL (unknown flag).

- [ ] **Step 3: Implement** flag parsing (sets `USE_PR=true`, `BRANCH` default `ci/backlog-milestone-guard`, mutual-exclusion usage errors), `guard_ref_ok`, and `add_guard_repo` up to the dry-run line; dispatch to it from the loop right after `current_ref`, like `fix_perms_repo`. Exit 1 at the end when `ADD_GUARD` and `failed > 0`. Source `lib/milestone-stub.sh` and `lib/backlog-milestone.sh`.

- [ ] **Step 4: Verify**
  Run: `bash tests/run-migrate-guard-tests.sh && bash tests/run-script-tests.sh`
  Expected: both 0 failed (the second proves existing modes unchanged).

- [ ] **Step 5: Commit** — `feat(migrate): --add-milestone-guard dry run reports per-repo guard status (#653)`

### Task 4: `--add-milestone-guard --apply` — create, write, PR

**Files:**
- Modify: `scripts/migrate-consumers.sh` (`add_guard_repo`; a writer for a NEW file)
- Test: `tests/run-migrate-guard-tests.sh`

**Interfaces:**
- Consumes: `create_backlog_milestone` (Task 2), `build_milestone_yml` (Task 1).
- Produces: `put_new_file <repo> <path> <content> <message>` — creates `$BRANCH` from the default branch head if absent (as `put_stub` does) and `PUT repos/<repo>/contents/<path>` with `branch=$BRANCH`, no `sha`. Returns 1 on failure. Command. (`put_stub` stays as is.)

Apply lines:
- `<repo>  <cur>  added guard → PR <url>  backlog:<present|created>  unmilestoned:<N>` — changed
- `<repo>  <cur>  MILESTONE CREATE FAILED` — failed, nothing else written
- `<repo>  <cur>  WRITE FAILED  backlog:<present|created>` — failed
- `<repo>  <cur>  PR FAILED (branch <branch> written)  backlog:<present|created>` — failed

PR title: `ci(milestone): assign backlog to issues opened without a milestone`. Body names freaxnx01/agent-workflow#646 and freaxnx01/ai-instructions#61 and says the stub is what `onboard-consumer.sh` writes.

- [ ] **Step 1: Write the failing tests**, section `add-milestone-guard — apply`:
  - `backlog` missing, all writes succeed → log order: `-X POST repos/o/a/milestones` before `-X PUT repos/o/a/contents/.github/workflows/issue-milestone.yml`, then `pr create --repo o/a --head ci/backlog-milestone-guard`; line contains `added guard → PR` and `backlog:created`; exit 0.
  - The PUT's base64 `content` decodes to `build_milestone_yml freaxnx01/agent-workflow v2` output (+ trailing newline) — decode it from the mock log.
  - `backlog` present → no POST; `backlog:present`.
  - POST fails → `MILESTONE CREATE FAILED`, no PUT, exit 1.
  - PUT fails after a successful POST → `WRITE FAILED  backlog:created`, exit 1.
  - `pr create` fails → `PR FAILED (branch ci/backlog-milestone-guard written)`, exit 1.
  - Skipped verdicts from Task 3 (guard present, old pin, closed backlog) issue no POST/PUT even with `--apply`.

- [ ] **Step 2: Run** the runner — Expected: FAIL.

- [ ] **Step 3: Implement** `put_new_file` and the apply branch of `add_guard_repo` (create milestone only when state is `missing`; then write; then `with_backoff gh pr create`).

- [ ] **Step 4: Verify**
  Run: `bash tests/run-migrate-guard-tests.sh && bash tests/run-all.sh && shellcheck -x -e SC1091 scripts/migrate-consumers.sh scripts/lib/milestone-stub.sh scripts/lib/backlog-milestone.sh scripts/onboard-consumer.sh scripts/backfill-backlog-milestone.sh tests/run-migrate-guard-tests.sh`
  Expected: runner 0 failed; `run-all.sh` 0 failed; shellcheck no output.

- [ ] **Step 5: Commit** — `feat(migrate): --add-milestone-guard --apply creates backlog and opens the guard PR (#653)`

### Task 5: Docs and changelog

**Files:**
- Modify: `scripts/migrate-consumers.sh` header (mode, branch default, exit code 1 now also for this mode, and a block "Rolling out the backlog guard (#653) — an operator step, never run by CI" with dry run, `--apply`, and the backfill follow-up `bash scripts/backfill-backlog-milestone.sh -R <owner/repo>` then `--apply`)
- Modify: `docs/CONSUMER-SETUP.md` §3d — existing consumers: the command above; note it covers repos under the personal owner, and that repos with their own milestone scheme should be decided case by case (no names)
- Modify: `CHANGELOG.md` — one bullet under the top-level unreleased area the repo currently uses for hand-written entries: `*(migrate)* --add-milestone-guard rolls the backlog milestone guard out to existing consumers, one PR per repo (#653)`

- [ ] **Step 1: Write the failing test**, section `docs`: the header of `scripts/migrate-consumers.sh` contains `--add-milestone-guard` and `ci/backlog-milestone-guard`; `docs/CONSUMER-SETUP.md` contains `--add-milestone-guard`.
- [ ] **Step 2: Run** the runner — Expected: FAIL.
- [ ] **Step 3: Edit** the three files.
- [ ] **Step 4: Verify**
  Run: `bash tests/run-migrate-guard-tests.sh && git add -A && pre-commit run --all-files`
  Expected: 0 failed; all hooks pass (markdownlint included).
- [ ] **Step 5: Commit** — `docs(migrate): document the backlog guard rollout (#653)`

## Post-merge (manual — NOT for the implementing agent)

Do not run the rollout against real repos, create milestones, or open consumer PRs. After merge an interactive session, on the user's yes: dry run with `--owner freaxnx01`, then `--apply`, merge the PRs, then backfill per repo (dry run first), and report counts on #653.
