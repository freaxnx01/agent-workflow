# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.0](https://github.com/freaxnx01/agent-pipeline/releases/tag/v1.6.0) - 2026-06-05

### Added

- Pre-preview mode — agent self-review → human merge (#77) (#80)

## [1.5.0](https://github.com/freaxnx01/agent-pipeline/releases/tag/v1.5.0) - 2026-06-05

### Added

- **onboard:** One-command consumer onboarding (script + just recipe) (#79)

### Documentation

- Rename stale claude-pipeline references to agent-pipeline (#78)

## [1.4.1](https://github.com/freaxnx01/agent-pipeline/releases/tag/v1.4.1) - 2026-06-03

### Fixed

- **envelope:** Gate 5 robust to unreadable branch protection (#75) (#76)

## [1.4.0](https://github.com/freaxnx01/agent-pipeline/releases/tag/v1.4.0) - 2026-06-02

### Added

- **auto-merge:** Optional GitHub App token for PR creation (#55) (#70)

### Fixed

- **workflow:** Update runtime refs to renamed agent-pipeline repo (#68)
- **review-pr:** Salvage JSON verdict from fenced/prose agent output (#73)

### Documentation

- **changelog:** Draft v1.0.0 release notes (#57)
- **runbook:** Reflect #68 merge + correct tag state (#69)
- **runbook:** Record GitHub App auto-merge setup + automation/Passbolt notes (#71)

## [1.3.1](https://github.com/freaxnx01/agent-pipeline/releases/tag/v1.3.1) - 2026-06-02

### Fixed

- **auto-review:** Normalize bot author logins; document App/PAT need (#67)

## [1.3.0](https://github.com/freaxnx01/agent-pipeline/releases/tag/v1.3.0) - 2026-06-02

### Added

- **metrics:** Cumulative token totals + resolved model/agent in report (#66)

## [1.2.0](https://github.com/freaxnx01/agent-pipeline/releases/tag/v1.2.0) - 2026-06-01

### Added

- **opencode:** Upload raw opencode output as a diagnostics artifact (#64)

### Fixed

- **opencode:** Map real --format json event stream to canonical result (#65)

## [1.1.0](https://github.com/freaxnx01/agent-pipeline/releases/tag/v1.1.0) - 2026-06-01

### Added

- **opencode:** Target the real opencode 1.x CLI (experimental) (#61)

### Fixed

- **report:** Degrade gracefully on non-JSON execution file (#60)
- **opencode:** Install opencode after agent classification (#63)

### Documentation

- Consumer onboarding runbook + checklist; ci: harden actionlint download (#51)
- **consumer:** Document two repo-settings traps for first runs (#52)
- **consumer:** Clarify agent selection — assignee vs label (#56)

## [1.0.0] - 2026-06-01

First stable release of the Issue→PR automation pipeline. Consumers pin
`freaxnx01/agent-pipeline/.github/workflows/claude-implement.yml@v1`.

### Added

- **Reusable `claude-implement.yml` workflow** — labeled-issue (`ai-implement`)
  → draft PR. Fetches issue context, runs the agent, opens a draft PR whose body
  carries `Closes #<n>`.
- **Model triage** — `classify-task.sh` selects Opus/Sonnet/Haiku per issue
  (overridable via `model:*` label).
- **Run reporting** — `post-run-report.sh` posts outcome, duration, turns, cost,
  tokens, cache-hit rate, and context-utilization metrics, and stamps lifecycle
  labels (`ai:running`/`ai:done`/`ai:failed`, `ctx:*`).
- **Retry / rate-limit handling** — `classify-failure.sh` buckets failures and
  `retry-dispatch.sh` re-dispatches transient/rate-limit runs with caps.
- **Auto-review + auto-merge** (opt-in, ADR-002) — agent review of the draft PR
  and squash-merge only when the full safety envelope passes: pipeline-author
  allowlist (gate 1), required checks green incl. pending refusal (gate 5),
  `.github/`/secret-glob/blocklist path fences (gate 6), squash+auto-merge repo
  settings and CODEOWNERS pre-check (gate 7). Hardcoded self-modification guard
  for the pipeline repo itself.
- **Issue chaining** (opt-in, ADR-003) — `chain-dispatch.yml` walks `Blocks:` /
  `Blocked by:` markers on auto-merge and dispatches newly-unblocked successors,
  with depth cap, cooldown, visited-set cycle defense, and an `ai:chain-paused`
  kill switch.
- **Second agent backend** (ADR-001) — OpenCode via OpenRouter behind an
  identical result-shape contract: `OPENROUTER_API_KEY` secret, conditional CLI
  install, `agent`/`agent:*` selection, and `adapt-opencode-result.sh`.
- **Label self-healing** — `ensure-issue-labels.sh` creates lifecycle labels
  before use.
- **Toolchain bootstrap** — `ensure-toolchain.sh` installs ripgrep et al. on
  hosted runners, idempotently.
- **Layered tests** — `actionlint` + `shellcheck` lint, fixture-driven
  `run-script-tests.sh`, and `act`-runnable `*.test.yml` workflows covering
  review-verdict, safety-envelope, chain-dispatch, and OpenCode paths.
- **Docs** — `DESIGN.md`, `DECISIONS.md` (ADR-001/002/003), `CONSUMER-SETUP.md`
  with onboarding checklist, and `RUNNER-REQUIREMENTS.md`.

### Fixed

- Default `pipeline-ref` to `main` — `workflow_sha` is caller-scoped and can't
  auto-resolve the pinned ref.
- Expose `GH_TOKEN` to the agent subprocess (workflow- and step-level) so it can
  open PRs.
- Handle the Claude action's JSON-array `execution_file` format.
- Lint workflow: retry the actionlint release download to absorb transient
  HTTP errors.

[1.0.0]: https://github.com/freaxnx01/agent-pipeline/releases/tag/v1.0.0
