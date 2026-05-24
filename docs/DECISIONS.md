# Architecture Decisions

This file records architecturally-significant decisions for `claude-pipeline`.
Each entry is dated and immutable — supersession is captured by a follow-on
entry, never by editing prior history.

Format: lightweight ADR (Context / Decision / Consequences) per Michael
Nygard's pattern, kept terse.

---

## ADR-001 — Agent abstraction layer (2026-05-23)

**Status:** Accepted
**Tracking:** [#5](https://github.com/freaxnx01/claude-pipeline/issues/5) under epic [#2](https://github.com/freaxnx01/claude-pipeline/issues/2)

### Context

The reusable workflow `claude-implement.yml` is hard-coded to invoke
`anthropics/claude-code-base-action` and to address Claude model IDs
(`claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5`). Epic
[#2](https://github.com/freaxnx01/claude-pipeline/issues/2) adds OpenCode
+ OpenRouter (Mistral first) as a second executor without forcing a
redesign on every downstream script (`classify-failure.sh`,
`post-run-report.sh`, `retry-dispatch.sh`).

The pre-existing classify/report/retry pipeline already operates on a
single JSON file: `${RUNNER_TEMP}/claude-result.json`. That file is the
natural isolation seam between "agent runs the task" and "pipeline acts
on the result." If both agents emit the same JSON shape, every downstream
script keeps working.

### Decision

Introduce an **agent abstraction layer** with five elements:

#### 1. Selector surface — input + label

- New `agent` workflow input (string, default `claude`, validated to one
  of `claude | opencode`).
- Per-issue override via `agent:claude` / `agent:opencode` label, parallel
  to the existing `model:*` override convention.
- **Three-tier precedence: label > workflow input > script default.** This
  *extends* the two-tier pattern in `classify-task.sh` (label > default),
  which has no workflow-input tier today.
- A new script `scripts/classify-agent.sh` performs the decision and
  emits `agent=...` and `reason=...` to `$GITHUB_OUTPUT`.

#### 2. Result-shape contract

Every agent step normalizes its output to the existing
`${RUNNER_TEMP}/claude-result.json` shape consumed by
`classify-failure.sh` and `post-run-report.sh`.

**Required keys (read by downstream scripts):**

| Key                                  | Type    | Notes                                                                                                |
|--------------------------------------|---------|------------------------------------------------------------------------------------------------------|
| `subtype`                            | string  | `"success"` or an error tag (`"error_during_execution"`, `"error_max_turns"`, ...). Read by `classify-failure.sh`. |
| `is_error`                           | bool    | `false` on success. Read by `classify-failure.sh` and `post-run-report.sh`.                          |
| `duration_ms`                        | number  | wall time of the agent run. Read by `post-run-report.sh`.                                            |
| `num_turns`                          | number  | conversation turns. Read by `post-run-report.sh`.                                                    |
| `total_cost_usd`                     | number  | best-effort; `0` if the agent doesn't surface cost (document per-agent). Read by `post-run-report.sh`. |
| `result`                             | string  | **Load-bearing on failure**: `classify-failure.sh` pattern-matches this to bucket the failure (`rate_limit` / `api_auth` / `transient` / `task_failure` / `bug`). An empty / missing `result` on `is_error: true` falls through to `bug`. On success, surfaced in the run-report comment. New-agent adapters MUST populate this on errors so the regex hits its OpenRouter-flavored cases (added in #10) or its existing Claude-flavored ones. |
| `usage.input_tokens`                 | number  | totals across the run. Read by `post-run-report.sh`.                                                 |
| `usage.output_tokens`                | number  | totals across the run.                                                                               |
| `usage.cache_creation_input_tokens`  | number  | `0` for agents without prompt caching.                                                               |
| `usage.cache_read_input_tokens`      | number  | `0` for agents without prompt caching.                                                               |

**Informational keys (written by current adapters but not read by any pipeline script):**

| Key          | Type   | Notes |
|--------------|--------|-------|
| `type`       | string | Only meaningful in event-stream output filtered by the standard `Adapt execution_file -> result.json` step (it filters on `select(.type == "result")` to pick the final SDK message from a stream). Adapters that write `claude-result.json` directly (like the workflow's `Stub Claude run` step) may omit it. |
| `session_id` | string | Agent's own session id (or a synthesized placeholder). Useful for traceability when reading the workflow log; not consumed by any script. New adapters MAY emit it. |

New agents add an adapter step (e.g. `scripts/adapt-opencode-result.sh`)
that translates their native output into this shape. The pipeline does
not branch on agent identity past the adapter.

#### 3. Mutex execution

Exactly one agent step runs per job. Steps are gated via
`if: steps.classify_agent.outputs.agent == '<name>'`. There is no parallel
agent execution and no fallback chain.

#### 4. Auth model

Each agent declares its own secret at the `workflow_call.secrets`
boundary:

- `CLAUDE_CODE_OAUTH_TOKEN` — currently `required: true`; becomes
  `required: false` after the OpenCode path lands so consumers can pick
  one.
- `OPENROUTER_API_KEY` — added as `required: false`.

Consumers that want both agents available declare both secrets;
consumers that want only one declare only one. The workflow does **not**
validate that the correct secret is set for the chosen agent — the agent
step will fail loudly, and `classify-failure.sh` already buckets that as
`api_auth`.

#### 5. Why this does not create lock-in

The contract is small: one selector script, one result-shape JSON, one
secret per agent. Adding a third agent later (Aider, Goose, a future
first-party Anthropic non-CLI runner) is:

- Add `agent: <name>` to the input enum and `agent:<name>` to the label
  vocabulary.
- Add one runner step and one adapter script.
- Add fixtures for the new agent's success / rate-limit / task-failure
  shapes.

No downstream script changes. The Phase-4 retry/classify infrastructure
(`classify-failure.sh`, `retry-dispatch.sh`) already pattern-matches on
the normalized JSON, not on agent identity.

### Consequences

- The Claude path becomes one branch of an `if:` ladder rather than the
  unconditional path. Defaults stay the same so existing consumers see
  no behavior change.
- `classify-failure.sh`'s error-string regex must learn OpenRouter-
  flavored rate-limit / auth / 5xx messages alongside the Claude-flavored
  ones. Tracked in
  [#10](https://github.com/freaxnx01/claude-pipeline/issues/10).
- Agents that do not surface per-run cost (current OpenCode behavior)
  report `total_cost_usd: 0`. Documented in `CONSUMER-SETUP.md` so the
  run-report comment is not mistaken for "free."
- The result-shape table above is now load-bearing. Any change to it is a
  breaking change to consumers' assumptions about the run-report. Such
  changes require a new ADR and a major-version bump.

---

## ADR-002 — Auto-review and auto-merge safety envelope (2026-05-23)

**Status:** Accepted — supersedes constraint #4 ("Draft PRs only") in
`docs/DESIGN.md`.
**Tracking:** [#12](https://github.com/freaxnx01/claude-pipeline/issues/12) under epic [#3](https://github.com/freaxnx01/claude-pipeline/issues/3)

### Context

`docs/DESIGN.md` "Critical constraints — non-negotiable" item 4
(April 2026) made it a non-negotiable rule that
the pipeline only opens **draft** PRs and never promotes them. That rule
was the right default when there was no review step between
"agent finished" and "PR exists" — every diff needed human eyes before
merge.

Epic [#3](https://github.com/freaxnx01/claude-pipeline/issues/3) introduces
an agent-driven review step that runs on the just-opened draft PR
([#14](https://github.com/freaxnx01/claude-pipeline/issues/14)). With a
review verdict in hand, there is a defensible path to promoting the draft
to ready and enabling auto-merge — but only if a tight safety envelope is
enforced. This ADR defines that envelope.

### Decision

#### 1. What the policy reversal allows

When all hard-gates in §2 are satisfied, the pipeline may:

- `gh pr ready <PR>` — promote the draft to ready-for-review.
- `gh pr merge --auto --squash <PR>` — enable GitHub's native auto-merge,
  which fires once all required status checks pass.

Without all gates satisfied, the PR stays draft and a human is expected
to take over. There is no partial-promotion (e.g. "ready but not
auto-merge") because the only reason to promote in this flow is to enable
auto-merge.

#### 2. Hard-gates — ALL must be true

Auto-merge is enabled iff every one of these holds at the moment the
auto-review job runs:

1. **Pipeline-authored PR.** `pr.user.login` must be in the configured
   allowlist. Default: the single-element list `["github-actions[bot]"]`
   — the identity GitHub assigns to PRs opened via `GITHUB_TOKEN` (which
   is how the workflow opens PRs in consumer repos today). Consumers
   using a GitHub App or PAT have a different `pr.user.login` and MUST
   either (a) pass the additional identity via a new
   `pipeline-author-allowlist` workflow input (added in
   [#15](https://github.com/freaxnx01/claude-pipeline/issues/15)), or
   (b) leave `auto-review: false` until the allowlist is wired. Refuse
   to promote a human-authored or third-party-bot PR even if the gating
   labels are present.

   *Why this is independent of gates 2 + 3:* defense in depth against
   label injection. A human could open a PR by hand and then apply the
   `ai-auto-review` label to its originating issue; gate 1 prevents the
   auto-merge step from acting on any PR the pipeline itself did not
   open.

   *Interim behavior before #15 lands the allowlist input:* the gate
   check MUST hard-fail (not silently default to "allowed") with a
   clear error message naming this ADR and #15. Silent default to the
   pinned `github-actions[bot]` value is acceptable; silent default to
   "any author allowed" is not.
2. **Per-issue opt-in.** The originating issue carries the
   `ai-auto-review` label.
3. **Per-repo opt-in.** The reusable workflow was called with
   `auto-review: true`.
4. **Review verdict = approve.** `scripts/review-pr.sh`
   ([#14](https://github.com/freaxnx01/claude-pipeline/issues/14)) emits
   `verdict=approve`. `request_changes` and `block` both leave the PR
   draft.

   The review prompt
   ([#14](https://github.com/freaxnx01/claude-pipeline/issues/14)) MUST
   flag the following as automatic `block` regardless of other findings:
   - **Any net deletion of test files** — i.e. test-file lines removed
     strictly exceeds test-file lines added (N=0; any net deletion
     blocks). Same rule for whole-file deletions in `tests/**`.
   - Test files renamed-to-skip or marked `@Ignore` / `xit(` /
     `@pytest.mark.skip` / `[Fact(Skip = …)]` / `t.Skip(…)` and
     equivalents.
   - Changes to test fixtures that align expected outputs with newly-
     broken implementation behavior (heuristic; the reviewer flags
     suspect, human resolves).

   These are explicitly called out because gates 1, 2, 3, 5, 6, 7 do
   not catch them and gate 5 ("all required checks green") can be
   satisfied by deleting the failing checks.
5. **All required status checks green.** Auto-merge will defer until
   they are; if any required check is failing at the time of decision,
   refuse to promote (don't bet on a flaky check turning green after the
   fact).
6. **Diff is inside the safety envelope.** The PR must not touch:
   - Anything under `.github/` (workflows, actions, CODEOWNERS, branch
     protection config). Touching CI from within an auto-merged change
     is a self-modifying-pipeline footgun.
   - Encrypted-secret naming conventions: `*.sops.yaml`, `*.enc.*`,
     `*.age`, `*.gpg`, `*.pem`, `*.key`, `*.kbx`, `*.p12`, `*.pfx`,
     `secrets.*`. **Non-exhaustive.** Repos with their own conventions
     extend coverage via the `.claude-auto-merge-blocklist` file below.
   - Paths listed in a repo-local `.claude-auto-merge-blocklist` file
     (one glob per line, comments with `#`). Optional; absent file =
     empty blocklist. Consumers customize per-repo without needing a
     workflow change.

   **Supply-chain risk** (PRs that add malicious dependencies via
   `package.json`, `requirements.txt`, `pyproject.toml`, `Dockerfile`,
   `Cargo.toml`, `*.csproj`, `pubspec.yaml`, `go.mod`, etc.) is NOT
   handled by an in-envelope blocklist on manifest files — blocking
   every dependency change would make auto-merge useless. Instead it is
   delegated to gate 5: consumers MUST wire a dependency-vulnerability-
   scanning check (e.g. `npm audit`, `pip-audit`, `dotnet list package
   --vulnerable`, Dependabot's review action) as a **required status
   check** on the target branch. Without one, supply-chain attacks pass.
   `docs/CONSUMER-SETUP.md` MUST document this requirement before
   `auto-review: true` is recommended.
7. **Branch protection compatibility.** The target branch must have
   squash-merge enabled. CODEOWNERS, if defined, must be satisfied by
   the diff (we don't bypass review requirements — `gh pr merge --auto`
   honors them, but we check first so we can post a clear reason in the
   PR comment when we don't promote).

If any gate fails, the auto-review job:
- Posts a single PR review comment naming the failed gate(s).
- Leaves the PR draft.
- Applies the `ai:review-blocked` label to the originating issue (label
  itself is out of scope for this ADR; created when needed).
- Exits the job successfully — gate failure is a *decision*, not an
  error.

#### 3. Merge strategy

**Squash only.** Rationale:

- The pipeline produces multiple commits per branch (implementation,
  test, fixup-from-review). The commit-by-commit history is uninteresting
  to consumers; the PR-title-as-commit-subject squash gives a clean
  `main` history.
- Squash-merge plays well with Conventional Commits — the PR title is
  already conventional (the pipeline enforces this when creating the PR),
  so the squash commit is too.
- Rebase-merge fans out N agent commits into `main`; merge-commit
  pollutes `main` with merge bubbles. Both lose the "one decision per
  merge" story that auto-merge needs to make sense in `git log`.

#### 4. Failure modes & rollback

- **Required check fails after promotion.** GitHub's auto-merge cancels
  itself and notifies via PR. The pipeline does not retry. A human
  takes over.
- **Squash-merge succeeds, then a follow-up CI run (e.g. nightly) finds
  a regression.** Revert is a normal `git revert` — no pipeline-specific
  rollback. Worth a future ADR if reverts ever become common, but
  out-of-scope today.
- **Review verdict was wrong (approved a bad change).** Same as above —
  revert in `main`, and post-mortem the review prompt
  ([#14](https://github.com/freaxnx01/claude-pipeline/issues/14)) before
  re-enabling `auto-review: true` for the issue category that produced
  it.
- **Gate-envelope bug** (e.g. a `.github/` file slipped through).
  Disable feature via either kill switch:
  - **Per-repo:** flip `auto-review: false` at the call site. No code
    change to `claude-pipeline` needed.
  - **Per-issue:** remove the `ai-auto-review` label from the
    originating issue. Symmetric with the two-tier opt-in in §2 (gates
    2 + 3).

  Then add a fixture covering the missed path, then re-enable.

  **Propagation latency.** Both kill switches only take effect on the
  NEXT workflow run. In-flight runs that have already passed gate 6 and
  called `gh pr merge --auto` will still land their PRs once required
  checks pass — there is no mechanism to revoke an armed auto-merge
  short of `gh pr merge --disable-auto`. If the gate-envelope bug is
  active enough to require immediate stopping, do that manually on
  affected PRs.

- **Indefinite auto-merge.** GitHub's `gh pr merge --auto` waits
  forever for required checks to go green. A flaky or hung required
  check leaves the PR in armed-but-not-merged state indefinitely. This
  is acceptable today (the PR remains visible, draft-promoted, and a
  human can take over by running `gh pr merge --disable-auto` or by
  fixing the check). A future janitor job that cancels armed
  auto-merges older than N hours is **out of scope** for this ADR and
  should be revisited if it becomes a real operational problem.

#### 5. Update to `docs/DESIGN.md`

Constraint #4 in the "Critical constraints — non-negotiable" section is
**amended in this PR**, not deleted. The amendment preserves the
default-draft posture and adds the conditions under which promotion is
allowed:

> 4. **Draft PRs by default; promotion allowed only inside ADR-002's
>    safety envelope.** The pipeline opens drafts. Promotion to ready +
>    auto-merge requires every gate in ADR-002 to be true; otherwise the
>    PR stays draft.

`CLAUDE.md` is not amended — the project's `CLAUDE.md` is the AI base
instructions + CI-automation stack overlay and does not carry this
specific rule. (The original issue
[#12](https://github.com/freaxnx01/claude-pipeline/issues/12) body cited
`CLAUDE.md`; the rule is actually in `docs/DESIGN.md` under the
"Critical constraints — non-negotiable" section, item 4. Corrected
here.)

### Consequences

- The `auto-review-enabled` workflow output added in
  [#13](https://github.com/freaxnx01/claude-pipeline/issues/13) becomes
  the first gate consulted by
  [#15](https://github.com/freaxnx01/claude-pipeline/issues/15). It is
  necessary but not sufficient — gates 1, 4, 5, 6, 7 above are all
  evaluated after it.
- The safety envelope is the **single source of truth** for "is this PR
  auto-mergeable."
  [#15](https://github.com/freaxnx01/claude-pipeline/issues/15)'s
  `scripts/check-merge-envelope.sh` (to be written there) implements
  exactly these checks — no extra, no fewer. Any divergence is a bug in
  one place or the other, not a policy disagreement.
- Issue [#17](https://github.com/freaxnx01/claude-pipeline/issues/17)
  (chaining ADR) inherits the assumption that auto-merge is the only
  trigger for chain-dispatch. If a human merges a chained issue's PR
  manually, the chain does NOT auto-advance — this is intentional
  (manual merge implies the human is steering).
- **`ai:review-blocked` label provenance.** §2 names this label as a
  side effect of a failed gate, but the in-tree `ensure-issue-labels.sh`
  does not create it today. **Whichever of #14 or #15 lands first MUST
  extend `scripts/ensure-issue-labels.sh`** with `ai:review-blocked`
  (red, description: "Auto-review left the PR draft; human action
  required") AND add a `tests/run-script-tests.sh` assertion that the
  label appears in the mock log — so the missing-label state fails CI
  and the obligation cannot be silently dropped. The other issue
  rebases over the change.
- **Posture asymmetry with ADR-001 is principled, not accidental.**
  ADR-001 trusts the agent step to fail loudly on bad auth and lets
  `classify-failure.sh` bucket the error — blast radius is low (one
  failed run, retriable). ADR-002 validates seven gates pre-merge
  because the blast radius of a bad auto-merge is a bad commit on
  `main` — much more expensive to recover from. Different consequence
  asymmetry justifies different posture. Future ADR readers should not
  try to "harmonize" the two; the asymmetry is the point.
- **Gate 6 trade-off cost.** The blanket `.github/` exclusion blocks
  routine docs-only PRs to `.github/ISSUE_TEMPLATE/`,
  `.github/PULL_REQUEST_TEMPLATE/`, `CODEOWNERS`, `dependabot.yml`,
  etc. This is accepted as a conservative default. If it becomes
  painful, a future ADR can carve out a `.github/` allowlist (purely-
  declarative subpaths that cannot affect workflow execution) without
  needing to revisit ADR-002's core decision.
- **Self-modification / dogfooding.** `claude-pipeline` itself MUST NOT
  enable `auto-review: true` until a follow-up ADR addresses the
  self-modification risk surface that other consumer repos don't have:
  the pipeline's own `scripts/`, `tests/`, `docs/DECISIONS.md`, and
  `.github/` ARE the pipeline. A PR in this repo that changes any of
  them could change the gates applied to itself.

  To prevent accidental violation, #15 MUST implement a workflow-level
  guard: refuse to promote (post a clear comment naming this ADR, leave
  PR draft) when `github.repository == 'freaxnx01/claude-pipeline'`
  regardless of input or label state. Hardcoding the repo string in the
  guard is acceptable for this single-known-instance carve-out; if the
  pipeline ever forks, the fork's first task is to update the guard.
  Prose alone is insufficient — the guard MUST exist in code.
