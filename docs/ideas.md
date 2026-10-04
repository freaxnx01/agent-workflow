# Ideas

## Complete AI-assisted SDLC loop

- id: 2026-07-30-complete-ai-assisted-sdlc-loop · captured: 2026-07-30 · status: raw
- value: Sketch of a full SDLC (intake through post-release) plus a 4-loop AI-first framing (Plan/Build/Validate/Operate), with open questions on daily workflow and multi-repo WIP limits.

Human tasks:

- Create Issues out of new req & Assign to Milestone
- Enrich Issues (Spec, Impl plan)
- Route Issues (assign Copilot / ai-implement)
- Review Issues (HITL)
- Loop: Manual Tests -> Process Test Feedback (own or others') -> Create Issues
- Documentation
- Release

Open questions:

- What am I doing on a work day?
- Multiple projects/repos — WIP limit?

### "complete" SDLC (fuller phase list, before/after implementation)

1. Intake & Planning — capture requirements, create issues, assign milestone/priority, define acceptance criteria
2. Specification — enrich issues (functional spec, technical design, implementation plan, dependencies, risks)
3. Implementation — route issues (assign developer / Copilot / ai-implement), create PR
4. Review (HITL) — code review, AI review, architecture review (if needed), security review (optional)
5. Verification loop — automated tests, manual tests, process test feedback, create follow-up issues, fix implementation, repeat until accepted
6. Documentation — user docs, developer docs, changelog, ADRs (if applicable)
7. Release — versioning, release notes, deploy, tag release
8. Post Release — monitor, bug reports, customer feedback, create new issues, feed backlog

### AI-first framing as four repeating loops

- Plan: create issues, enrich issues, prioritize
- Build: route issue, AI implement, review (HITL), merge
- Validate: automated tests, manual tests, process feedback, create follow-up issues
- Operate: documentation, release, monitor, feed backlog

Emphasizes the process is continuous rather than linear — production feedback becomes new requirements, starting the next cycle. Automated quality gates (linting, static analysis, unit/integration tests, security scanning) should be explicit in the Verification stage to reduce manual review load.

## Gate results as evidence, and the metrics layer above them

- id: 2026-08-19-gate-results-as-evidence · captured: 2026-08-19 · status: raw
- follows: 2026-07-30-complete-ai-assisted-sdlc-loop
- source: ChatGPT thread "Transform Coding Agent", 2026-08-19 — distilled in `docs/ai-notes/2026-08-19-coding-agent-to-software-factory.md`
- value: The delta between the advisor's software-factory sketch and what this repo already ships. Most of the sketch (contracts, router, deterministic gates, scope guard, AI review, self-fix loop, merge gate) is built. Four things are not.

Delta worth acting on:

1. **Structured gate results.** Gate outcomes currently live as workflow logs and PR comments. Emit one machine-readable result per run instead — `run_id`, `commit`, overall result, and per gate a `name`, `type` (deterministic / ai / human), `result` and a measure. The point is queryable evidence, not the file format.
2. **Metrics on top of those results.** First-pass success rate, average repair iterations, gate failure distribution, escaped defects, issue → merge time, cost per feature. This is the "adaptive factory" step: routing and decomposition change because the numbers say so, not because it felt right. Blocked on (1).
3. **Explicit gate taxonomy.** Declare deterministic / ai / human gates as an ordered list somewhere readable rather than leaving it implicit in workflow wiring. Underlying rule: deterministic checks dominate LLM judgement wherever possible, or the factory becomes agents agreeing with each other.
4. **API compatibility gate.** Not currently a gate. Snapshot the OpenAPI contract per API project and fail the PR on breaking response/route changes.

Explicitly rejected from the sketch (recorded so it does not resurface): a parallel `.factory/` directory tree, a PowerShell gate runner, ten specialised agent roles, and a new control-plane component — `bridge` already occupies that slot.
