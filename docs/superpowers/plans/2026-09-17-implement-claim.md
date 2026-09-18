# Implement Claim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The implement job takes a visible claim on the issue before the agent runs and releases it when the run ends, so a local session and the pipeline can no longer implement the same issue at once — with staleness decided by the referenced run's real state, never by elapsed time.

**Architecture:** A shared library parses a claim comment and resolves the referenced run's liveness. Two thin scripts sit on top — one acquires (check → claim → re-check → stand down if it lost), one releases. `agent-implement.yml` calls acquire before the agent and release in an `always()` step. `ensure-issue-labels.sh` creates the label, because `--add-label` fails outright on a label that does not exist.

**Tech Stack:** Bash 5 (`set -euo pipefail`), `gh` CLI, GitHub Actions reusable workflows, `shellcheck`, `actionlint`, fixture-driven bash tests in `tests/run-script-tests.sh`.

**Spec:** `docs/superpowers/specs/2026-09-17-implement-claim-design.md`

## Global Constraints

- Every bash script starts with `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`. Quote every variable expansion. Use `[[ ... ]]`, never `[ ... ]`. No `eval`.
- Exit codes are API: `0` success, `2` required env missing, `3` claim held by someone else (acquire only — a distinct code so the workflow can branch on it).
- **The release must never fail the job.** It runs in `always()`, often during a cancellation grace period. Every failure inside it is swallowed and reported, never propagated.
- Claim state is read from the issue, never from Actions-only context — a local session with no Actions access must reach the same verdict from the same data.
- Never decide staleness from elapsed time. The run's state is the only signal; unresolvable means stale.
- No inline bash longer than 5 lines in a YAML step.
- Do not pin GitHub Actions to floating tags. Do not loosen workflow `permissions:`.
- Commit messages follow Conventional Commits. **Commit AND PUSH after every task** — every task's final step ends `git commit ... && git push -u origin HEAD`. Work committed but never pushed dies with the runner.
- **If the branch already has commits when you start, you are resuming.** Read `git log --oneline origin/main..HEAD`, match subjects against the task list, skip what is already committed, continue from the first that is not.

**The claim format** (memorize; it recurs in every task):

```text
🔒 Implement claim by run <run-id>
<run-url>
claimed <ISO-8601 UTC>
```

Label: `ai-implementing`. Both are required for a claim to count as held — a label with no parseable comment is a **stale** claim, not a held one, and is takeable. That direction matters: failing open is what keeps a crashed run from wedging the issue.

**Testability contract:** every script reads its inputs from env overrides when set — `ISSUE_LABELS`, `ISSUE_COMMENTS`, `RUN_STATE` — and only shells out to `gh` when they are not. This mirrors `classify-turns.sh`'s `ISSUE_LABELS` / `ISSUE_BODY` pattern and is what lets Layer-1 cover every branch with no network.

---

### Task 1: Claim library

Parsing and liveness, with no side effects. Everything the other tasks reason about lives here.

**Files:**
- Create: `scripts/lib/issue-claim.sh`
- Test: `tests/run-script-tests.sh` (new section, after the `classify-turns` section)

**Interfaces:**
- Produces: functions sourced via `source scripts/lib/issue-claim.sh`.
  - `parse_latest_claim <comments>` → prints `run_id<TAB>run_url<TAB>claimed_at` for the **newest** claim comment, or nothing.
  - `claim_state <run_id>` → prints `live` | `stale`. Resolves via `gh run view "$run_id" --json status,conclusion` unless `RUN_STATE` is set. `queued` and `in_progress` are live; everything else, **including an unresolvable run**, is `stale`.
- Consumed by Tasks 2 and 3.

- [ ] **Step 1: Write the failing tests**

```bash
section "issue-claim — claim parsing and run liveness"

CLAIM_LIB="$ROOT/scripts/lib/issue-claim.sh"

comments_one=$'🔒 Implement claim by run 111\nhttps://gh/run/111\nclaimed 2026-09-17T09:12:03Z'
out="$(source "$CLAIM_LIB"; parse_latest_claim "$comments_one")"
assert_contains "$out" '111' "parses a single claim's run id"
assert_contains "$out" 'https://gh/run/111' "parses the run url"

# Newest claim wins — a redispatched issue accumulates them
comments_two=$'🔒 Implement claim by run 111\nhttps://gh/run/111\nclaimed 2026-09-17T09:12:03Z\n---\n🔒 Implement claim by run 222\nhttps://gh/run/222\nclaimed 2026-09-17T10:00:00Z'
out="$(source "$CLAIM_LIB"; parse_latest_claim "$comments_two")"
assert_contains "$out" '222' "newest claim wins"

# No claim at all
out="$(source "$CLAIM_LIB"; parse_latest_claim 'just an ordinary comment')"
assert_equals "$out" "" "no claim comment → empty"

# Liveness
for s in queued in_progress; do
  out="$(source "$CLAIM_LIB"; RUN_STATE="$s" claim_state 111)"
  assert_equals "$out" "live" "$s → live"
done
for s in completed cancelled failure skipped; do
  out="$(source "$CLAIM_LIB"; RUN_STATE="$s" claim_state 111)"
  assert_equals "$out" "stale" "$s → stale"
done

# The decision that keeps a crashed run from wedging the issue
out="$(source "$CLAIM_LIB"; RUN_STATE="" claim_state 999999)"
assert_equals "$out" "stale" "unresolvable run → stale, never live"
```

Run `bash tests/run-script-tests.sh`; confirm they fail because the library does not exist.

- [ ] **Step 2: Write the library**

Create `scripts/lib/issue-claim.sh`. Notes that matter:

- `parse_latest_claim` must take the **last** match, not the first — a redispatched issue accumulates claim comments and the oldest one is never the answer.
- `claim_state` must return `stale` on **any** non-zero `gh` exit, and must not let `set -e` kill the caller: guard the call (`state="$(gh run view … 2>/dev/null || true)"`).
- Header comment records *why* unresolvable maps to stale: an unresolvable run cannot be in progress, and failing open is what satisfies "a crashed run does not block the issue indefinitely" without a time heuristic.

- [ ] **Step 3: Verify**

```bash
bash tests/run-script-tests.sh
shellcheck -x -e SC1091 scripts/lib/issue-claim.sh
```

- [ ] **Step 4: Commit and push**

```bash
git add scripts/lib/issue-claim.sh tests/run-script-tests.sh
git commit -m "feat(claim): add claim parsing and run-liveness library (#366)" && git push -u origin HEAD
```

---

### Task 2: Acquire and release scripts

**Files:**
- Create: `scripts/claim-issue.sh`
- Create: `scripts/release-issue-claim.sh`
- Test: `tests/run-script-tests.sh`

**Interfaces:**
- Consumes: `scripts/lib/issue-claim.sh` from Task 1.
- `claim-issue.sh` env in: `ISSUE_NUMBER`, `REPO`, `RUN_ID`, `RUN_URL`, `GH_TOKEN`; test overrides `ISSUE_LABELS`, `ISSUE_COMMENTS`, `RUN_STATE`, `DRY_RUN`. Writes `claimed=true|false` and `holder=<run-url>` to `$GITHUB_OUTPUT`. Exit `0` claimed, `3` held by another live run, `2` bad env.
- `release-issue-claim.sh` env in: `ISSUE_NUMBER`, `REPO`, `RUN_ID`, `GH_TOKEN`. Always exits `0`.
- Task 3 wires both.

- [ ] **Step 1: Write the failing tests**

Cover, at minimum:

- no label and no claim comment → claims, exit `0`
- label present, comment names a **live** run → exit `3`, `holder` names that run's URL
- label present, comment names a **stale** run → takes over, exit `0`
- label present, **no parseable comment** → stale, takes over, exit `0` (a crashed run must not wedge the issue)
- claim comment naming **this same run id** → idempotent, exit `0`, no duplicate comment
- missing `ISSUE_NUMBER` / `RUN_ID` → exit `2`
- release with no claim held → exit `0`, no error
- release when the newest claim belongs to a **different** run → leaves it alone, exits `0` (a cancelled run must not release its successor's claim)

That last one is easy to miss and is the one that turns `cancel-in-progress` into a live-issue bug: the cancelled run's `always()` release can land *after* the replacement run has claimed.

- [ ] **Step 2: Write `claim-issue.sh`**

Order is: read labels + comments → if a live claim by another run exists, exit `3` → post the claim comment → add the label → **re-read comments and re-check**.

The re-check is not optional. Acquire is not atomic, and the whole point is a second party that Actions' `concurrency` cannot see. If the re-check finds a claim comment that is not this run's and is **older** than the one just posted, this run lost: remove the label only if this run added it, post a stand-down note, and exit `3`. Same shape as `/enrich`'s Step 2.5 race re-check.

Post the comment **before** adding the label, matching the enrich lock's ordering, so a label can never exist without an age/reference to judge it by.

- [ ] **Step 3: Write `release-issue-claim.sh`**

Read the newest claim; if its run id is not `RUN_ID`, do nothing and exit `0`. Otherwise remove the label and post a release note. Wrap every `gh` call so a failure prints and is swallowed — this script runs in `always()` and must never fail the job.

- [ ] **Step 4: Verify**

```bash
bash tests/run-script-tests.sh
shellcheck -x -e SC1091 scripts/claim-issue.sh scripts/release-issue-claim.sh
```

- [ ] **Step 5: Commit and push**

```bash
git add scripts/claim-issue.sh scripts/release-issue-claim.sh tests/run-script-tests.sh
git commit -m "feat(claim): acquire and release the implement claim (#366)" && git push -u origin HEAD
```

---

### Task 3: Wire into the pipeline, and create the label

**Files:**
- Modify: `.github/workflows/agent-implement.yml`
- Modify: `scripts/ensure-issue-labels.sh`
- Test: `tests/run-script-tests.sh` (the `ensure-issue-labels` section)

**Interfaces:** consumes Task 2's scripts.

- [ ] **Step 1: Label definition**

Add `ai-implementing` to `ensure-issue-labels.sh` under the existing `coordination` category, alongside `enrichment-ongoing`, and extend that category's header comment. Add the assertion to the existing `ensure-issue-labels` test section — the `turns:*` labels went missing exactly this way (#273), so an untested label is a label that will not exist.

- [ ] **Step 2: Claim step**

In `agent-implement.yml`, add a `Claim issue` step in the implement job, **after** `Check attempt cap` and **before** `Classify agent`. Guard it with `if: ${{ !inputs.stub-claude }}`, matching its neighbours. Env: `ISSUE_NUMBER`, `REPO`, `RUN_ID: ${{ github.run_id }}`, `RUN_URL` built from `github.server_url`/`github.repository`/`github.run_id`, and `GH_TOKEN: ${{ steps.app_token.outputs.token || github.token }}` — the same token expression the neighbouring steps already use.

On exit `3`, the job must stop **without** looking like a crash: surface the holder in `$GITHUB_STEP_SUMMARY` and end the job cleanly. Do not let a refusal masquerade as an agent failure — that is how a collision would get misdiagnosed and redispatched, which is the loop this issue exists to break.

- [ ] **Step 3: Release step**

Add a `Release issue claim` step at the end of the implement job with `if: ${{ always() && !inputs.stub-claude }}`. Same env minus `RUN_URL`.

Place it so it runs after the agent and after the report step. Confirm by reading the file back that no step between claim and release can exit the job early without reaching it.

- [ ] **Step 4: Verify**

```bash
actionlint
bash tests/run-script-tests.sh
just lint
```

All clean. Read back the workflow and confirm the release step carries `always()` and that workflow-scope `permissions:` is unchanged.

- [ ] **Step 5: Commit and push**

```bash
git add .github/workflows/agent-implement.yml scripts/ensure-issue-labels.sh tests/run-script-tests.sh
git commit -m "feat(claim): claim the issue before implementing, release on run end (#366)" && git push -u origin HEAD
```

---

### Task 4: Local-side refusal and docs

**Files:**
- Modify: `commands/gh/implement.md`
- Modify: `commands/work.md`
- Modify: `docs/DECISIONS.md` (new ADR)
- Modify: `CHANGELOG.md` (`[Unreleased]` → `### Added`)

**Interfaces:** none — command docs and prose.

- [ ] **Step 1: `/gh:implement` precondition**

Add a precondition alongside the existing ones: read the issue's labels and comments, and if a live claim is held, **stop** and name the holding run and its URL. Give the mechanical check, in the style of the existing precondition 5:

```bash
gh issue view <N> --repo <owner/repo> --json labels --jq '[.labels[].name]' | grep -q ai-implementing && echo "CLAIM?" || echo "free"
```

...then resolve the newest claim comment's run and report `live` / `stale`. State plainly that a **stale** claim is not a blocker — take over — and that cancelling a live run is the operator's call, offering `gh run cancel <id>` as text, never running it.

- [ ] **Step 2: `/work` check**

Same check before local implementation begins, with the same refuse-and-name behaviour.

- [ ] **Step 3: ADR**

Record in `docs/DECISIONS.md`: the claim format, why it is label **plus** comment (the run reference is what staleness is judged from), why unresolvable maps to stale (fail open — a wedged issue is worse than a rare double-implementation), and the **residual gap** — a local session that started before the dispatch still is not protected, and a PR in `ai:review-blocked` is unclaimed once its run ends. Follow the numbering and shape of the existing ADRs.

- [ ] **Step 4: Follow-up issues**

File two, and reference them from the ADR:

- symmetric claims, so a local session claims in the same format (needs a claim identity that is not a run id, and a staleness rule for it)
- whether a PR in `ai:review-blocked` should keep the issue owned until it merges or closes

- [ ] **Step 5: Verify**

```bash
just lint
bash tests/run-script-tests.sh
```

- [ ] **Step 6: Commit and push**

```bash
git add commands/gh/implement.md commands/work.md docs/DECISIONS.md CHANGELOG.md
git commit -m "docs(claim): refuse local implementation while a claim is live (#366)" && git push -u origin HEAD
```

---

## Out of scope

- **Symmetric claims.** Local sessions read the claim; they do not take one. Making it symmetric needs a claim identity that is not a run id, and staleness for it would fall back to the time heuristic this design rejects. Filed as a follow-up in Task 4.
- **Ownership through `ai:review-blocked`.** A blocked PR's issue is unclaimed once its run ends — the state flowhub#93's collision happened in. Filed as a follow-up in Task 4.
- **Cancelling a live run automatically.** The refusal names `gh run cancel <id>`; nothing runs it. Cancelling mid-implementation discards uncommitted work.
