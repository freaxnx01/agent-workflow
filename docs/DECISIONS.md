# Architecture Decisions

This file records architecturally-significant decisions for `agent-pipeline`.
Each entry is dated and immutable — supersession is captured by a follow-on
entry, never by editing prior history.

Format: lightweight ADR (Context / Decision / Consequences) per Michael
Nygard's pattern, kept terse.

---

## ADR-001 — Agent abstraction layer (2026-05-23)

**Status:** Accepted
**Tracking:** [#5](https://github.com/freaxnx01/agent-pipeline/issues/5) under epic [#2](https://github.com/freaxnx01/agent-pipeline/issues/2)

### Context

The reusable workflow `agent-implement.yml` is hard-coded to invoke
`anthropics/claude-code-base-action` and to address Claude model IDs
(`claude-opus-4-7`, `claude-sonnet-5`, `claude-haiku-4-5`). Epic
[#2](https://github.com/freaxnx01/agent-pipeline/issues/2) adds OpenCode

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

+ New `agent` workflow input (string, default `claude`, validated to one
  of `claude | opencode`).
+ Per-issue override via `agent:claude` / `agent:opencode` label, parallel
  to the existing `model:*` override convention.
+ **Three-tier precedence: label > workflow input > script default.** This
  *extends* the two-tier pattern in `classify-task.sh` (label > default),
  which has no workflow-input tier today.
+ A new script `scripts/classify-agent.sh` performs the decision and
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

+ `CLAUDE_CODE_OAUTH_TOKEN` — currently `required: true`; becomes
  `required: false` after the OpenCode path lands so consumers can pick
  one.
+ `OPENROUTER_API_KEY` — added as `required: false`.

Consumers that want both agents available declare both secrets;
consumers that want only one declare only one. The workflow does **not**
validate that the correct secret is set for the chosen agent — the agent
step will fail loudly, and `classify-failure.sh` already buckets that as
`api_auth`.

#### 5. Why this does not create lock-in

The contract is small: one selector script, one result-shape JSON, one
secret per agent. Adding a third agent later (Aider, Goose, a future
first-party Anthropic non-CLI runner) is:

+ Add `agent: <name>` to the input enum and `agent:<name>` to the label
  vocabulary.
+ Add one runner step and one adapter script.
+ Add fixtures for the new agent's success / rate-limit / task-failure
  shapes.

No downstream script changes. The Phase-4 retry/classify infrastructure
(`classify-failure.sh`, `retry-dispatch.sh`) already pattern-matches on
the normalized JSON, not on agent identity.

### Consequences

+ The Claude path becomes one branch of an `if:` ladder rather than the
  unconditional path. Defaults stay the same so existing consumers see
  no behavior change.
+ `classify-failure.sh`'s error-string regex must learn OpenRouter-
  flavored rate-limit / auth / 5xx messages alongside the Claude-flavored
  ones. Tracked in
  [#10](https://github.com/freaxnx01/agent-pipeline/issues/10).
+ Agents that do not surface per-run cost (current OpenCode behavior)
  report `total_cost_usd: 0`. Documented in `CONSUMER-SETUP.md` so the
  run-report comment is not mistaken for "free."
+ The result-shape table above is now load-bearing. Any change to it is a
  breaking change to consumers' assumptions about the run-report. Such
  changes require a new ADR and a major-version bump.

---

## ADR-002 — Auto-review and auto-merge safety envelope (2026-05-23)

**Status:** Accepted — supersedes constraint #4 ("Draft PRs only") in
`docs/DESIGN.md`.
**Tracking:** [#12](https://github.com/freaxnx01/agent-pipeline/issues/12) under epic [#3](https://github.com/freaxnx01/agent-pipeline/issues/3)

### Context

`docs/DESIGN.md` "Critical constraints — non-negotiable" item 4
(April 2026) made it a non-negotiable rule that
the pipeline only opens **draft** PRs and never promotes them. That rule
was the right default when there was no review step between
"agent finished" and "PR exists" — every diff needed human eyes before
merge.

Epic [#3](https://github.com/freaxnx01/agent-pipeline/issues/3) introduces
an agent-driven review step that runs on the just-opened draft PR
([#14](https://github.com/freaxnx01/agent-pipeline/issues/14)). With a
review verdict in hand, there is a defensible path to promoting the draft
to ready and enabling auto-merge — but only if a tight safety envelope is
enforced. This ADR defines that envelope.

### Decision

#### 1. What the policy reversal allows

When all hard-gates in §2 are satisfied, the pipeline may:

+ `gh pr ready <PR>` — promote the draft to ready-for-review.
+ `gh pr merge --auto --squash <PR>` — enable GitHub's native auto-merge,
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
   [#15](https://github.com/freaxnx01/agent-pipeline/issues/15)), or
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
   ([#14](https://github.com/freaxnx01/agent-pipeline/issues/14)) emits
   `verdict=approve`. `request_changes` and `block` both leave the PR
   draft.

   The review prompt
   ([#14](https://github.com/freaxnx01/agent-pipeline/issues/14)) MUST
   flag the following as automatic `block` regardless of other findings:
   + **Any net deletion of test files** — i.e. test-file lines removed
     strictly exceeds test-file lines added (N=0; any net deletion
     blocks). Same rule for whole-file deletions in `tests/**`.
   + Test files renamed-to-skip or marked `@Ignore` / `xit(` /
     `@pytest.mark.skip` / `[Fact(Skip = …)]` / `t.Skip(…)` and
     equivalents.
   + Changes to test fixtures that align expected outputs with newly-
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
   + Anything under `.github/` (workflows, actions, CODEOWNERS, branch
     protection config). Touching CI from within an auto-merged change
     is a self-modifying-pipeline footgun.
   + Encrypted-secret naming conventions: `*.sops.yaml`, `*.enc.*`,
     `*.age`, `*.gpg`, `*.pem`, `*.key`, `*.kbx`, `*.p12`, `*.pfx`,
     `secrets.*`. **Non-exhaustive.** Repos with their own conventions
     extend coverage via the `.claude-auto-merge-blocklist` file below.
   + Paths listed in a repo-local `.claude-auto-merge-blocklist` file
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

+ Posts a single PR review comment naming the failed gate(s).
+ Leaves the PR draft.
+ Applies the `ai:review-blocked` label to the originating issue (label
  itself is out of scope for this ADR; created when needed).
+ Exits the job successfully — gate failure is a *decision*, not an
  error.

#### 3. Merge strategy

**Squash only.** Rationale:

+ The pipeline produces multiple commits per branch (implementation,
  test, fixup-from-review). The commit-by-commit history is uninteresting
  to consumers; the PR-title-as-commit-subject squash gives a clean
  `main` history.
+ Squash-merge plays well with Conventional Commits — the PR title is
  already conventional (the pipeline enforces this when creating the PR),
  so the squash commit is too.
+ Rebase-merge fans out N agent commits into `main`; merge-commit
  pollutes `main` with merge bubbles. Both lose the "one decision per
  merge" story that auto-merge needs to make sense in `git log`.

#### 4. Failure modes & rollback

+ **Required check fails after promotion.** GitHub's auto-merge cancels
  itself and notifies via PR. The pipeline does not retry. A human
  takes over.
+ **Squash-merge succeeds, then a follow-up CI run (e.g. nightly) finds
  a regression.** Revert is a normal `git revert` — no pipeline-specific
  rollback. Worth a future ADR if reverts ever become common, but
  out-of-scope today.
+ **Review verdict was wrong (approved a bad change).** Same as above —
  revert in `main`, and post-mortem the review prompt
  ([#14](https://github.com/freaxnx01/agent-pipeline/issues/14)) before
  re-enabling `auto-review: true` for the issue category that produced
  it.
+ **Gate-envelope bug** (e.g. a `.github/` file slipped through).
  Disable feature via either kill switch:
  + **Per-repo:** flip `auto-review: false` at the call site. No code
    change to `agent-pipeline` needed.
  + **Per-issue:** remove the `ai-auto-review` label from the
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

+ **Indefinite auto-merge.** GitHub's `gh pr merge --auto` waits
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
[#12](https://github.com/freaxnx01/agent-pipeline/issues/12) body cited
`CLAUDE.md`; the rule is actually in `docs/DESIGN.md` under the
"Critical constraints — non-negotiable" section, item 4. Corrected
here.)

### Consequences

+ The `auto-review-enabled` workflow output added in
  [#13](https://github.com/freaxnx01/agent-pipeline/issues/13) becomes
  the first gate consulted by
  [#15](https://github.com/freaxnx01/agent-pipeline/issues/15). It is
  necessary but not sufficient — gates 1, 4, 5, 6, 7 above are all
  evaluated after it.
+ The safety envelope is the **single source of truth** for "is this PR
  auto-mergeable."
  [#15](https://github.com/freaxnx01/agent-pipeline/issues/15)'s
  `scripts/check-merge-envelope.sh` (to be written there) implements
  exactly these checks — no extra, no fewer. Any divergence is a bug in
  one place or the other, not a policy disagreement.
+ Issue [#17](https://github.com/freaxnx01/agent-pipeline/issues/17)
  (chaining ADR) inherits the assumption that auto-merge is the only
  trigger for chain-dispatch. If a human merges a chained issue's PR
  manually, the chain does NOT auto-advance — this is intentional
  (manual merge implies the human is steering).
+ **`ai:review-blocked` label provenance.** §2 names this label as a
  side effect of a failed gate, but the in-tree `ensure-issue-labels.sh`
  does not create it today. **Whichever of #14 or #15 lands first MUST
  extend `scripts/ensure-issue-labels.sh`** with `ai:review-blocked`
  (red, description: "Auto-review left the PR draft; human action
  required") AND add a `tests/run-script-tests.sh` assertion that the
  label appears in the mock log — so the missing-label state fails CI
  and the obligation cannot be silently dropped. The other issue
  rebases over the change.
+ **Posture asymmetry with ADR-001 is principled, not accidental.**
  ADR-001 trusts the agent step to fail loudly on bad auth and lets
  `classify-failure.sh` bucket the error — blast radius is low (one
  failed run, retriable). ADR-002 validates seven gates pre-merge
  because the blast radius of a bad auto-merge is a bad commit on
  `main` — much more expensive to recover from. Different consequence
  asymmetry justifies different posture. Future ADR readers should not
  try to "harmonize" the two; the asymmetry is the point.
+ **Gate 6 trade-off cost.** The blanket `.github/` exclusion blocks
  routine docs-only PRs to `.github/ISSUE_TEMPLATE/`,
  `.github/PULL_REQUEST_TEMPLATE/`, `CODEOWNERS`, `dependabot.yml`,
  etc. This is accepted as a conservative default. If it becomes
  painful, a future ADR can carve out a `.github/` allowlist (purely-
  declarative subpaths that cannot affect workflow execution) without
  needing to revisit ADR-002's core decision.
+ **Self-modification / dogfooding.** `agent-pipeline` itself MUST NOT
  enable `auto-review: true` until a follow-up ADR addresses the
  self-modification risk surface that other consumer repos don't have:
  the pipeline's own `scripts/`, `tests/`, `docs/DECISIONS.md`, and
  `.github/` ARE the pipeline. A PR in this repo that changes any of
  them could change the gates applied to itself.

  To prevent accidental violation, #15 MUST implement a workflow-level
  guard: refuse to promote (post a clear comment naming this ADR, leave
  PR draft) when `github.repository == 'freaxnx01/agent-pipeline'`
  regardless of input or label state. Hardcoding the repo string in the
  guard is acceptable for this single-known-instance carve-out; if the
  pipeline ever forks, the fork's first task is to update the guard.
  Prose alone is insufficient — the guard MUST exist in code.

---

## ADR-003 — Issue-chain dispatch on auto-merge (2026-05-24)

**Status:** Accepted
**Tracking:** [#17](https://github.com/freaxnx01/agent-pipeline/issues/17) under epic [#4](https://github.com/freaxnx01/agent-pipeline/issues/4)

### Context

ADR-002 lands a draft → ready → auto-merge flow for individual issues.
The natural compounding move: when an auto-merge fires and closes its
originating issue, look for an opted-in issue whose `Blocked by:` list
just emptied, and dispatch the pipeline on it automatically. A
maintainer files a small dependency-graph of issues once and the
pipeline walks it.

This ADR defines the conventions and safeguards; implementation
follows in [#18](https://github.com/freaxnx01/agent-pipeline/issues/18)
(workflow wiring) and [#19](https://github.com/freaxnx01/agent-pipeline/issues/19)
(chain-depth cap, cooldown, kill switch).

Manual merges are intentionally NOT triggers. ADR-002 already
established that auto-merge is the only "machine decided this is
ready" signal in the system; manual merges mean a human is steering
and should pick the next issue themselves.

### Decision

#### 1. Body markers

Issues declare dependencies using GitHub's native convention in the
issue **body** (not comments, not titles):

+ `Blocks: #N, #M`     — this issue's completion unblocks #N and #M.
+ `Blocked by: #N, #M` — this issue cannot start until #N and #M close.

Rules:

+ Case-sensitive (matches GitHub's own rendering: `Blocks` / `Blocked by`).
+ Comma-separated lists allowed: `Blocks: #42, #43`.
+ Multiple lines OK: a `Blocks:` line and a `Blocked by:` line, or
  even multiple `Blocks:` lines — the parser unions them into a set.
+ Cross-references to other repos (`Blocks: org/repo#42`) are
  **explicitly out of scope** (see §6); the parser ignores them
  rather than erroring.

The `Blocked by` semantic IS the dependency edge — a successor with
no `Blocked by` entries pointing at unresolved issues becomes eligible
the moment its last blocker closes. The `Blocks` direction is
optional and informational; the parser uses `Blocked by` as the
load-bearing relation.

#### 2. Parser

`scripts/parse-chain.sh` (added in [#18](https://github.com/freaxnx01/agent-pipeline/issues/18)):

+ Reads the issue body via `gh issue view <N> --json body`.
+ Applies a single-line regex per marker
  (`^Blocks:\s*(.+)$` and `^Blocked by:\s*(.+)$`, multi-line mode).
+ Extracts `#N` references, ignores `org/repo#N`.
+ Returns two sets: `blocks=[...]` and `blocked_by=[...]`.

Comments, titles, and PR bodies are NOT parsed. A human can
reorganize the chain by editing the issue body and any change takes
effect on the next auto-merge tick. Editing comments is a no-op.

#### 3. `ai-chain` opt-in label

The chain-dispatch flow is **per-issue opt-in** via the `ai-chain`
label. An issue WITHOUT `ai-chain` is never auto-dispatched even if
all its blockers close. Rationale: the dependency markers are general-
purpose GitHub conventions; consumers may use them for human-tracked
work too. The `ai-chain` label is the explicit "this is meant for the
pipeline" signal.

`ai-implement` and `ai-chain` are independent labels with different
semantics:

| Label combo on a successor issue | What happens when the blocker closes |
|---|---|
| `ai-implement` + `ai-chain` | Successor auto-dispatched on the pipeline. |
| `ai-implement` only | Nothing; maintainer dispatches manually. |
| `ai-chain` only | Successor labeled `ai-implement` and dispatched. (See note.) |
| neither | Ignored. |

**Note on `ai-chain` without `ai-implement`:** the chain dispatcher
adds `ai-implement` itself before triggering. This lets a maintainer
file an entire chain up front with just `ai-chain` and let the
pipeline label-and-dispatch each issue as its turn arrives. The
maintainer never has to touch follow-on issues.

#### 4. Repo kill switch

Two layers, both checked at chain-dispatch time:

1. **Per-issue:** the original `ai-chain` label can be removed from a
   successor at any time; the pipeline checks it before dispatch.
2. **Repo-wide:** an open issue **titled exactly `ai:chain-paused`**
   halts ALL chain dispatch on the repo until closed.

The "open issue titled X" mechanism is chosen over a repo topic
because:

+ It is greppable from any pipeline run via `gh issue list --state
  open --search "ai:chain-paused in:title"`.
+ It needs no special permission (`gh repo edit --add-topic` requires
  admin; opening an issue requires write).
+ The issue body is the natural place to record *why* the kill switch
  is on, who set it, and the lift-off criterion.
+ Closing the issue is the lift-off action — atomic and obvious.

A maintainer opens an issue with the exact title `ai:chain-paused`
when chain-dispatch needs to stop. Re-opens or close-and-reopens are
unambiguous. **Title must match exactly** — the matcher is `==`, not
`contains`, to avoid an issue titled `Add ai:chain-paused to docs`
accidentally tripping the switch.

Propagation latency is the same as ADR-002's kill switches: takes
effect on the next chain-dispatch tick. A chain step that has already
started its CI run will complete; the NEXT step won't fire.

#### 5. Cycle handling

The dispatcher must not get stuck in a cycle (`#A` blocks `#B` blocks
`#A`) or a runaway (`#A` → #B → #C → … → #∞).

Two complementary defenses:

1. **`MAX_CHAIN_DEPTH`** — a workflow input (default `10` per ADR-002-
   adjacent precedent of conservative defaults). The dispatcher
   tracks the chain via the `Closes #N` reference from each merged
   PR; if the depth from the original maintainer-initiated dispatch
   exceeds `MAX_CHAIN_DEPTH`, refuse and post a comment on the new
   successor naming the cap.
2. **Visited-set** — within a single chain (one originating
   maintainer dispatch), the dispatcher remembers issues it has
   already dispatched. If a successor lookup would target an
   already-visited issue, refuse and post a comment.

The visited-set lives in a chain-state issue body, also titled
`ai:chain-state:<originating-issue-N>`, opened and updated by the
dispatcher itself. The body holds a checkbox list:

```text
- [x] #42 (originating)
- [x] #43
- [ ] #44 (dispatched, in-progress)
```

This is observable to the maintainer and survives across workflow
runs without a separate datastore. The dispatcher closes the chain-
state issue when there are no more eligible successors. Both #18 and #19
reference this format.

#### 6. Cross-repo dependencies

Out of scope for this ADR. `Blocks: org/other-repo#42` references are
parsed but ignored when computing successor eligibility. A future ADR
may add cross-repo chain support; until then, every chain edge is
intra-repo.

Rationale: cross-repo dispatch requires either a GitHub App with
access to all involved repos (operational complexity beyond personal-
use scope) or a PAT (auth-surface concentration that ADR-001 / ADR-002
have studiously avoided). Single-repo is enough to walk a typical
"refactor in N steps" chain.

### Worked example

Maintainer files three issues with both `ai-implement` and `ai-chain`
labels:

+ **#100** — "Refactor auth middleware: extract token validator"
  body: `Blocks: #101`
+ **#101** — "Refactor auth middleware: extract session loader"
  body: `Blocked by: #100`, `Blocks: #102`
+ **#102** — "Refactor auth middleware: wire validator + loader into handler"
  body: `Blocked by: #101`

Maintainer dispatches `#100` (label `ai-implement`). The pipeline:

1. Implements #100, opens a draft PR with `Closes #100` in the body.
2. Auto-review + envelope pass → ready → squash-merge.
3. Squash-merge closes #100 and triggers the chain dispatcher.
4. Dispatcher walks `Blocks: #101` from #100's body. Checks #101:
   + `ai-chain` present? ✓
   + All `Blocked by:` entries closed? ✓ (only #100, now closed)
   + `ai:chain-paused` issue open? ✗
   + Depth from origin? 1 < `MAX_CHAIN_DEPTH=10`. ✓
   + Already visited in this chain? ✗
   + **Eligible** → adds `ai-implement` if missing, dispatches.
5. #101 implements + auto-merges → chain dispatcher fires again →
   #102 eligible (its only blocker #101 just closed) → dispatched.
6. #102 implements + auto-merges → dispatcher walks #102's `Blocks:`
   markers (none) → no further dispatch → chain ends.
7. The chain-state issue `ai:chain-state:#100` is closed by the
   dispatcher.

If at step 5 the maintainer had opened an issue titled
`ai:chain-paused`, the dispatcher would have refused at step 5 with a
comment on #102 naming ADR-003 §4 and pointing at the
`ai:chain-paused` issue. The maintainer closes the kill-switch issue
when ready to resume; the dispatcher does NOT auto-retry — the
maintainer must manually re-dispatch the next issue in the chain.

### Consequences

+ **Single source of truth for the dependency graph.** The issue
  body. Editing the body changes the chain on the next tick. No
  separate config file, no project board to keep in sync.
+ **The chain only walks `ai-chain`-opted issues.** A maintainer
  who tags only the first issue with `ai-chain` gets a single-step
  chain that stops after that issue. Useful for partial automation.
+ **Manual merges break the chain by design.** ADR-002 already
  established auto-merge as the only "machine ready" signal;
  inheriting that here means a maintainer who steps in to fix
  something mid-chain naturally takes over the rest.
+ **The chain-state issue is observable, not magical.** A
  maintainer who wants to know "where is the pipeline in my chain"
  reads the chain-state issue. No special tool needed.
+ **Cycle and depth defenses are belt-and-suspenders.** The visited
  set covers true cycles; `MAX_CHAIN_DEPTH` covers chains-too-deep-
  for-comfort and serves as a final brake. Both fail closed — the
  dispatcher refuses on either trigger.
+ **The kill switch is operationally cheap.** Opening an issue is a
  one-keystroke action; no admin permissions, no workflow edit, no
  re-deploy. Lift-off is closing the issue.

---

## ADR-004 — Pre-preview mode (agent self-review → human merge) (2026-06-04)

**Status:** Accepted
**Tracking:** [#77](https://github.com/freaxnx01/agent-pipeline/issues/77)

### Context

The pipeline has two end-states after it opens a draft PR: flow #1 leaves a
*raw* draft for a human (no agent review), and flow #2 (ADR-002) runs an agent
review and, inside a safety envelope, **auto-merges**. There is no middle
ground for a repo that wants the agent's review rigor but keeps the merge
decision with a human.

### Decision

Add a third flow, **pre-preview**, as a `pre_preview` job parallel to
`auto_review`:

+ **Opt-in:** per-repo input `pre-preview: true` AND per-issue label
  `ai-pre-preview` (sibling of `auto-review` / `ai-auto-review`), computed by
  `scripts/check-preview-gate.sh`.
+ **Behavior:** reuse `find-pipeline-pr.sh` + `review-pr.sh`. On `approve`,
  `gh pr ready` only — **no merge envelope, no `gh pr merge`**; a human merges.
  Non-approve / missing PR leaves the PR draft and stamps `ai:review-blocked`
  via `post-auto-review-block.sh` (with `MODE=pre-preview` wording).
+ **No self-modification guard.** Promote-to-ready performs no merge, so
  (unlike auto_review) it is safe on `freaxnx01/agent-pipeline` itself — this
  repo can dogfood pre-preview.
+ **Precedence:** if an issue carries both gating labels, **pre-preview wins**
  — the `auto_review` job gate gains `&& pre-preview-enabled != 'true'`. This
  fail-safes toward human control: ambiguous intent must not auto-merge.
+ **Self-fix deferred.** The agent fixing its own findings is out of scope;
  tracked as a follow-up.

### Consequences

+ Two near-duplicate jobs (`auto_review`, `pre_preview`) share scaffolding by
  copy, not abstraction. Accepted for isolation — the ADR-002 auto-merge job's
  internals stay byte-for-byte. If a fourth flow appears, extract the shared
  "checkout + find PR + review" into a composite action (brainstorming
  approach C).
+ The reusable workflow gains `pre-preview` / `stub-pre-preview-enabled` inputs
  and `pre-preview-{merge,ready}-attempted` outputs.

## ADR-005 — Operator console lives here; user-level vs project-scoped commands (2026-07-12)

### Context

The issue-workflow slash commands (forge routers, `gh:*`, `fj:*`, `enrich`,
`route`, `work`, `capture-idea`) previously lived in `freaxnx01/config`, a repo
scoped to "Claude Code configuration." In practice they are the human-facing
front-end of *this* pipeline — they feed and drive it — so their home was wrong.
`agent-pipeline` is also intended to become forge-agnostic (GitHub Actions now,
Forgejo Actions later), which makes the `fj:*` half native to this repo, not
foreign.

### Decision

1. **`agent-pipeline` = the pipeline end-to-end** — the CI side **plus** the
   operator console. The console lives in a **new top-level `commands/`** directory.
2. **Two command surfaces, deliberately distinct:**
   + `commands/` — **user-level**. Symlinked into `~/.claude/commands/` by
     `setup/link-commands.sh`; active from **any** repo. This is the console.
   + `.claude/commands/` — **project-scoped** (`commit`, `push`, `ui-*`); active
     only inside agent-pipeline. Unchanged.
   Do not conflate them. A command that should work everywhere goes in `commands/`;
   one that only makes sense inside this repo goes in `.claude/commands/`.
3. **`config` stays the single one-URL bootstrap.** Its `setup/01-claude-commands.sh`
   links the retained generic commands, then clones this repo (if absent) and calls
   `setup/link-commands.sh`. This repo exposes the link step but does **not** grow a
   competing machine bootstrap.
4. Files were **copied** here and `git rm`'d from config (per-file history remains
   in config's log); no cross-repo history graft.

### Consequences

+ `agent-pipeline` now has a user-level surface it didn't before — documented in
  `commands/README.md` and here so contributors don't confuse the two dirs.
+ The "one curl sets up a machine" promise survives, now spanning two repos; config's
  bootstrap clones this repo idempotently and surfaces (not swallows) clone failure.
+ Building the Forgejo Actions CI side later has a natural home; the `fj:*` console
  is already here waiting.
+ **Hazard — the console is coupled to this repo's checked-out branch.** The symlinks
  point into the *working tree* (`commands/…`), not at a fixed revision, so the
  user-level console silently becomes whatever the agent-pipeline checkout currently
  has: editing a command on a feature branch changes it globally, and checking out any
  branch that predates this ADR makes all 34 commands **dangling symlinks in every
  repo**. Observed on 2026-07-20: a checkout parked on a pre-move feature branch left
  33 broken links until `main` was restored and the link step re-run. **Resolved the
  same day: `setup/link-commands.sh` now defaults to `--copy`**, so the console is
  pinned at install time and survives any checkout; `--link` opts back into symlinks
  while actively editing commands. Trade-off accepted: `git pull` here no longer
  updates the installed commands — re-run the link step. `config`'s command surface
  was never exposed to this — that repo is effectively always on `main`.

---

## ADR-006 — Rename `agent-pipeline` to `agent-workflow` (2026-07-20)

### Context

ADR-005 reframed this repo as "CI + operator console" but kept the name
`agent-pipeline`. `docs/superpowers/specs/2026-07-20-consolidate-command-surface-design.md`
proposes moving the remaining 11 commands here from `freaxnx01/config` —
`/wt:status`, `/wt:finish`, `/handoff`, `/pickup`, `/wrap-up`, `/loose-ends`
and friends, which are session-hygiene and git-worktree helpers, in no sense
a "pipeline." Landing them here would make `agent-pipeline` describe a
shrinking fraction of its own contents — the same naming failure that spec
diagnoses in `config` ("Claude Code configuration plus other personal
config"). This ADR answers that spec's open decision §1 and supersedes
ADR-005's naming consequence.

### Decision

Rename `freaxnx01/agent-pipeline` to `freaxnx01/agent-workflow`.
`agent-workflow` covers both halves without strain: the CI that implements
labeled issues, and the operator console that feeds it.

### Consequences

+ GitHub's rename redirect keeps consumer CI working, but it is
  **transitional only** — it dies silently the moment any repo claims the
  name `freaxnx01/agent-pipeline`. Every consumer must still be updated
  explicitly; the redirect buys time, not correctness.
+ Six consumer repos depend on this one across 10 workflow files: flowhub,
  FlowHub-CAS-AISE, quotes, quicktask-vikunja, bridge,
  agent-action-sandbox.
+ `.github/actions/dotnet-quality` is a **second public entry point** — a
  composite action consumed by flowhub and FlowHub-CAS-AISE — that
  `docs/CONSUMER-SETUP.md` has never documented. The rename must cover it
  too, not just the reusable workflows.
+ Three consumers pin `@main` (flowhub, FlowHub-CAS-AISE,
  agent-action-sandbox), which this repo's own CI stack overlay forbids.
  They are the most exposed to the redirect's silent failure mode and are
  updated first.
+ Per-file git history is unaffected by a GitHub rename — unlike the
  copy + `git rm` approach ADR-005 §4 used for the console move, no history
  graft is needed here.
+ The local clone directory also moves, which invalidates any git
  worktree's gitdir pointer. This is the exact mechanism that orphaned a
  `.worktrees/misc` directory found in this repo; every existing worktree
  must be recreated after the rename, not just relinked.
