# Implementing plans

When executing an implementation plan (after the plan is written and approved),
use the `superpowers:subagent-driven-development` skill **by default** — dispatch
the plan's independent tasks to subagents rather than implementing inline — unless
I explicitly say otherwise.

**Exception — issue-based dispatch.** If the plan was written for a GitHub issue
(brainstorming/writing-plans ran against an issue's context, not ad hoc local
work) **and** the repo has agent-workflow's pipeline wired up — detect via
`.github/workflows/agent-implement.yml` (agent-workflow itself) or
`.github/workflows/agent.yml` (a consumer repo) — do not default to
subagent-driven-development. Instead follow the `/enrich` command's own
ending: push the spec + plan, inline the full plan into the issue body under
an `## Implementation Plan` section, clear `needs-enrichment` /
`❓ to-be-defined`, then dispatch via `/gh:implement` (the `ai-implement`
label) so the pipeline implements it — not this session. `/enrich`'s Step 5–7
(`commands/enrich.md`) is the source of truth for the exact mechanics; don't
duplicate it here, follow it.

This also means: suppress writing-plans' own "Subagent-Driven or Inline
Execution?" handoff question outright in this case — don't ask it, don't wait
for an answer, don't execute the plan locally. Same suppression `/enrich`
already applies to itself.

Falls back to the general subagent-driven-development default above when
either condition is false (no GitHub issue behind the plan, or the repo has
no agent-workflow pipeline wired up), or when I explicitly ask for local/inline
execution regardless of the repo's wiring.

Per Superpowers' own instruction-priority rules, this user-level instruction
overrides the plugin's default skill selection.

## While the pipeline runs, enrich the next wave

A dispatched `ai-implement` run is unattended for roughly 10–25 minutes (implement
plus review). **Do not spend that window watching it.** Arm a monitor so the outcome
arrives as a notification, then immediately start enriching the next candidates —
spec, plan, docs PR, issue body — so the queue is full the moment the current wave
lands.

Enrichment is the throughput bottleneck, not the pipeline. A backlog that has been
triaged but not enriched will have very few dispatchable issues: on
`anim-bossinfo-ch/BI-ArchiveUploader` on 2026-09-09 it was **5 of 30** open
milestone issues, every other one carrying `needs-enrichment`. Sequential
"dispatch → watch → report → enrich" wastes the whole run window, every run.

Two practical rules that follow:

- **Batch the specs and plans into one docs PR.** Many repos run their full
  build/test/lint matrix on every PR, docs-only ones included, so one PR per issue
  burns a full CI cycle each for no added review value.
- **Pick the next wave for no file collision with what is already running.** Two
  concurrent runs editing the same file produce a conflict that reads like a pipeline
  failure but is a batch-composition mistake.
