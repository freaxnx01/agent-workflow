# Pre-preview mode — design

**Issue:** [#77](https://github.com/freaxnx01/agent-pipeline/issues/77)
**Date:** 2026-06-04
**Status:** Approved — ready for implementation planning

## Summary

Add a **third review flow** to the pipeline, sitting between the two existing
ones (`docs/CONSUMER-SETUP.md`):

1. **Minimum stub** — labeled issue → draft PR. A human reviews and merges. No
   agent review.
2. **Auto-review + auto-merge** (`ai-auto-review`, ADR-002) — draft PR → agent
   review → on approve + safety envelope, `gh pr ready` + `gh pr merge --auto
   --squash`. The pipeline merges.
3. **Pre-preview** (this design) — draft PR → agent reviews its own PR → on
   approve, `gh pr ready` **only**. A human merges. No envelope, no auto-merge.

Pre-preview is "auto-review minus the merge": the human reviews a PR the agent
has already vetted, without surrendering the merge decision.

### Decisions (locked during brainstorming)

- **Term:** "pre-preview". Label `ai-pre-preview`, input `pre-preview`.
  ("self-review" was rejected — too close to "auto-review".)
- **Self-fix is out of scope** for this iteration (agent fixing its own
  findings). It becomes a follow-up issue. Iteration 1 is: review → on approve,
  promote to ready; non-approve leaves the PR draft + `ai:review-blocked`.
- **Opt-in surface:** a new per-issue label `ai-pre-preview` + a new per-repo
  boolean input `pre-preview`, parallel to `ai-auto-review` / `auto-review`. No
  tri-state input — the existing boolean surface is kept.
- **Job structure:** a **separate `pre_preview` job** parallel to `auto_review`
  (approach B). Reuses the scripts; leaves the ADR-002-audited auto-merge job's
  internal steps byte-for-byte unchanged.
- **Conflict rule:** if an issue carries both `ai-auto-review` and
  `ai-pre-preview`, **pre-preview wins** (fail-safe toward human control — do
  not auto-merge under ambiguous intent).

## Goals / Non-goals

### Goals

- A consumer can opt a repo (input) and an issue (label) into pre-preview.
- After the pipeline opens a draft PR, the agent reviews it with the existing
  `review-pr.sh`. On `approve`, the draft is promoted to ready so a human can
  merge. On `request_changes` / `block` / no-PR, the draft stays draft and the
  issue/PR is marked `ai:review-blocked`.
- The pipeline never merges in this mode.
- This repo (`freaxnx01/agent-pipeline`) can dogfood pre-preview.

### Non-goals (deferred)

- Self-fix loop (agent commits fixes for its own findings, re-reviews, bounded
  iterations). → follow-up issue.
- Composite-action refactor to de-duplicate job scaffolding (approach C). →
  revisit if a fourth flow appears.
- Any change to the auto-merge safety envelope (ADR-002).

## Architecture

The pipeline lives in the reusable workflow `.github/workflows/claude-implement.yml`,
which has two jobs today: `implement` (runs the agent, opens the draft PR,
computes the auto-review gate) and `auto_review` (reviews + promotes + merges
inside ADR-002's envelope). Pre-preview adds:

- one gate script,
- one new output + one new input on `implement`,
- one new clause on the `auto_review` job gate (precedence),
- one new `pre_preview` job,
- a tiny `MODE` tweak to `post-auto-review-block.sh`,
- a new label in `ensure-issue-labels.sh`,
- tests, docs, and an ADR.

### 1. Opt-in surface

**Input** (reusable-workflow `workflow_call` inputs):

```yaml
pre-preview:
  description: |
    Per-repo opt-in for pre-preview mode: after the pipeline opens a draft
    PR, the agent reviews it and, on approve, promotes it to ready for a
    human to merge. Never auto-merges. Combined with the per-issue
    `ai-pre-preview` label (both required). If an issue also carries
    `ai-auto-review`, pre-preview wins (no auto-merge).
  type: boolean
  default: false
stub-pre-preview-enabled:
  description: |
    Test-only seam for act. When true, forces the implement job's
    `pre-preview-enabled` output to true instead of running
    check-preview-gate.sh.
  type: boolean
  default: false
```

**Label:** `ai-pre-preview` — added to `scripts/ensure-issue-labels.sh` in the
"gates" group alongside `ai-auto-review`:

- color: `1D76DB` (blue, distinct from `ai-auto-review`'s green `0E8A16`)
- description: `Run agent pre-review after PR opens; promote to ready for human merge (no auto-merge)`

**Gate script:** `scripts/check-preview-gate.sh` — a near-clone of
`check-auto-review-gate.sh`. Contract:

- **Required env:** `ISSUE_NUMBER`, `REPO` (or `GITHUB_REPOSITORY`),
  `INPUT_PRE_PREVIEW` (`true`/`false`).
- **Optional env:** `ISSUE_LABELS` (newline/space-separated; skips the `gh issue
  view` call — used by Layer-1 tests), `GH_TOKEN`.
- **Logic:** `enabled=true` iff `INPUT_PRE_PREVIEW == true` **AND** the issue
  carries the `ai-pre-preview` label. Either alone is `false`.
- **Output:** `enabled=true|false` and `reason=<text>` to `$GITHUB_OUTPUT`;
  one-line `enabled=<bool> (<reason>)` to stdout.
- **Exit codes:** `0` success; `2` missing env or `INPUT_PRE_PREVIEW` not in
  `{true,false}`.

This mirrors `check-auto-review-gate.sh` exactly so its tests and shape are
familiar. (A shared helper is not worth the indirection for two ~80-line gates;
revisit if a third gate appears.)

### 2. Precedence — minimal, auto_review internals untouched

In the `implement` job:

- Run `check-preview-gate.sh` in a step `preview_gate` (and a stub step
  `preview_gate_stub` gated on `inputs.stub-pre-preview-enabled`, mirroring the
  existing `auto_review_gate` / `auto_review_gate_stub`).
- Add an `implement` job output and a reusable-workflow output
  `pre-preview-enabled`, sourced like its auto-review sibling:
  `${{ steps.preview_gate.outputs.enabled || steps.preview_gate_stub.outputs.enabled }}`.

Precedence is expressed as **one added clause** on the existing `auto_review`
job's top-level `if:`:

```yaml
# auto_review job — existing gate, with ONE new clause appended:
&& needs.implement.outputs.pre-preview-enabled != 'true'
```

When both gates are enabled, `pre-preview-enabled == 'true'` fails the
`auto_review` gate (no merge) and passes the `pre_preview` gate (promote to
ready). The `auto_review` job's **internal** steps — self-mod guard, envelope,
promote+merge, block — are not modified.

### 3. New `pre_preview` job

Parallel to `auto_review`. Top-level gate mirrors `auto_review`'s test-mode
guards plus the new enabled flag:

```yaml
pre_preview:
  needs: implement
  if: >
    (!inputs.stub-claude || inputs.stub-review-verdict != '')
    && (!inputs.dry-run || inputs.stub-review-verdict != '')
    && needs.implement.outputs.outcome == 'success'
    && needs.implement.outputs.pre-preview-enabled == 'true'
  runs-on: ${{ fromJSON(inputs.runner-labels) }}
  timeout-minutes: 10
  permissions:
    contents: write
    pull-requests: write
    issues: write
```

**Steps** (reusing existing scripts and the same test seams as `auto_review`):

1. **Checkout consumer repo** — `actions/checkout`.
2. **Checkout `agent-pipeline` scripts** (`!inputs.local-scripts`) / **Mirror
   local scripts** (`inputs.local-scripts`) into `.claude-pipeline` — copied
   verbatim from `auto_review`.
3. **Wire gh mock + stub PR JSON** (`inputs.stub-review-verdict != ''`) — copied
   from `auto_review` (sets `PATH`, `GH_MOCK_LOG`, `PIPELINE_PRS_JSON`).
4. **Find pipeline-opened PR** — `find-pipeline-pr.sh` (unchanged), emits
   `found`, `pr-number`, `head-sha`.
5. **Install Claude Code CLI** — gated on `found == 'true' && stub-review-verdict
   == ''` (no self-mod-guard clause here).
6. **Run agent review** — `review-pr.sh` (unchanged), gated as in `auto_review`
   minus the self-mod clause. Emits `verdict`.
7. **Stub agent review** (`stub-review-verdict != ''`) — synthesizes `verdict`,
   copied from `auto_review`.
8. **Resolve review verdict** — single seam `verdict.value = real || stub`,
   copied from `auto_review`.
9. **Promote draft to ready (pre-preview)** — gated on `found == 'true' &&
   verdict.value == 'approve'`:

   ```bash
   gh pr ready "$PR_NUMBER" --repo "$REPO"
   gh pr comment "$PR_NUMBER" --repo "$REPO" \
     --body "Pre-reviewed ✓ — promoted to ready. Merge is yours (no auto-merge in pre-preview mode)."
   ```

   No envelope check. No `gh pr merge`.
10. **Mark blocked** — gated on `found != 'true' || verdict.value != 'approve'`:
    `post-auto-review-block.sh` with `MODE=pre-preview`. Leaves the PR draft,
    applies `ai:review-blocked`, comments the reason.
11. **Verify gh mock log** (`stub-review-verdict != '' && always()`) — assert
    helper (see Testing) that confirms `gh pr merge` was **not** called and (on
    the approve path) `gh pr ready` **was** called.

**No self-mod guard.** Promote-to-ready performs no merge, so promoting a PR on
`freaxnx01/agent-pipeline` itself is safe — a human still merges. Omitting the
guard is what lets this repo dogfood pre-preview. This is called out explicitly
in the ADR and as a code comment in the job.

### 4. `post-auto-review-block.sh` — `MODE` tweak

Add an optional `MODE` env (default `auto-review`). It only affects comment
wording; the `ai:review-blocked` label and the reason-selection logic are
unchanged:

- `MODE=auto-review` (default): `Auto-merge held: <reason>. PR stays draft for
  human review.` / `Auto-review held: <reason>.` (current behavior, byte-for-byte).
- `MODE=pre-preview`: `Pre-review held: <reason>. PR stays draft for human
  review.` / `Pre-review held: <reason>.`

The reason strings themselves (self-mod guard / PR-not-found / verdict / envelope)
are unchanged; in pre-preview only the PR-not-found and verdict reasons are
reachable (no envelope, no self-mod guard).

## Data flow

```text
issue labeled (ai-implement + ai-pre-preview)
        │
        ▼
implement job ── opens draft PR ── check-preview-gate.sh ──► pre-preview-enabled=true
        │                                                    (auto-review-enabled forced
        │                                                     irrelevant: auto_review gate
        │                                                     fails on pre-preview-enabled)
        ▼
pre_preview job
   find-pipeline-pr.sh ──► found? ──no──► post-auto-review-block.sh (MODE=pre-preview)
        │ yes
   review-pr.sh ──► verdict
        ├─ approve ──────────► gh pr ready  (+ comment)        ──► human merges
        └─ request_changes/block ──► post-auto-review-block.sh (MODE=pre-preview)
                                      → draft + ai:review-blocked
```

## Error handling

- `review-pr.sh` already normalizes agent crashes / non-JSON / invalid verdicts
  to `verdict=block` (exit 0), so the pre_preview job always has a verdict and
  routes block → `post-auto-review-block.sh`. No new failure modes.
- PR not found (`find-pipeline-pr.sh` `found=false`) → block path with the
  existing "could not find a pipeline-opened draft PR" reason.
- `gh pr ready` failure (e.g. PR already ready) — non-fatal; the human can still
  merge. The job should not hard-fail on a redundant `gh pr ready`. (Implementation
  note: tolerate the "already ready" case, consistent with the idempotent spirit
  of `review-pr.sh`.)

## Testing

Mirrors the existing two-layer strategy.

**Layer-1 (script units)** — new `check-preview-gate.sh` cases (fixtures of the
same shape as the auto-review-gate tests):

- input `false` → `enabled=false`.
- input `true`, label present → `enabled=true`.
- input `true`, label absent → `enabled=false`.
- missing `ISSUE_NUMBER` → exit 2.
- `MODE=pre-preview` wording assertion for `post-auto-review-block.sh` (block
  reason → "Pre-review held").

**Layer-2 (act, `claude-implement.test.yml`)** — new scenarios using the
existing stub seams (`stub-pre-preview-enabled`, `stub-review-verdict`,
gh-mock log):

- **preview-approve** → assert `gh pr ready` called AND `gh pr merge` **not**
  called.
- **preview-block** (and **preview-request_changes**) → assert PR stays draft,
  `ai:review-blocked` applied, no `gh pr ready`, no `gh pr merge`.
- **precedence** → both `stub-auto-review-enabled` and `stub-pre-preview-enabled`
  true ⇒ `auto_review` job skipped (or no merge), `pre_preview` runs ⇒ no
  `gh pr merge`.

**Assertion helper:** extend `verify-gh-mock-merge.sh` (or add a sibling
`verify-gh-mock.sh`) to also report whether `gh pr ready` appears in
`$GH_MOCK_LOG`, so the approve scenario can assert promotion happened and merge
did not.

## Documentation

- `docs/CONSUMER-SETUP.md` — add **flow #3 (Pre-preview)** to the flows list and
  an onboarding note: enable `pre-preview: true` and label issues
  `ai-pre-preview`; a human merges.
- `docs/DECISIONS.md` — **ADR-004 — Pre-preview mode (agent self-review → human
  merge)**. Context (the gap between draft-only and auto-merge; #77), Decision
  (separate job, no envelope, no self-mod guard, pre-preview-wins precedence,
  self-fix deferred), Consequences (this repo can dogfood; two near-duplicate
  jobs accepted for isolation; revisit with approach C if a fourth flow lands).
- Update issue #77's acceptance criteria as items land.

## Files touched (estimate)

| File | Change |
|---|---|
| `scripts/check-preview-gate.sh` | **new** — preview gate |
| `scripts/ensure-issue-labels.sh` | add `ai-pre-preview` label |
| `scripts/post-auto-review-block.sh` | optional `MODE` wording |
| `scripts/verify-gh-mock-merge.sh` (or sibling) | also report `gh pr ready` |
| `.github/workflows/claude-implement.yml` | `pre-preview` + `stub-pre-preview-enabled` inputs; `pre-preview-enabled` output; preview gate steps; one clause on `auto_review` gate; new `pre_preview` job |
| `.github/workflows/claude-implement.test.yml` | preview-approve / preview-block / precedence scenarios |
| `tests/fixtures/*`, `tests/mocks/*` | gate + verdict fixtures as needed |
| `docs/CONSUMER-SETUP.md` | flow #3 |
| `docs/DECISIONS.md` | ADR-004 |

## Open items for implementation

- Confirm the exact `auto_review` job `if:` once on the latest `main` (append
  the precedence clause without disturbing existing clauses).
- Decide whether the promote step's confirmation comment is worth a second PR
  comment given `review-pr.sh` already posts the verdict — keep it (cheap,
  clarifies "ready, merge is yours") unless it reads as noise.
