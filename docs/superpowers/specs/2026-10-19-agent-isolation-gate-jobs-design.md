# Agent isolation: agents produce, a fresh gate job decides — Design

> Issue: #535. Related: #517, #521 (ADR-019 names this gap), #551 (unattended lane on a `self-fix: true` consumer).
> Operator decision 2026-10-19: **separate gate job**.

## Problem

Every job in `.github/workflows/agent-implement.yml` that runs an agent with a bash tool
also runs the steps that judge what the agent did, as the same user and in the same
workspace:

| job | agent step (bash tool) | decisions made afterwards in the same job |
|---|---|---|
| `implement` (`:403-1175`) | `Run Claude Code` (`:708`, `--allowedTools ...Bash`) / `Run OpenCode` (`:791`) | classify failure, pause alarm, model alert, retry dispatch, job outcome, labels, plan coverage, checks diagnostic, run report, red/green (`:977-1175`) |
| `ai_review_ai_merge` (`:1177-1603`) | `Self-fix loop` (`:1445`, fix agent via `agent-cmd-claude-fix.sh:32` / `agent-cmd-opencode-fix.sh`) | final verdict, wait for checks, merge envelope, promote + auto-merge, blocked labelling (`:1476-1592`) |
| `ai_review_human_merge` (`:1605-1893`) | `Self-fix loop` (`:1812`) | final verdict, promote to ready, blocked labelling (`:1842-1886`) |

An agent with a bash tool can, before those steps run:

1. rewrite `.claude-pipeline/scripts/*` (classifier, pause reasons, envelope, coverage);
2. append forged events to `$RUNNER_TEMP/opencode-output.json` or rewrite the verdict
   file the next step reads;
3. write `$GITHUB_ENV` (e.g. `BASH_ENV=/tmp/x`) or `$GITHUB_PATH`, which turns
   **every later `run:` step of the same job** into attacker code — a fresh re-checkout
   inside the same job does not help (this is why the operator rejected it);
4. write its own step's `$GITHUB_OUTPUT`.

A prompt-injected issue, or review findings that quote one, is enough.

## Decision

**Every job in which an agent runs only produces evidence. Every decision derived from
that evidence runs in a new job, on its own runner, with its own fresh checkout of the
consumer repo (`persist-credentials: false`) and of `.claude-pipeline` at
`inputs.pipeline-ref`, and that job never runs an agent.**

Rejected (operator, 2026-10-19):

- *Re-checkout within the same job* — `$GITHUB_ENV`/`$GITHUB_PATH` and detached
  processes survive it.
- *Agent as a separate unprivileged user* — complex, brittle on self-hosted runners.

### What is trusted

GitHub captures a step's outputs when that step ends; a later step cannot change them,
and a job output is an expression over step outputs. So **outputs of steps that finished
before the first agent step are trusted** (`classify_agent`, `triage`, `triage_turns`,
`issue.has-plan`, `pause_gate`, `attempt_cap`, the merge-gate flags, the review job's
`self_mod_guard`, `find_pr`, and the first `verdict` when no self-fix ran). Everything
produced at or after the first agent step is **evidence: untrusted, forgeable**.

The first review agent (`review-pr.sh` via `agent-cmd-claude.sh:28`) gets no
`--allowedTools`, but the consumer's checked-in `.claude/settings.json` can grant it
tools, so the review job is treated as an agent job too.

## Job layout

| | before | after |
|---|---|---|
| 1 | `implement`: agent + all post-run decisions | `implement`: pre-agent classification, agent, salvage/recover PR, **export evidence** (job outputs) |
| 2 | — | **`implement_gate`** (new): import evidence, classify, pause alarm, model alert, retry, outcome, labels, find PR, plan coverage, checks diagnostic, run report, red on failure |
| 3 | `ai_review_ai_merge`: review, self-fix, verdict, checks wait, envelope, promote + auto-merge, blocked | `ai_review_ai_merge`: self-mod guard, find PR, review, self-fix → outputs only |
| 4 | — | **`ai_review_ai_merge_gate`** (new): re-find PR, gated verdict, head binding, plan coverage on final head, checks wait, envelope, promote + `--auto --match-head-commit`, blocked |
| 5 | `ai_review_human_merge`: review, self-fix, verdict, promote, blocked | `ai_review_human_merge`: find PR, review, self-fix → outputs only |
| 6 | — | **`ai_review_human_merge_gate`** (new): re-find PR, gated verdict, head binding, promote to ready, blocked |

Review jobs now `needs: [implement, implement_gate]` and key off
`needs.implement_gate.outputs.{outcome,plan-coverage}`. The reusable workflow's
`outcome`, `cost-usd`, `num-turns`, `failure-class`, `retry-decision` outputs re-point to
`jobs.implement_gate.outputs.*`; the merge/ready/outcome-label test outputs to the two
review gate jobs. Output **names** do not change.

### Evidence transport — job outputs, not artifacts

The implement job's new `Export result for the gate` step (`scripts/export-result-output.sh`)
emits:

- `result-json` — the canonical result object (`ADR-001 §2`), compact, with `.result`
  elided to its first and last 4000 characters;
- `execution-usage` — a compact array holding only the usage-bearing events
  (`assistant` → `message.usage`, `step_finish` → `part.tokens`), which is all
  `post-run-report.sh:240-300` reads from `EXECUTION_FILE`;
- `is-error` — local hint for `verify-or-recover-pr.sh`'s salvage decision only.

`implement_gate` writes them back to files with `scripts/import-result-output.sh`, which
validates the shape (object, `type == "result"`, boolean `is_error`). Anything else —
including an empty output because GitHub dropped one it believed held a secret — becomes
a synthetic `error_invalid_evidence` result, classified `bug`, reported `ai:failed`.
Outputs reach `run:` steps only through `env:`, never as `${{ }}` inside a script
(script injection).

Rejected: artifacts. The existing diagnostics uploads fail on a full artifact quota
(#404), `act` needs an artifact server, and a new download action would need pinning;
job outputs (1 MB per job) carry the few KB needed.

### When `implement_gate` runs

`if: !cancelled() && needs.implement.outputs.agent-eligible == 'true'`. `agent-eligible`
is computed from trusted pre-agent outputs: a new marker step `agent_reached` placed
directly before the agent steps, plus `pause_gate.paused != 'true'` and
`attempt_cap.proceed != 'false'`. So a paused or parked dispatch produces no report (as
today), and a run where the agent was due but no result came back now gets an
`ai:failed` report instead of silence.

### Salvage stays in the implement job

`verify-or-recover-pr.sh` commits and pushes the agent's uncommitted tree
(`verify-or-recover-pr.sh:146-158`), so it needs that workspace. It produces a PR — the
same thing the agent can do with its own token — so it is producer work. Its outputs are
evidence; the gate re-derives the PR with `find-pipeline-pr.sh`. `salvaged` is passed on
for display only.

### Gated verdict and head binding (review gates)

- **Verdict.** If the review job's `self-fix-outcome` is `skipped`, the gate uses
  `first-verdict` (captured before any bash agent ran); otherwise the post-self-fix
  `verdict`, which is forgeable.
- **Binding** (`scripts/check-verdict-binding.sh`): the gate's own `find-pipeline-pr.sh`
  must return the PR number the review job found (trusted, pre-agent) and a head SHA
  equal to the head the review job reports. Mismatch → blocked with a reason.
- **Merge pin.** `gh pr merge --auto --squash --match-head-commit "$HEAD_SHA"` with the
  gate's own head SHA.
- **Plan coverage** is recomputed in `ai_review_ai_merge_gate` from the PR diff on the
  final head (`plan-coverage-step.sh`), not taken from any upstream output. The envelope
  runs only on `complete` (dry-run exempt, as today at `:1194`).
- The **self-mod guard** stays where it is (pre-agent, trusted); the gate reads its
  output instead of duplicating the inline script.
- `post-auto-review-block.sh` gains two reasons, after the existing verdict check:
  `BINDING_REASON` and `PLAN_COVERAGE` ≠ `complete`.

### Runner choice

New input `gate-runner-labels` (default `''` → `runner-labels`). Gate jobs need no
toolchain beyond `gh`/`jq`, so a consumer on persistent self-hosted runners can put them
on `ubuntu-latest` or an ephemeral pool. Additive, no consumer change.

### Permissions

| job | contents | pull-requests | issues | actions |
|---|---|---|---|---|
| `implement_gate` | read | read | write | write (retry dispatch) |
| `ai_review_ai_merge_gate` | write | write | write | — |
| `ai_review_human_merge_gate` | read | write | write | — |

All within the existing union (`contents/pull-requests/issues/actions: write`) that
`tests/run-caller-permissions-tests.sh` checks against every documented and generated
consumer stub, so **no consumer `agent.yml` changes**. Jobs inside a reusable workflow
run under the caller's ceiling; outputs pass between jobs through `needs.<job>.outputs`.

## Residual risks (accepted, stated)

- **R1 — Forged result stream.** The result is still agent-reachable. Bounds: a forged
  402 pauses only when the budget already reads `warn`/`exhausted`, a forged 403 only on
  `exhausted` (ADR-019, #521 C3). A forged `rate_limit`/`transient`/`task_failure` costs at
  most the retry caps in `retry-dispatch.sh` and `max-attempts`. A forged success on a PR
  that misses plan tasks is caught by the gate's own plan coverage (`partial` →
  `ai:partial`, no review). Unbounded: a forged success on an issue with no
  Implementation Plan, or forged cost/turn numbers in the report — display only.
- **R2 — Forged verdict.** Only when a bash agent ran in the review job (self-fix, or
  tools granted by the consumer's `.claude/settings.json`). Bounds: required checks
  (branch protection, server side), the merge envelope re-run in the gate (author
  allowlist, `.github/` and secret-glob paths, blocklist from a fresh default-branch
  checkout, checks green, repo settings), plan coverage on the final head, head binding
  and `--match-head-commit`. Unbounded: the *quality* judgement — a forged `approve` on a
  PR that passes every mechanical gate merges. Follow-up option: a fresh, tool-less
  re-review job after self-fix (one extra review per self-fixed PR).
- **R3 — Forged display fields.** `reason`, `self-fix-iterations-used`,
  `self-fix-outcome`, `salvaged`, cost and token figures. They only change wording;
  forging iterations to `0` skips the checks wait and fails the envelope closed.
- **R4 — The agent's own token.** The implement and self-fix agents hold a write-scoped
  token (App installation token or `GITHUB_TOKEN`, `:720`, `:808`, `:1458`). They can push,
  call `gh pr ready` / `gh pr merge --auto` themselves, or exfiltrate the token (an App
  token lives 1 h). That path bypasses the envelope entirely; only server-side branch
  protection bounds it. Not addressed here (token scoping is a separate issue).
- **R5 — Persistent self-hosted runners.** "Fresh runner" holds on hosted and ephemeral
  runners only. On a persistent runner the agent can leave changes in `$HOME`
  (`~/.bashrc`, `~/.local/bin`, `~/.opencode/bin`, `gh` config) that a later gate job on
  the same machine picks up. Mitigation: `gate-runner-labels`.
- **R6 — Push after auto-merge is enabled.** `--match-head-commit` is checked when auto-merge
  is enabled. A write-access push afterwards keeps auto-merge on; required checks re-run
  on the new head server-side, nothing else re-runs.

## Out of scope

Token scoping for agents (R4), a re-review job after self-fix (R2), the review-job
timeout/report gap (#372), diagnostics upload failures (#404).

## Testing

- Layer 1: `export-result-output.sh`, `import-result-output.sh`, `check-verdict-binding.sh`,
  the two new `post-auto-review-block.sh` reasons; a structural test
  (`tests/run-agent-isolation-tests.sh`) asserting that no step after the first agent step
  of any job runs a decision script, that every job running a decision script checks out
  `inputs.pipeline-ref` itself and has no agent step, and that no `run:` block interpolates
  `${{ needs.* }}`. Existing structural assertions in `tests/run-script-tests.sh`
  (`#430`, `#439`, `#474`, `#490`) move to the new jobs.
- Layer 2: `agent-implement.test.yml` keeps every scenario; its stubs now travel through
  export → job output → import, and its merge/ready assertions read the gate jobs'
  outputs (re-pointed, names unchanged).
