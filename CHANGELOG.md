# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.9.0](https://github.com/freaxnx01/agent-workflow/releases/tag/v1.9.0) - 2026-07-22

### Added

- **commands:** global `ui/` console namespace for the 4-phase UI workflow (#140)
- **docs:** working note for the 2026-07-21 skills-delivery session under `docs/ai-notes/` (#139)
- **docs:** #133 provisioning-consolidation completion record in `docs/TODO.md` (#141)

### Changed

- **build:** markdownlint now ignores transient agent working docs — `docs/ai-notes/**` and `docs/superpowers/**` (#139)

## [1.8.0](https://github.com/freaxnx01/agent-workflow/releases/tag/v1.8.0) - 2026-07-21

### Added — this repo is now the machine bootstrap

**`partials/` and `setup/bootstrap.sh` move here from `freaxnx01/config`**
(ADR-007, #133). agent-workflow now owns every Claude surface — partials, commands,
hooks, skills — *and* the provisioning that installs them. No cross-repo clone remains.

New machine, one line:

```bash
curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/bootstrap.sh | bash
```

The old `config` URL still works — it forwards, and prints the new one.

**Existing machines:** re-run the bootstrap above (or `/update-commands`). The
installer sweeps the old `config`-era marker block automatically, so the partials
do not load twice. No manual edit of `~/.claude/CLAUDE.md` is needed.

- **setup:** `partials/` surface + `link-partials.sh` with legacy-block migration (#133)
- **setup:** `bootstrap.sh` moves here; verbatim flag passthrough to all link steps (#133)
- **tests:** first coverage for `setup/` — 24 assertions (#133)

### Changed

- **commands:** `/update-commands` runs this repo's bootstrap, not config's installer (#133)
- **docs:** README documents the `partials/` surface and the new bootstrap URL (#133)

### Also included since 1.7.0

Merged into this release ahead of the #133 consolidation:

- **commands:** consolidate the full user-level command surface into this repo (#128)
- **skills:** `processing-test-feedback` skill + `setup/link-skills.sh` installer (#132)
- **skills:** `/process-feedback` merged into the `processing-test-feedback` skill (#137)
- **setup:** `link-skills.sh` prunes skills that disappear upstream (#135)
- **setup:** match the `handoff-resume` hook by basename, not exact command string (#129)

## [1.7.0](https://github.com/freaxnx01/agent-workflow/releases/tag/v1.7.0) - 2026-07-21

### Changed — repository renamed

**`freaxnx01/agent-pipeline` is now `freaxnx01/agent-workflow`** (ADR-006). The repo
outgrew its name: it carries the operator console (issue-workflow slash commands)
alongside the CI, and neither `/wt:status` nor `/wrap-up` is a pipeline.

**Migration.** Update the owner/repo segment of your `uses:` references; keep your
pin exactly as it is:

```yaml
# before
uses: freaxnx01/agent-pipeline/.github/workflows/agent-implement.yml@v1
# after
uses: freaxnx01/agent-workflow/.github/workflows/agent-implement.yml@v1
```

The same applies to the `dotnet-quality` composite action and to any explicit
`pipeline-repo:` input, whose default is now `freaxnx01/agent-workflow`.

GitHub's rename redirect keeps existing references working, so **nothing breaks
immediately** — but it is a transitional safety net, not an end state: it stops
working the moment any repo claims the old name. Update at your convenience.

### Added

- **dotnet-quality:** Composite action + self-validating gate-tests (#88)
- **lint:** Actionlint gate + selftest fixture in agent-pipeline (#90)
- **dotnet-quality:** Add run-method-size input to skip Linux-broken metrics step (#93)
- **classify-task:** Add 5 OpenRouter coding-model labels (#95)
- **classify-task:** Add 5 tool-use-capable coding-model labels (#98)
- **models:** Make Claude Sonnet 5 the default model
- **commands:** Adopt issue-workflow operator console from config
- **setup:** Add user-level console linker (link-commands.sh)
- **commands:** Adopt /process-feedback into the console (#118)

### Changed

- **workflows:** Rename `claude-*` workflows to `agent-*` (#106)

### Fixed

- **labels:** Ensure the ai-implement trigger label exists (#82)
- **classify-task:** Use exact OpenRouter catalog slugs for model labels (#96)
- **claude-implement:** Pass resolved agent to triage step (#97)
- **opencode:** Stop leaking .claude-pipeline gitlink into consumer PRs (#99) (#101)
- **pipeline:** PR-aware run status with recovery (#100) (#104)
- **setup:** Make --copy idempotent over a prior symlink install
- **lint:** Clear markdownlint debt blocking every PR (#119)
- **setup:** Default console install to --copy, not symlink (#117)
- **rename:** Revert three references missed in #123 (#124)

### Documentation

- **ai:** Regenerate AI instructions from ai-instructions@5e6ab78 (#86)
- **model-comparison:** Promote OpenCode×OpenRouter report to canonical living doc (#102)
- **#100:** Spec + implementation plan for PR-aware run status (#103)
- **specs:** Design for agent-skills workflow plugin
- **specs:** Add self-improvement loop to agent-skills design
- **plans:** Phase 0+1 implementation plan for agent-skills
- **model-comparison:** Add Round 3 — .NET authors endpoint (qwen3.6-27b debut) (#113)
- Reframe agent-pipeline as CI + operator console (ADR-005)
- **design:** List top-level commands/ (user console) in repo-structure tree
- **todo:** Add README documentation tasks
- **todo:** Add slash-cmd bootstrap and spec-commit TODOs
- **todo:** Add new-skill idea for workflow-to-repo scaffolding
- **spec:** Consolidate the personal command surface into one repo (#120)
- **plan:** Rename agent-pipeline to agent-workflow (#122)

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
