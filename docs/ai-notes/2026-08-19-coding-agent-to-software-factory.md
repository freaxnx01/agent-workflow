# Coding Agent → Software Factory (external advisor sketch)

Source: ChatGPT thread "Transform Coding Agent", 2026-08-19. Full transcript alongside in
`2026-08-19-coding-agent-to-software-factory-transcript.md`.
Follows on from `docs/ideas.md` entry `2026-07-30-complete-ai-assisted-sdlc-loop`, which
captured the earlier "SDLC Process Overview" thread. The advisor was given the
`Create Issues → Enrich → Route → HITL → Test → Feedback → Docs → Release` sketch and asked
how to turn a coding agent into a software factory, then asked two follow-ups: what a
contract YAML looks like concretely with Claude Code, and how quality gates are implemented
technically.

This note distils the thread and marks what is already built here, what is genuinely new,
and where the advice diverges from decisions already taken.

## Core framing

The central claim: do not make the coding agent better at coding, make the system around it
better at moving work through a controlled production line. The agent stops being the
workflow and becomes one component inside it.

Stage chain: intake → specify → decompose → route → implement → verify → review → release →
feedback, with production feedback re-entering as new issues.

Second claim: pass information through persistent artifacts rather than prompts. Every stage
consumes a well-defined artifact and produces another, which makes the process inspectable,
resumable and automatable.

## Already covered here

Most of the thread describes things this repo already ships. Recorded so a future session
does not "discover" them again:

| Advisor proposal | Already implemented as |
| --- | --- |
| Contract YAML per work type | `commands/gh/implementation-contract.md` |
| Router (trivial / normal / complex, bug / docs / test / refactor) | `commands/route.md`, `scripts/classify-task.sh`, `scripts/classify-agent.sh` |
| Deterministic gates (build, test, format, analyzers, coverage) | `.github/actions/dotnet-quality/`, `gate-tests/` |
| Scope guard (files outside allowed paths fail the gate) | `.github/actions/dotnet-quality/check-diff-scope.sh`, `scope-from-git.sh`, `partials/scope-boundary.md` |
| AI review producing a structured verdict | `scripts/review-pr.sh`, `scripts/lib/review-prompt.md`, `scripts/check-auto-review-gate.sh` |
| Autonomous repair loop with a retry cap | `scripts/self-fix-loop.sh`, `scripts/self-fix-pr.sh` |
| Merge gate separate from the agent | `scripts/check-merge-envelope.sh`, branch protection |
| Issue as work order (spec + plan + acceptance criteria) | `commands/enrich.md`, `commands/enrich-phased.md` |
| Lifecycle state machine | milestone/label state model in `commands/milestone.md`, `commands/triage.md`, `commands/parked.md` |
| Feedback loop back into issues | `skills/processing-test-feedback/SKILL.md` |

The one principle worth restating because it is easy to erode: the agent may observe the
gates and react to failures, but must never be the authority that declares itself successful.
CI is the final authority.

## Genuinely new — worth acting on

### 1. Gate results as machine-readable artifacts

Currently gate outcomes exist as workflow logs and PR comments. The proposal is to emit a
structured result per run, e.g. a `summary.json` carrying `run_id`, `commit`, overall
`result`, and one entry per gate with `name`, `type` (deterministic / ai / human), `result`,
and a measure (duration, test count).

The point is not the file format — it is that gate outcomes become queryable evidence rather
than prose someone has to read.

### 2. The metrics layer that sits on top

Once gate results are structured, the factory can measure itself:

- first-pass success rate (implementations passing all gates without a repair iteration)
- average repair iterations per issue
- gate failure distribution (which gate blocks most often)
- escaped defects (issues created after release for work already merged)
- time from issue → merge
- cost per feature

And then adapt: "tasks touching more than N files fail at a higher rate" → the planner splits
differently; "agent A needs more review iterations than agent B" → the router changes. This is
the step beyond the current setup, which produces run reports (`scripts/post-run-report.sh`)
but no longitudinal signal.

### 3. Explicit gate taxonomy

Separating gates into deterministic / ai / human as a declared list, so the state machine
knows the order: deterministic gates → AI review → human gate → merge. The rule that follows:
deterministic checks should dominate LLM judgement wherever possible, otherwise the factory
becomes a set of agents agreeing with each other.

Roughly what happens here already, but it is implicit in workflow wiring rather than declared
anywhere readable.

### 4. API compatibility as its own mandatory gate

Not currently a gate. Relevant for the API-heavy work: detect breaking changes to an existing
contract (response shape, route removal) and fail rather than merge. Would need an OpenAPI
snapshot committed per API project to diff against.

### 5. Maturity levels as a framing device

Level 1 agent-assisted → Level 2 agentic pipeline → Level 3 software factory → Level 4
adaptive factory (the factory optimises its own routing and decomposition from metrics).
Useful for `docs/FACTORY-MAP.md` framing; this setup sits at Level 3 with Level 4 blocked on
item 2 above.

## Divergences — do not adopt

- **`.factory/` directory tree.** The advisor proposes `.factory/contracts/`, `.factory/gates/`,
  `.factory/agents/`, `.factory/run-gates.ps1`. This repo has settled on `commands/` +
  `.github/actions/` + the GitHub Issue as the work order. Do not introduce a parallel
  `.factory/` hierarchy.
- **PowerShell gate runner.** Gates here are bash and composite actions. The single-entrypoint
  idea (one command a human, CI, and an agent can all run) is sound and is already served by
  the `justfile` plus `gate-tests/run-selftest.sh`.
- **Ten specialised agent roles** (intake, analyst, architect, planner, coding, test, review,
  security, docs, release, feedback). Over-decomposed for a single-operator factory. The
  current split — enrich, implement, review, self-fix — is the useful subset.
- **Control plane above GitHub/Copilot/Claude.** Overlaps with what `bridge` already does as a
  cross-forge cockpit. Any control-plane work belongs there, not as a new component.

## Follow-ups

- [ ] Decide the structured gate-result format and where it is written (PR artifact vs. repo).
- [ ] Once results are structured, define the first three metrics worth tracking.
- [ ] Evaluate an API compatibility gate for the API projects.
- [ ] Consider recording the deterministic / ai / human gate taxonomy explicitly in `docs/DESIGN.md`.
