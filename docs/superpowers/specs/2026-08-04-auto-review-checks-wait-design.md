# Bounded wait for required checks after auto_review self-fix approve — design

**Issue:** [#238](https://github.com/freaxnx01/agent-workflow/issues/238)
**Relates to:** ADR-002 (auto-review/auto-merge safety envelope), the ADR-002 addendum "Self-fix + pending-checks interaction (2026-08-04)", the ADR-004 addendum "Self-fix generalized to auto_review + agent routing (2026-08-04)"
**Date:** 2026-08-04

## Context

Issue #193 (self-fix generalization, Phases 1–3, merged) gave `auto_review` the
same self-fix pass `pre_preview` already had. `scripts/check-merge-envelope.sh`'s
gate 5 treats a *pending* required-checks status the same as *failing* —
intentional, documented behavior per ADR-002 §2.5: never vacuously pass the
supply-chain gate on an unknown/pending state.

That behavior collides with self-fix's timing: `auto_review`'s self-fix step
pushes a fresh commit and, seconds later, the very next step ("Check merge
envelope") queries that commit's required-checks status. CI on a
just-pushed commit has almost never finished in that window. Net effect: the
new self-fix→approve→auto-merge path commonly still lands in
`ai:review-blocked` today, even when the fix itself was good — not because
anything is broken, but because the check hasn't had time to run yet.

The **plain** (non-self-fix) `auto_review` approve path doesn't have this
problem in practice: by the time `auto_review` runs as a separate job after
`implement` finishes, and after `auto_review`'s own setup/review overhead,
several minutes have typically elapsed — enough for CI on `implement`'s
commits to complete. Self-fix compresses that window to near-zero. This
design targets the compressed window specifically, not gate 5's semantics
in general.

## Non-goals

- **No change to gate 5's semantics.** Pending still means "not ready" —
  this design buys the pending state more time to resolve, it doesn't
  change what counts as passing.
- **No change to the plain (non-self-fix) `auto_review` approve path.**
  Scoped narrowly to post-self-fix, per the issue and confirmed during
  brainstorming — no evidence the plain path races the same way, and
  widening the fix without that evidence isn't justified.
- **No change to `pre_preview`.** It never auto-merges (ADR-004), so gate 5
  never runs there.
- **No weakening of any other envelope gate** (1, 6, 7) — this design
  touches nothing about author allowlist, path envelope, or
  branch-protection compatibility.

## Design

### 1. A new step, not a new script

Insert one new workflow step in the `auto_review` job, between the existing
"Resolve final verdict (post self-fix)" step and "Check merge envelope":

```yaml
      - name: Wait for required checks (post self-fix approve)
        # KNOWN GAP fix (#238): self-fix pushes a fresh commit seconds
        # before this point, so required checks on it have almost never
        # finished yet -- gate 5 (check-merge-envelope.sh) treats pending
        # the same as failing (ADR-002 §2.5), so the approve path commonly
        # dead-ends at ai:review-blocked even when the fix was good. This
        # step gives checks a bounded window to finish. `gh pr checks
        # --watch` polls until all required checks reach a terminal state
        # (or the step's own timeout-minutes below fires first) --
        # continue-on-error + `|| true` mean this step can NEVER fail the
        # job: on timeout or any gh error, execution falls straight through
        # to the unmodified "Check merge envelope" step below, which does
        # its own live query and fails gate 5 exactly as it does today.
        # Worst case is unchanged from before this fix; best case the
        # checks finish in time and the PR actually merges.
        if: |
          steps.self_mod_guard.outputs.blocked != 'true'
          && steps.find_pr.outputs.found == 'true'
          && steps.final.outputs.verdict == 'approve'
          && steps.final.outputs.iterations-used != '0'
          && inputs.stub-review-verdict == ''
        continue-on-error: true
        timeout-minutes: 3
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}
        run: gh pr checks "$PR_NUMBER" --repo "$REPO" --required --watch --interval 15 || true
```

**Why `iterations-used != '0'` gates this, not just `verdict == 'approve'`:**
`steps.final.outputs.iterations-used` is `0` whenever the self-fix loop never
ran (verdict was `approve`/`block` on the first pass, or `self-fix: true`
wasn't set) — exactly the plain-path case this design doesn't touch. Only a
non-zero count means self-fix actually pushed a commit.

**Why `inputs.stub-review-verdict == ''` gates this:** `check-merge-envelope.sh`
already has a full test seam for gate 5 (`REQUIRED_CHECKS_STATUS`,
consumed directly under `stub-review-verdict != ''`) — Layer-2 tests never
need a real check-status query. Without this guard, the new step would call
real `gh pr checks --watch` against a nonexistent stub PR number and either
hang (bounded by its own 3-minute timeout, wasting CI time every act run) or
error immediately — either way, pure noise in tests that already stub the
thing this step exists to wait for.

**Why `gh pr checks --watch` and not a custom poll script:** it's GitHub
CLI's own native polling primitive for exactly this — refreshes until all
checks reach a terminal state, no bespoke sleep-loop-timeout logic to
maintain or unit-test. `--required` scopes it to the same check set gate 5
itself evaluates, so a wait success genuinely predicts a gate 5 pass. One
line of `run:`, well under the 5-line inline-bash limit.

### 2. Job timeout: 10 → 15 minutes

`auto_review`'s `timeout-minutes` (currently 10) becomes 15. Self-fix's own
fix→re-review iterations already consume a meaningful share of the original
10-minute budget (noted as a pre-existing, unaddressed observation in
Phase 2's final review). Adding a bounded 3-minute wait on top, without
raising the job timeout, risks the *whole job* being killed by its own
timeout mid-wait — which skips the "Mark issue blocked" step entirely (no
comment, no label), a strictly worse outcome than today's
`ai:review-blocked`. Raising the ceiling keeps the new step's own
`continue-on-error`/timeout as the only thing that can time out, preserving
the documented fallback behavior.

### 3. Everything downstream is unmodified

"Check merge envelope", "Promote / merge on final approve", and "Mark issue
blocked" keep reading `steps.final.outputs.verdict` and `steps.envelope.*`
exactly as Phase 2 left them. This design adds a step; it does not change
any existing step's logic, `if:` condition, or env.

## Data flow summary

```
Self-fix loop (auto-review) → commit pushed
       │
       ▼
Resolve final verdict: verdict=approve, iterations-used=N (N>0)
       │
       ▼ (NEW, only when N>0 && verdict==approve && not stub mode)
Wait for required checks:
  gh pr checks --required --watch --interval 15   (bounded 3 min, continue-on-error)
       │
       ▼ (always falls through, pass or timeout)
Check merge envelope (UNCHANGED)  →  live gh pr checks query
       │
       ├─ pass ─→ Promote / merge (UNCHANGED)
       └─ fail ─→ Mark issue blocked (UNCHANGED, same wording as today)
```

## Testing strategy

- **Layer-2 `act` scenario (required — today's coverage would miss a
  regression here):** the existing `verify-auto-review-self-fix-approve`
  scenario stubs `REQUIRED_CHECKS_STATUS: pass` unconditionally via
  `stub-review-verdict != ''`, which — per this design's own guard — means
  the new wait step is *skipped* in that scenario, not exercised. Add a
  new assertion confirming the new step is correctly absent/skipped under
  stub mode (e.g. assert the job completes within a tight time bound,
  ruling out an accidental real `gh pr checks --watch` call hanging for 3
  minutes in CI). A true positive-path test of the wait step itself
  (real pending→pass transition) is not feasible under `act`/stub mode
  without a real GitHub PR and real check runs — out of scope for
  Layer-2; note this limitation explicitly in the PR.
- **actionlint** on the modified workflow file.
- **Manual verification note for the PR body:** since the wait step's
  actual polling behavior can't be exercised by stubs, the PR should say so
  plainly rather than implying full coverage.

## Open questions

None — scope, mechanism, timeout, and fallback behavior were all confirmed
during brainstorming. The one acknowledged testing gap (no Layer-2 coverage
of the real polling behavior) is inherent to `act`'s stub-based test model,
not a gap in this design's own logic.
