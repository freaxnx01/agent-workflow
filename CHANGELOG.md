# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Deprecated

- **naming:** the inputs `auto-review` / `pre-preview`, the labels
  `ai-auto-review` / `ai-pre-preview`, and the output `auto-review-enabled`
  still work but emit a warning annotation naming the replacement.
  **Removed in v3.** See the migration section in `docs/CONSUMER-SETUP.md`.

### Removed

- **commands:** Remove `/gh:done` `/gh:enrich` `/gh:enrich-phased` `/gh:issues`
  `/gh:milestone` `/gh:new` `/gh:parked` `/gh:prs` `/gh:roadmap` `/gh:route`
  `/gh:triage` `/gh:work` and their `/fj:*` equivalents — merged into the
  forge-agnostic `/done` `/enrich` `/enrich-phased` `/issues` `/milestone`
  `/new` `/parked` `/prs` `/roadmap` `/route` `/triage` `/work` commands.
  **BREAKING CHANGE:** anyone invoking a `gh:x`/`fj:x` name directly for one of
  these 12 concepts must switch to the prefix-less command; re-run
  `setup/link-commands.sh` to pick up the change (#198, #199).

### Added

- **issues:** `/issues` takes an optional milestone argument, matching
  `/triage`'s — `/issues <name>` scopes the list to one milestone (exact title,
  else a unique case-insensitive substring), and `/issues pick` lists the open
  milestones with their counts and asks which. A bare `/issues` is unchanged and
  still lists every in-scope issue repo-wide. An argument that matches nothing,
  or more than one milestone, never resolves silently and never falls back to
  "all issues" — it asks. Rows now carry the milestone and its due date, which is
  what makes a wrongly resolved substring visible. On GitHub the scope is a
  server-side `filterBy:{milestoneNumber:}` on the existing GraphQL query — it
  takes the milestone *number*, not its title, so the REST milestones lookup runs
  even for an exact title, and passing the variable **empty** returns zero issues
  rather than all of them; the Forgejo half filters client-side for the same
  unverified-`&milestones=` reason as `/triage` (#289).
- **triage:** `/triage` takes an optional milestone argument — `/triage <name>`
  scopes the list to one milestone (exact title, else a unique case-insensitive
  substring), and `/triage pick` lists the open milestones with their counts and
  asks which. A bare `/triage` is unchanged and still lists every in-scope issue.
  An argument that matches nothing, or more than one milestone, never resolves
  silently and never falls back to "all issues" — it asks. On GitHub the scope is
  `gh issue list --milestone`, filtered server-side so the call stays one cheap
  request; the Forgejo half filters client-side because its `&milestones=` query
  parameter has not been verified against a live `tea`.
- **enrich:** `--quick` flag for non-interactive enrichment — suppress all
  clarifying questions and the user approval gate (except on [one-way
  doors](docs/glossary.md#one-way-door)), record all unaided decisions in an
  `## Assumptions` block with confidence markers and rejected alternatives,
  and include a `## Consequences` block for collateral effects. Converts the
  synchronous interview into an async review queue (#255)
- **enrich-phased:** concurrency lock — Phase `spec` now detects an existing
  `enrichment-ongoing` lock and acquires its own before brainstorming, using
  the same 24h staleness window `/enrich`'s lock now uses (see below) to
  absorb the `/clear` boundaries a phased run legitimately pauses across.
  Both steps run on a new run only, never on a resume — and a resume whose
  earlier stop (issue closed/parked, already-complete) would otherwise
  abandon the lock now releases it first. The state file is written only
  once the lock is confirmed held, so a hard-stop or a lost race leaves
  nothing resumable behind, and label application is verified before the
  race re-check runs. Phase `issue` releases the label on the success path.
  Same label and comment format as `/enrich`, so a lock set by either
  command is seen by the other (#237)
- **enrich:** concurrency lock — `/enrich` claims an `enrichment-ongoing` label
  plus a timestamped lock comment before brainstorming (Step 2.5), hard-stops
  when another session holds a lock younger than 24h (Step 1.5), offers a
  takeover past that threshold, re-checks after acquiring so the session that
  acquired first wins the race, and releases the label at Step 6 or on any
  earlier user-initiated abort (#229)
- **pre-preview:** `self-fix` and `self-fix-max-iterations` workflow
  inputs — on a `request_changes` verdict, optionally let the agent
  attempt bounded fix → re-review cycles before falling back to the
  human-review block path (#81)
- **self-fix:** generalized to also run inside auto-review (not just
  pre-preview), and to route the fix call to whichever agent (Claude or
  OpenCode) actually implemented the issue instead of a hardcoded Claude
  fallback (#193)
- **commands:** `/milestone triage` — lists open issues with no milestone,
  excluding `🧊 parked` and `roadmap`, then walks them one at a time to assign
  one, every write confirmed by read-back (#178)
- **commands:** `/parked` gains `unpark`, `repark`, and `review` verbs —
  unparking hands off to `/route`, reparking records a `🧊 parked:` reason
  comment, and `list` now shows the most recent reason (#174)
- **commands:** `/roadmap` — lists issues labeled `roadmap`, promotes one into
  a milestone (schedule first, then unlabel), and records a `roadmap:` reason
  comment; `/issues` now points here instead of a raw `gh` invocation (#175)

### Changed

- **naming:** the two review flows are named for their actor pair —
  `auto-review` → `ai-review-ai-merge` and `pre-preview` →
  `ai-review-human-merge` — across workflow inputs, issue labels, job ids and
  the two gate scripts (ADR-009). Behaviour and precedence are unchanged.
- **triage:** `/triage` now drops parked (`🧊 parked`) and `roadmap`
  issues in the query itself, and shows each issue's milestone + due date
  alongside its body length. Milestone is displayed, **not** sorted on — the
  bugs → quick wins → rest ordering is unchanged, because triage asks what's
  broken and what's cheap, not when it ships. Body length rides beside the
  200-char preview so the "short, well-defined" quick-win signal survives
  truncation. WIP stays deliberately unexcluded: filtering it needs `/issues`'
  GraphQL timeline query, which would cost `/triage` its single cheap
  `gh issue list` call. Both the GitHub and Forgejo halves.
- **partials:** `subagent-driven-default.md` now carves out issue-based
  dispatch — when a plan targets a GitHub issue in a repo with
  agent-workflow's pipeline wired up, default to `/enrich`'s issue-body +
  `ai-implement` dispatch instead of local `subagent-driven-development`,
  even when brainstorming/writing-plans wasn't invoked via `/enrich` itself.
- **commands:** Extract the duplicated forge host-detection snippet into
  `scripts/lib/detect-forge.sh`, sourced by the 12 merged commands above (#198,
  #199).
- **commands:** `/issues` now also excludes issues labeled `roadmap` (planned
  for a future milestone, not current work), alongside the existing
  `🧊 parked` exclusion (#173)
- **commands:** `/gh:assign` and `/gh:implement` now pick an implementation
  contract by issue shape — the TDD contract for code changes, a before/after
  verification contract for docs-only issues — from the new shared
  `/gh:implementation-contract` (#177)

### Fixed

- **enrich:** the `enrichment-ongoing` release no longer swallows its own
  failure with `2>/dev/null || true` — that pattern is for labels a repo may
  not define, and hiding a failed release leaves the lock held for the full
  staleness window with no signal. Every Forgejo read-modify-PUT of the label
  set now also guards its read: an empty or failed read used to PUT an empty
  set, wiping every label on the issue including `ai-implement` (#237)
- **enrich:** staleness threshold raised from 4h to 24h, matching
  `/enrich-phased`. The lock comment doesn't record which command acquired
  it, so both must use the same window — at 4h, `/enrich` read an
  `/enrich-phased` run's ordinary overnight pause as abandoned and offered it
  up for takeover, the exact double-enrichment bug the lock exists to
  prevent, just via the other command (#237)
- **setup:** `setup/link-commands.sh` now prunes command files it previously
  installed that no longer exist in the repo's `commands/` tree, instead of
  only ever adding/updating. Previously a re-install after a command was
  removed or merged elsewhere (e.g. the gh:/fj: -> forge-agnostic
  consolidation, #198/#199) left the superseded file installed and working
  indefinitely, alongside its replacement. Scoped to a manifest of this
  installer's own prior writes — `~/.claude/commands/` is Claude Code's
  general user-commands directory, not exclusively agent-workflow's, so a
  file this installer never placed (hand-authored, or from another tool) is
  never touched.
- **auto-review self-fix:** the post-self-fix approve path now waits (bounded, up to 3 minutes) for required checks to complete before the merge-envelope re-check, instead of routinely dead-ending at `ai:review-blocked` because checks on the freshly-pushed fix commit hadn't finished yet (#238).

## [1.11.0](https://github.com/freaxnx01/agent-workflow/releases/tag/v1.11.0) - 2026-07-27

### Added

- **commands:** Add /milestone across GitHub and Forgejo (#172)
- **agent-implement:** Expose max_turns as a configurable input

### Fixed

- **gh:enrich:** Resolve spec/plan dirs against gitignore, push to main
- **handoff:** Key handoff files by branch so worktrees don't collide
- **claude-implement:** Forward max-turns input to keep shim in lockstep

### Documentation

- **todo:** Note the missing GLM 5.2 model comparison (#169)
- **decisions:** Add ADR-008 — advisor tool not yet wired into ai-implement
- **glossary:** Distinguish milestones, epics, and labels
- **specs:** Add milestone support design for #172
- **handoff:** Save phase for resume — #172 milestone support
- **plans:** Add milestone support implementation plan for #172
- **plans:** Make #172 plan verification CI-executable
- Add spec and implementation plan for roadmap-label filter (#173)
- **plans:** Make #173 verification CI-safe and dry-run validate it
- Add spec and implementation plan for conditional contract (#177)
- Add spec and implementation plan for /milestone triage (#178)
- Add spec and implementation plans for #174 and #175
- **commands:** Exclude `roadmap` issues from `/gh:issues` and `/fj:issues` (#181)
- **handoff:** Save queue-drain phase for resume
- **plans:** Add implementation plan for max-turns input (#166)

### commands

- **gh:** Make pre-dispatch implementation contract conditional (code vs docs-only) (#180)

## [1.10.0](https://github.com/freaxnx01/agent-workflow/releases/tag/v1.10.0) - 2026-07-26

### Added

- **partials:** `response-formatting` partial, plus a tightened `task-checklist` (#159)
- **partials:** `scope-boundary` rule separating discovery from action
- **commands:** `/git-sync` slash command
- **processing-test-feedback:** `Source` traceability on generated entries
- **docs:** glossary with a scope-creep entry, and a partials overview table in the root README

### Fixed

- **OpenCode runs now fail fast on a missing `OPENROUTER_API_KEY`** (#164).
  Previously the run reached `opencode run`, which silently skipped registering the
  `openrouter` provider and died with a misleading `ProviderModelNotFoundError`
  that looked like a model-id bug. `scripts/check-opencode-auth.sh` now preflights
  the secret and emits an actionable `AuthError`, classified `api_auth` (no retry).
  The `openrouter/` model prefix is unchanged — it was never the cause.
- **ensure-toolchain:** surface the pinned version in the
  `opencode-present-different-version` message
- **test:** stale `[Fact(Skip =` marker whitespace mismatch in the Layer-1 suite

### Changed

- **commands:** stale `claude.yml` references updated to `agent.yml` (#163)
- **commands:** implementation plans are now inlined into the issue body
- **commands:** handoff artifacts are committed and pushed by default
- **chore:** AI instruction files refreshed from `ai-instructions` (base + ci overlay)

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
