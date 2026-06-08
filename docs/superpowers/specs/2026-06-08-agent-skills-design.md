# agent-skills — Personal Workflow Skill Plugin

> Design spec. Brainstormed 2026-06-08. The skills described here form a family of
> **local, interactive Claude Code skills** that cover the front-of-funnel of the
> personal dev workflow: capture → evaluate → plan → (CI implements) → review,
> plus backlog/chain/retro/failure helpers. They feed the existing
> `freaxnx01/agent-pipeline` CI pipeline; they are not part of it.

## Goal

Ship a dedicated `freaxnx01/agent-skills` repo — packaged as a Claude Code plugin —
containing eight focused skills that orchestrate the user's personal product/dev
loop locally and hand off cleanly to the agent-pipeline CI (the `ai-implement`
Issue→PR pipeline). Done means: the plugin installs once locally, the daily-loop
skills (capture-idea, evaluate-to-issue, plan-sprint, review-pr) work end-to-end
against a real repo and the freaxnx01 "Backlog" Project, and the four supporting
skills (author-chain, pipeline-retro, groom-backlog, triage-failure) are specced
and built.

## Decisions captured during brainstorming

1. **Family of focused skills**, not one orchestrating skill — each is invoked at
   its own moment and is testable independently.
2. **Substrate: local md → GitHub Issues → Project board.** Raw capture in a
   per-repo `docs/ideas.md`; evaluation promotes a worthy idea into a GitHub Issue;
   sprint planning operates on the "Backlog" Project board.
3. **Home: a new dedicated `freaxnx01/agent-skills` repo, as a Claude Code plugin.**
   Not in agent-pipeline (whose CI stack forbids non-CI deliverables and uses a
   reusable-workflow versioning model), not in ai-instructions (stack conventions,
   not personal meta-workflow). The skills are local/interactive, cross-stack, and
   a cohesive distributable family — a plugin is the right vehicle.
4. **Eight skills:** four core (capture-idea, evaluate-to-issue, plan-sprint,
   review-pr) + four supporting (author-chain, pipeline-retro, groom-backlog,
   triage-failure).
5. **Build order: foundation + funnel.** Phase 0 scaffold + shared substrate, then
   the daily loop, then the supporting four.

## Architecture

### Repo layout

`freaxnx01/agent-skills`, scaffolded as a Claude Code plugin on the CI/automation
stack overlay (bash helpers + markdown + tests; no application code):

```
agent-skills/
├── .claude-plugin/plugin.json     # manifest: name, version, the 8 skills
├── skills/
│   ├── capture-idea/SKILL.md
│   ├── evaluate-to-issue/SKILL.md
│   ├── plan-sprint/SKILL.md
│   ├── review-pr/SKILL.md
│   ├── author-chain/SKILL.md
│   ├── pipeline-retro/SKILL.md
│   ├── groom-backlog/SKILL.md
│   ├── triage-failure/SKILL.md
│   └── lib/                       # SHARED, fixture-tested helpers
│       ├── ideas-schema.md        # ideas.md entry format (source of truth)
│       ├── spec-template.md       # issue spec template (migrated from agent-pipeline)
│       ├── ideas.sh               # parse / append / update ideas.md
│       ├── board.sh               # gh project / Backlog board operations
│       └── gh-helpers.sh          # issue / label / PR wrappers
├── tests/
│   ├── fixtures/                  # canonical ideas.md, issue JSON, run-report JSON
│   ├── mocks/gh-mock.sh           # stub gh CLI
│   └── run-skill-tests.sh         # Layer-1 entry point, <5s
├── docs/
│   ├── DESIGN.md                  # this spec, promoted into the new repo
│   └── DECISIONS.md               # ADR-style record
├── justfile · VERSION · CHANGELOG.md · cliff.toml · .editorconfig
└── README.md · CLAUDE.md
```

### Hybrid skill design (key architectural choice)

- **Judgment / orchestration lives in `SKILL.md`** — the prose instructs local
  Claude to run Grep/Glob/Read/LSP, ask focused narrowing questions, surface
  negative findings, and decide outcomes.
- **Deterministic, repetitive operations live in tested bash helpers** under
  `lib/` — parsing `ideas.md`, querying/mutating the board, creating an issue with
  the correct labels. This is what makes the family Layer-1 testable (fixtures +
  mocked `gh`, <5s) rather than untestable prose.

Each `lib/*.sh` starts with the standard prelude (`set -euo pipefail`,
`IFS=$'\n\t'`), quotes every expansion, and is env-driven (not flag-driven) where
called non-interactively.

### Self-improvement loop (every skill)

Every `SKILL.md` ends with a standard closing instruction:

> **If you hit a blocker while running this skill, solve it, then update this skill
> file so the blocker can't recur** — capture the fix as a new step, guard clause,
> or note in the relevant section before finishing the task.

Rules so this stays safe and reviewable:

- The skill edits **its own `SKILL.md`** (or a shared `lib/` helper it owns), never
  unrelated files, and only the part that addresses the blocker.
- The improvement is a normal change: it lands as a commit on a branch and goes
  through the repo's lint/test like any other edit — it is **not** pushed or merged
  automatically.
- Prefer the smallest durable fix (a guard clause, a clarified instruction, a new
  fixture) over broad rewrites. Surface what was changed and why in the skill's
  final summary to the user.

This makes the family self-maintaining: blockers discovered in real use feed back
into the skills instead of being re-hit each run.

## Shared substrate

### `ideas.md` (per-repo)

Lives at `docs/ideas.md` in each consumer repo — ideas stay with the project they
belong to. `capture-idea` appends to the *current* repo's file. Entry schema:

```markdown
## <title>
- id: <date-slug>  · captured: 2026-06-08  · status: raw|evaluated|issued(#42)|dropped
- value: <one-line why it matters>
<free-form body>
```

`status` transitions: `raw` (just captured) → `evaluated` (evaluate-to-issue ran,
not yet delegated) → `issued(#N)` (became GitHub issue #N) → `dropped`
(groom-backlog or evaluation pruned it).

### Issue spec template

Reused verbatim from `agent-pipeline/docs/DESIGN.md` (the delegate-to-gh design):
Goal / Affected files (explicit paths) / Out of scope / Existing patterns to
follow / Acceptance criteria / Test expectations / Constraints. Migrated to
`skills/lib/spec-template.md` as the single source of truth.

### Board & labels

- Board = the existing freaxnx01 "Backlog" GitHub Project. `board.sh` wraps
  `gh project item-add` / `gh project item-edit` to add issues and set
  status/priority fields. Project number discovered via `gh project list`.
- **Labels reused, not reinvented:** `ai-implement`, `model:opus|sonnet|haiku`,
  `ai-chain` — the labels the pipeline already understands. The plugin introduces
  no conflicting labels.

## Skill contracts

### 1. capture-idea
- **In:** fuzzy text (the idea). **Out:** a `status: raw` entry appended to the
  current repo's `docs/ideas.md` (created if absent).
- **Behavior:** zero friction. No clarifying questions unless the title is
  genuinely ambiguous. Confirms with the entry id. Does not evaluate.

### 2. evaluate-to-issue (keystone)
- **In:** an idea (by id from `ideas.md`) or a fresh fuzzy intent. **Out:** a
  GitHub Issue added to the Backlog board (Mode #1), OR a "do it now locally"
  decision (Mode #0), OR "spec not ready — work on it more" (refusal).
- **Behavior (= agent-pipeline DESIGN.md delegate-to-gh):**
  - Path discovery *now*, in the local session: Grep/ripgrep for terms, Glob for
    filename patterns, Read to confirm relevance, LSP `findReferences`/
    `goToDefinition` when available, plus conversation context.
  - Opinionated narrowing — if search returns many candidates, ask focused
    follow-ups; don't dump.
  - **Surface negative findings explicitly** ("no existing 24h cache pattern in
    repo") to stop headless Claude hallucinating patterns.
  - Distinguish "no match" from "greenfield."
  - Fill the spec template. If sections can't be filled after exploration, the task
    is not ready → Mode #0 or refusal. **A refusal is a successful invocation.**
  - Show the full rendered issue body for approval. Never auto-submit. On approval:
    create issue, add to board, set originating idea `status: issued(#N)`.

### 3. plan-sprint
- **In:** optional sprint size. **Out:** a committed sprint set with board status
  updated.
- **Behavior:** reads open Backlog issues via `gh`, presents them with age,
  priority, and blocked status; helps the user pick the worthwhile set; sets board
  status (e.g. "Todo"/"This Sprint"); optionally stamps `ai-implement` to kick the
  pipeline on chosen issues.

### 4. review-pr
- **In:** PR number (or the current branch's PR). **Out:** an executed decision —
  merge / request-changes / close.
- **Behavior:** loads the PR and its originating issue spec. Checks acceptance-
  criteria conformance, scope creep (diff vs the spec's Affected files), and gate
  status (CI green, draft state, ADR-002 auto-merge envelope). May invoke
  `/code-review` for line-level findings as one input. Presents a verdict; the
  **user** decides; the skill executes (merge, or post a request-changes comment
  back to the agent, or close).
- **Distinct from** `/code-review` (line-level bug/quality scan) and the CI
  `pre-preview` self-review — this is spec-conformance + the merge decision.

### 5. author-chain
- **In:** a set of related issues. **Out:** issue bodies updated with
  `Blocks:`/`Blocked by:` markers and `ai-chain` opt-in label.
- **Behavior:** helps express dependencies per agent-pipeline DECISIONS.md ADR-003;
  validates the DAG (no cycles, respects depth); applies on approval. Feeds the
  pipeline's chain-dispatch (which fires only on auto-merge).

### 6. pipeline-retro
- **In:** a time window / label filter. **Out:** a retro summary.
- **Behavior:** reads recent run-report comments the pipeline already posts across
  issues; aggregates outcome, cost, cache-hit rate, and context utilization; flags
  CLAUDE.md health (low cache-hit) and cost trends; recommends tuning. Closes the
  loop — the metrics are posted today but nothing consumes them.

### 7. groom-backlog
- **In:** none. **Out:** a grooming report; approved changes applied.
- **Behavior:** scans `ideas.md` + open issues for duplicates/near-duplicates,
  stale `raw` ideas, and mis-prioritized items; proposes merges/prunes/re-ranks;
  applies on approval. Keeps capture-idea's low-friction dumping from rotting.

### 8. triage-failure
- **In:** a failed issue/run (`ai:failed`). **Out:** a decision + executed action.
- **Behavior:** reads the run report + the pipeline's failure classification
  (rate_limit | transient | task_failure | bug); recommends retry / escalate-model
  / take-it-local; executes the chosen path (re-label + dispatch, or hand to
  evaluate-to-issue's Mode #0).

## Testing strategy

Layered, mirroring the agent-pipeline CI stack:

- **Layer 0 — Lint:** `shellcheck -x` on `lib/` and tests; `actionlint` on any
  workflow; markdown lint on SKILL.md files.
- **Layer 1 — Fixture tests:** `tests/run-skill-tests.sh` drives the `lib/*.sh`
  helpers against `tests/fixtures/` (canonical `ideas.md`, issue JSON, run-report
  JSON) with `gh` mocked via `tests/mocks/gh-mock.sh`. Runs in <5s, no network.
  Every helper branch covered by at least one fixture.
- **Skill-level evals (later, optional):** the two judgment-heavy skills
  (evaluate-to-issue, review-pr) get skill-creator eval harnesses to measure
  triggering accuracy and behavior.
- **Dogfood:** exercise the skills on agent-pipeline's own Backlog — it has real
  issues and is already wired to the "Backlog" Project.

## Build sequence

- **Phase 0 — Foundation:** create `agent-skills` repo
  (`/home/admin/repos/github/freaxnx01/public/agent-skills`, `git init`); scaffold
  plugin.json, justfile, VERSION, CHANGELOG.md, cliff.toml, .editorconfig, lint
  workflow; run `/sync-ai-instructions ci` for CLAUDE.md; build shared `lib/`
  (ideas-schema, spec-template, ideas.sh, board.sh, gh-helpers.sh) + their fixture
  tests; migrate the delegate-to-gh spec/template from agent-pipeline DESIGN.md.
- **Phase 1 — Daily loop:** capture-idea → evaluate-to-issue → plan-sprint →
  review-pr.
- **Phase 2 — Supporting:** author-chain → pipeline-retro → groom-backlog →
  triage-failure.

The implementation plan builds Phase 0 + Phase 1 first so the daily loop works
quickly, then Phase 2.

## Constraints & non-goals

- **Local/interactive only.** These skills run in the user's Claude Code session,
  never in the CI runner. They orchestrate the pipeline; they are not part of it.
- **No conflicting labels or board fields** — reuse what agent-pipeline defines.
- **Never auto-submit** an issue (evaluate-to-issue) or auto-merge without the
  user's explicit decision (review-pr). Approval gates are mandatory.
- **Repo created locally; the GitHub remote is created by the user when ready** —
  this spec does not push or create remotes.
- **Cross-stack.** Skills must not assume dotnet; path discovery uses LSP only when
  a relevant plugin is loaded.
