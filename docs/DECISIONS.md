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
