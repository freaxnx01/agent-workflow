# find-pipeline-pr.sh search-index retry — design

**Tracking:** [freaxnx01/agent-workflow#249](https://github.com/freaxnx01/agent-workflow/issues/249)

## Problem

`find-pipeline-pr.sh` locates the pipeline-opened draft PR for an issue via a
GitHub **search** API call:

```bash
gh pr list --repo "$REPO" --state open \
  --search "closes #${ISSUE_NUMBER} in:body" \
  --json number,isDraft,headRefOid,headRefName,author --limit 10
```

`gh pr list --search` hits GitHub's full-text search index, which is
eventually consistent — a just-created PR is not guaranteed to be searchable
immediately. On a fast implementation run, the caller can query before the
index catches up, get zero results, and report `found=false` even though the
PR genuinely exists and matches every criterion (open, draft, correct `Closes
#N`, allowlisted author).

### Observed instance

`freaxnx01/game-geography-quiz#13`, 2026-08-11. The `implement` job succeeded
in 39s/18 turns — the fastest of four issues dispatched in the same batch —
and opened `game-geography-quiz#14` with a correct `Closes #13` body from the
allowlisted author (`app/github-actions`). The `pre_preview` job's `find_pr`
step ran immediately after and reported `found=false`. `post-auto-review-block.sh`
then stamped the issue `ai:review-blocked` and left PR #14 permanently
unreviewed — not "review found problems," but "review never ran." The other
three issues in the same batch (1m/2m/11m implement durations) all found
their PR correctly. The correlation with the *shortest* run is the tell: less
wall-clock time between `gh pr create` and the `find_pr` search query means
less time for the index to catch up.

`find-pipeline-pr.sh` has two call sites, both affected:

1. `verify-or-recover-pr.sh`, inside the `implement` job, immediately after
   the agent's turn ends (tightest timing — least elapsed time since `gh pr
   create`). Its own comment (`# PR already existed — the search index
   lagged`) already documents hitting this same race from a different angle:
   a false "not found" here makes it *attempt to recreate* the PR, which then
   fails with "already exists."
2. The `auto_review`/`pre_preview` jobs, in a separate job that runs after
   `implement` completes.

### Why it matters

The failure mode is silent from a human's perspective: `ai:review-blocked`
reads identically whether an agent reviewed the PR and found real problems,
or the review never ran at all. It reproduces more often the *faster* (i.e.
simpler, lower-risk) the implementation — exactly the PRs that should need
the least manual intervention end up needing the most.

## Approach

Retry the search inside `find-pipeline-pr.sh` itself when it comes back
empty, before reporting `found=false`. This is the single shared root cause
for both call sites — fixing it here fixes both without touching workflow
YAML or plumbing new job outputs across the `implement` → `auto_review`/
`pre_preview` job boundary.

This is a distinct primitive from `scripts/lib/gh-retry.sh`'s `with_backoff`:
`with_backoff` retries a command that **fails** (non-zero exit matching a
transient-error signature). Our failure mode is a command that **succeeds**
with a **stale-empty** result — a different trigger condition, so a new small
loop is added rather than reusing `with_backoff` directly.

Two other directions were considered and rejected for this issue (see
`agent-workflow#249` for the fuller writeup):

- Switching to `gh pr list --head <branch>` (avoids the search index, but
  the branch name isn't known to the caller today — would need a new job
  output plumbed from `implement` to the downstream jobs).
- Having `implement` return the PR number directly (removes the race
  structurally, but doesn't eliminate the need for `find-pipeline-pr.sh`,
  since `verify-or-recover-pr.sh`'s recovery path still needs to
  search-or-create).

Both are valid future improvements if retry-with-backoff turns out to be
insufficient in practice, but are materially larger changes for the same
near-term payoff.

## Behavior

- Loop up to `FIND_PR_RETRY_MAX` (default `3`) attempts.
- Each attempt: call `gh pr list --search ...` (or use `PIPELINE_PRS_JSON` if
  set — see below), then apply the existing author-normalization + draft +
  allowlist filter (unchanged logic). If a match is found, return
  immediately — no wasted retries once found.
- If empty, sleep `FIND_PR_RETRY_BASE_SLEEP * attempt` seconds (default base
  `2`, so 2s/4s/6s across 3 attempts ≈ 12s total added latency in the worst
  case, comfortably inside the ~15s budget) via `FIND_PR_RETRY_SLEEP_CMD`
  (defaults to `sleep`, overridable for tests), then retry.
- After the last attempt with no match, emit `found=false` exactly as today.
  Behavior for a genuinely nonexistent PR is unchanged, just delayed by the
  retry budget.
- A hard `gh` failure (auth, network) is still swallowed into `|| printf
  '[]'` exactly as today (unchanged behavior) — but now that empty result
  also gets retried, which is a strict improvement: a transient network blip
  during the search self-heals instead of immediately reporting not-found.

### Test seam

`PIPELINE_PRS_JSON` (existing seam, used by all current tests) bypasses `gh
pr list` entirely and is checked **once, with no retry** — this keeps every
existing single-shot test (author allowlist, draft filter, highest-number
tiebreak, etc.) passing unmodified, since those tests only ever construct one
static result set.

A new seam, `PIPELINE_PRS_JSON_SEQUENCE_CMD`, is added for retry-specific
tests: an optional path to a fake `gh`-shaped shim script. Follows the exact
counter-file idiom already used in `tests/run-script-tests.sh` for
`with_backoff`'s tests (`make_flaky`, `tests/run-script-tests.sh:2119`): the
shim returns empty JSON (`[]`) on its first N invocations (tracked via a
counter file), then the real PR JSON on the next. When set, `find-pipeline-pr.sh`
calls the shim instead of the real `gh pr list`.

## Testing

1. New: empty on attempt 1, PR found on attempt 2 → `found=true`, exactly 2
   invocations of the shim.
2. New: empty for all `FIND_PR_RETRY_MAX` attempts → `found=false`, exactly
   `FIND_PR_RETRY_MAX` invocations (proves it doesn't retry forever).
3. New: `PIPELINE_PRS_JSON` (existing seam) still short-circuits with zero
   sleep calls / zero shim invocations — regression guard that the new loop
   doesn't slow down the deterministic-JSON test path used by every other
   existing test.
4. Existing 8 tests at `tests/run-script-tests.sh:1462+` (author allowlist,
   draft filter, highest-number tiebreak, missing-issue-number error, etc.)
   pass unmodified — no behavior change to the filtering logic itself.

## Docs

Short addendum to `docs/DECISIONS.md`, near the existing ADR-002/pre-preview
self-modification section, documenting: the race, the `#13` evidence, the
fix, and a cross-reference to `agent-workflow#249`. Not a new ADR — this is
an implementation-detail reliability fix to an existing mechanism, not a new
architectural decision.

## Scope boundaries

- No change to the allowlist/author-normalization logic or the `isDraft`
  filter — this is scoped to the discovery mechanism's reliability, not its
  selection criteria.
- No workflow YAML changes — the fix is entirely inside
  `scripts/find-pipeline-pr.sh` (and its test file).
- No change to `verify-or-recover-pr.sh` itself — it calls
  `find-pipeline-pr.sh` and inherits the fix for free.
