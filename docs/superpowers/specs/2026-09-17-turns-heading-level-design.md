# Size the turn budget from either task heading level — design

**Issue:** [#359](https://github.com/freaxnx01/agent-workflow/issues/359)
**Date:** 2026-09-17

## Problem

`scripts/classify-turns.sh:113` sizes the implement job's turn budget by counting
task headings in the issue body:

```bash
task_count="$(grep -cE '^### Task [0-9]+' <<< "$ISSUE_BODY" || true)"
```

It matches **h3 only**. `superpowers:writing-plans` — the skill `/enrich` invokes
to produce the plan it inlines — emits **`## Task N`** (h2), and nothing bridges
the two. A fully enriched plan of any size can therefore land with
`task_count=0` and silently receive `DEFAULT_MAX_TURNS` (50).

The failure mode is the worst available: the issue looks correctly enriched,
triage logs a plausible-sounding reason, and the run simply stops partway with
`error_max_turns`.

### It has already cost a run

#354 was enriched with a 6-task plan written at h2. Triage logged:

```text
chosen: 50 (heuristic: 0 plan task(s), default budget enough)
```

The run died at `error_max_turns`, **51 turns against that cap of 50** — $1.24,
nothing pushed, no PR, and it consumed the issue's last attempt under
`max-attempts: 2`, so the issue could not be redispatched at all. Re-running the
same script against the same plan with h3 headings gives
`chosen: 160 (heuristic: 6 plan tasks)`. Fixed for that one issue in #358; the
next enrichment is exposed again.

### The gap was known, hit before, and fixed only halfway

This is the **second** time h2 headings have broken a dispatch. The comment above
the line names the cause:

> `grep -c` exits 1 on zero matches (**a heading level other than "### Task N"**,
> or a plan with no numbered task headings at all)

and `tests/run-script-tests.sh` carries a regression test recording the first
occurrence — issue #193's Phase 1 dispatch on 2026-08-04, where "the body used
`## Task N` (H2) instead of `### Task N` (H3), classify-turns.sh silently exited
1, and the whole implement job aborted before ever running the implementer."

So the August fix addressed the **crash** — `|| true` plus the here-string — and
then pinned h2-falls-through-to-the-default as *correct* behaviour:

```bash
assert_contains "$out" 'chosen: 50 (heuristic: 0 plan task(s), default budget enough)' \
  "zero task-heading matches → falls through to DEFAULT_MAX_TURNS, not a crash"
```

That made the failure survivable rather than fatal, which was the right call for
a crash. It did not make the budget right, and it left the real cause — the level
writing-plans actually emits — untouched, so #354 walked into the quieter version
of the same bug six weeks later. This change finishes the job.

**This supersedes that regression test deliberately.** Its two still-valid
guarantees — exit 0 rather than a crash, and `DEFAULT_MAX_TURNS` honoured on the
plan-present-but-zero-tasks branch — must be kept, retargeted at a genuinely
task-free body, since h2 is no longer "zero tasks".

## Approach

Relax the pattern to accept either level, and make the zero-task case audible.
Chosen over teaching `/enrich` to rewrite the heading level, because:

- It is one line, in the place that actually consumes the heading.
- It repairs plans **already written** — including any enriched issue sitting in
  the backlog right now with h2 tasks and an undersized budget waiting to happen.
- Rewriting in `/enrich` leaves `classify-turns.sh` brittle for anyone
  hand-writing a plan, pasting one in, or enriching via a different route.

### 1. Count both levels

```bash
task_count="$(grep -cE '^#{2,3} Task [0-9]+' <<< "$ISSUE_BODY" || true)"
```

### 2. Make a zero-task plan loud

A body containing `## Implementation Plan` but yielding no countable tasks is
almost always this bug rather than a genuinely task-free plan. It keeps taking
the default budget — that is the right conservative behaviour — but it now says
so on stderr and as a GitHub Actions annotation, the same pattern
`lib/blocked-models.sh` uses. Had this existed, #354 would have surfaced on its
first run instead of after two failed dispatches.

### Deliberate non-changes

- **Tier thresholds stay** 50 / 80 / 120 / 160.
- **The here-string and `|| true` stay exactly as they are.** That comment
  documents a real SIGPIPE bug: `printf ... | grep -q` let `grep` exit on first
  match while `printf` was still writing, and `set -o pipefail` turned a
  *successful* match into a false condition — losing the budget ~42% of the time
  on the 57KB body of #280. Nothing here touches that.
- **`/enrich` is not modified.** The fix belongs at the consumer.

## Consequences

- **Any already-enriched backlog issue with h2 tasks silently changes budget** on
  its next dispatch — from 50 to whatever its task count earns. That is the
  intent, but it means a redispatch of an old issue may now cost more compute
  than the last attempt did. It will also, presumably, get further.
- **A body mixing `## Task 1` and `### Task 1` for the same task double-counts**,
  possibly over-sizing the budget by a tier. Not a shape a generated plan takes,
  and guarding it costs more logic than it saves; over-sizing merely spends a
  little more compute, where under-sizing loses the entire run. Accepted, and
  pinned by a test so the behaviour is known rather than discovered.
- **The warning fires on a legitimately task-free plan too** — a plan section with
  prose and no numbered tasks. Rare, and a warning on it is not wrong: such a plan
  cannot be sized, which is worth saying out loud.

## Acceptance criteria

- [ ] A plan whose tasks are `## Task N` is sized identically to one using
      `### Task N`, at every tier
- [ ] Fixture tests cover both heading levels at each tier boundary (2, 4, 6)
- [ ] The existing h3 tier assertions keep passing, and the superseded
      h2-falls-through regression test is replaced rather than simply deleted —
      its exit-0 and `DEFAULT_MAX_TURNS` guarantees survive
- [ ] An `## Implementation Plan` section that yields zero countable tasks emits a
      warning naming the likely cause, and still takes the default budget
- [ ] A body with no `## Implementation Plan` section still gets
      `UNPLANNED_MAX_TURNS` (120), unchanged
- [ ] A `turns:*` label still overrides the heuristic entirely
- [ ] The mixed-level double-count is pinned by a test
- [ ] `tests/run-all.sh` passes and `just lint` is green

## Out of scope

Written down, not acted on:

- The tier thresholds themselves.
- `/enrich`'s plan-writing behaviour.
- `#355` (`ADD_TO_PROJECT_PAT` invalid) — unrelated, needs a human-minted token.
- Retro-fixing existing backlog issues' heading levels. This change makes that
  unnecessary, which is the point of fixing the consumer.
