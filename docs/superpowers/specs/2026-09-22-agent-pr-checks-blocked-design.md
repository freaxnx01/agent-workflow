# Make a stalled agent PR say so

**Issue:** [#364](https://github.com/freaxnx01/agent-workflow/issues/364)
**Date:** 2026-09-22
**Status:** Approved

## Problem

A PR opened by the pipeline is authored by `github-actions`, because
`agent-implement.yml:535` falls back to `github.token` when no App token was
minted:

```yaml
GH_TOKEN: ${{ steps.app_token.outputs.token || github.token }}
```

The App-token step at `:418-422` is gated on `env.PIPELINE_APP_ID != ''`, and
`PIPELINE_APP_ID` is not among this repo's secrets. So the fallback is always
taken here.

Observed on [#363](https://github.com/freaxnx01/agent-workflow/pull/363)
(author: `app/github-actions`). Its three `pull_request` runs were created at
`07:27:15` and stalled at `action_required` — awaiting manual approval — before
resolving to `failure`. A human push to the same branch at `07:42:1x` ran all of
them green with no approval needed.

Because `main`'s `required_status_checks` pins both `gate-selftest` and `test`,
such a PR reports an empty `statusCheckRollup`, satisfies neither check, and
sits `BLOCKED` indefinitely.

### The part that is not a code problem

Option 1 in the issue — configure the GitHub App — is an **operator credential
task**, not something an implementing agent can perform. It requires creating an
App, generating a private key, and adding `PIPELINE_APP_ID` and
`PIPELINE_APP_PRIVATE_KEY` as repository secrets. The workflow code for it
already exists and is correct; it is inert only because the secret is unset.

This spec therefore does **not** claim to close AC1 and AC2 by code. It ships
the part that is implementable — making the stall loud instead of silent — plus
the runbook for the part a human must do.

### The part that is a code problem

A stalled PR currently looks identical to a finished one. The run reports
success, the PR exists, and nothing anywhere says the gate cannot run. That is
the actual defect this change fixes, and it is AC3 verbatim.

## Decisions

| # | Decision | Rejected alternative |
|---|---|---|
| D1 | Ship detection + reporting + an operator runbook | Detection only (leaves AC3's operator with no way to act); switching to a PAT (long-lived personal credential, and the App path already exists) |
| D2 | Warn at job start **and** check empirically after the PR opens | Empirical check only — the operator would learn at the end of a paid run what was knowable at second zero |
| D3 | Diagnostic only; never fail the job | Failing the run conflates "the agent did its job" with "the repo is misconfigured", and would make every run on this repo red until the App is configured |
| D4 | Report through the existing `post-run-report.sh` comment | A second script posting a second comment doubles the noise on every blocked run |
| D5 | Poll for check *presence*, not completion | `gh pr checks --watch` waits for checks to finish; the symptom is that none ever start, so it would simply time out |

## Design

### Component 1 — preflight warning

A step at the top of the implement job, before any agent cost is incurred:

- When `PIPELINE_APP_ID` is empty, emit a `::warning::` annotation and append a
  line to `$GITHUB_STEP_SUMMARY` stating that the PR will be authored by
  `github-actions` and its checks will require manual approval, pointing at
  `docs/PIPELINE-APP-SETUP.md`.
- When it is set, do nothing.

Kept to four lines of inline YAML bash — under the stack overlay's five-line
ceiling, and extracting it would cost a file for a single conditional `printf`.

### Component 2 — `scripts/check-pr-checks-runnable.sh` (new)

Runs after the PR is known to exist, alongside `verify-or-recover-pr.sh`.

```
Required env: PR_NUMBER
Optional env: REPO (default $GITHUB_REPOSITORY), APP_TOKEN_CONFIGURED
              (the workflow passes `${{ env.PIPELINE_APP_ID != '' }}`),
              POLL_INTERVAL (default 10), POLL_TIMEOUT (default 120)

Outputs (stdout, and GITHUB_OUTPUT when set):
  checks-runnable=true|false
  checks-blocked-reason=<slug>

Exit codes:
  0  determination made (runnable or not)
  2  required env missing
```

The script's own exit code is not the safety guarantee — `exit 2` would fail a
normal step. The workflow step that calls it carries **`continue-on-error: true`**,
so neither a missing env var nor a `gh` outage can fail the implement job. That
is what D3 rests on; the exit code merely tells the run report which branch to
render.

Loop: query `gh pr view "$PR_NUMBER" --json statusCheckRollup`; a non-empty
rollup returns `true` immediately, without waiting out the window. On timeout,
return `false` with one of two reasons, because they call for different operator
actions:

- `no-app-token` — `APP_TOKEN_CONFIGURED` was `false`, so this was predicted.
  Action: configure the App.
- `rollup-empty` — the App *was* configured and checks still did not start.
  Action: unknown; investigate.

### Component 2b — `verify-or-recover-pr.sh` must report the PR number

The probe needs a PR number, and `verify-or-recover-pr.sh` does not emit one
today — its documented outputs are `found`, `pr-present`, `recovered`,
`salvaged`. It gains `pr-number`, empty when there is no PR.

Without it the probe step receives an empty `PR_NUMBER`, exits 2, and — because
the step carries `continue-on-error` — fails silently: the exact class of bug
this issue is about.

### Component 3 — reporting through `post-run-report.sh`

Two new optional env vars, `CHECKS_RUNNABLE` and `CHECKS_BLOCKED_REASON`. When
`CHECKS_RUNNABLE` is `false`:

- Render a warning block into the existing comment, naming the reason, the PR,
  and the remedy.
- Add `ai:checks-blocked` to `labels_csv()` (`:290`), which today returns
  `STATUS_LABEL` plus an optional `CTX_LABEL`.

**The outcome logic at `:227-252` is deliberately untouched.** `STATUS_LABEL`
stays `ai:done`. This is what makes the change diagnostic rather than a failure,
per D3.

### Component 4 — `ai:checks-blocked` label

Added to `ensure-issue-labels.sh`. Meaning: *the PR is real and reviewable, but
its required checks cannot run.* Three blocked states now exist and are
deliberately distinct:

| Label | Meaning |
|---|---|
| `ai:review-blocked` | The reviewer ran and refused to promote the PR |
| `ai:runner-blocked` | The reviewer never started; runner toolchain unmet (#302) |
| `ai:checks-blocked` | The PR is fine; its required checks cannot run |

### Component 5 — `docs/PIPELINE-APP-SETUP.md` (new)

The operator runbook: create the App, which permissions it needs (contents,
pull-requests, issues — write), install it on the repo, generate the private
key, add `PIPELINE_APP_ID` and `PIPELINE_APP_PRIVATE_KEY` as secrets, and how to
verify it worked (the next pipeline PR's author is the App, and its rollup is
non-empty). Linked from the preflight warning, the run-report block, and
`docs/CONSUMER-SETUP.md`.

## Testing

**Layer 0** — `actionlint` on the workflow, `shellcheck -x` on the new script.

**Layer 1** — `tests/run-check-pr-checks-runnable-tests.sh` (new), driving the
script against the `gh` mock's `GH_MOCK_STDOUT_MAP` seam with `POLL_TIMEOUT=1`
so the suite stays sub-second:

| Case | Asserts |
|---|---|
| non-empty rollup | `checks-runnable=true`, returns before the timeout |
| empty rollup, `APP_TOKEN_CONFIGURED=false` | `false` + `no-app-token` |
| empty rollup, `APP_TOKEN_CONFIGURED=true` | `false` + `rollup-empty` |
| `PR_NUMBER` missing | exit 2, names `PR_NUMBER` |
| `GITHUB_OUTPUT` set | both keys written |

Plus cases through `post-run-report.sh`'s existing `RENDER_ONLY=1` path:
the warning block renders and names the reason; `LABELS:` contains
`ai:checks-blocked`; and the outcome **stays** `ai:done` — the regression that
would turn a diagnostic into a failure.

## Acceptance criteria

- [ ] When `PIPELINE_APP_ID` is unset, the implement job emits a warning at job
      start naming the consequence and the runbook
- [ ] After the PR opens, the pipeline determines whether its checks can run,
      within a bounded window, without ever failing the job
- [ ] When checks cannot run, the run report on the issue says so explicitly,
      names which of the two reasons applies, and states the remedy (#364 AC3)
- [ ] The issue is labelled `ai:checks-blocked`, distinct from
      `ai:review-blocked` and `ai:runner-blocked`
- [ ] A blocked run's outcome label is still `ai:done` — detection never
      downgrades a successful implementation
- [ ] `docs/PIPELINE-APP-SETUP.md` exists and is linked from the warning, the
      run report, and `docs/CONSUMER-SETUP.md`
- [ ] `verify-or-recover-pr.sh` reports `pr-number`, empty rather than stale
      when no PR exists
- [ ] `actionlint` and `shellcheck -x` pass; Layer-1 suites green in <5s

## Out of scope

- **Configuring the GitHub App itself** (#364 option 1) — an operator task; this
  change ships the runbook for it, not the credentials. AC1 and AC2 of the issue
  are satisfied only once that is done.
- **Relaxing `required_status_checks`** (#364 option 2) — explicitly rejected in
  the issue; the gate caught a real bug in #354.
- The cancelled review job on the same run — filed separately by the issue.
