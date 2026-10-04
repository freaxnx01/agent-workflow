# Actor-pair naming for the review flows — design

**Date:** 2026-08-30
**Status:** Approved, pending implementation
**Supersedes naming in:** ADR-002 (`auto-review`), ADR-004 (`pre-preview`)
**New ADR:** ADR-009

## Context

The pipeline has three end-states after it opens a draft PR:

1. raw draft — no agent review, a human does everything;
2. `auto_review` (ADR-002) — the agent reviews and, inside the merge
   envelope, **auto-merges**;
3. `pre_preview` (ADR-004) — the agent reviews (and optionally self-fixes),
   and on approve promotes the draft to ready so a **human** merges.

Flow 3's name does not survive contact with a reader. "Pre-preview" names a
*stage* — and a doubled one at that, a thing before a preview — when the
actual differentiator against flow 2 is *who merges*. Flow 2's name has the
mirror problem: "auto-review" names only the review half and stays silent on
the part that carries all the risk, the automatic merge. Neither name tells
a maintainer scanning issue labels which flow will end with a machine
pushing to `main`.

Renaming one without the other would leave the two siblings on different
naming schemes, so both are renamed together.

## Decision

Name each flow by the actor pair that defines it: **who reviews, who
merges**. Both halves are always AI-reviewed, so the names differ in their
second half, which is precisely the axis that matters.

| Surface | flow 2 (was `auto-review`) | flow 3 (was `pre-preview`) |
|---|---|---|
| Workflow input | `ai-review-ai-merge` | `ai-review-human-merge` |
| Issue label | `ai-review-ai-merge` | `ai-review-human-merge` |
| Job id | `ai_review_ai_merge` | `ai_review_human_merge` |
| Gate script | `check-ai-merge-gate.sh` | `check-human-merge-gate.sh` |
| Gate env var | `INPUT_AI_REVIEW_AI_MERGE` | `INPUT_AI_REVIEW_HUMAN_MERGE` |
| `post-auto-review-block.sh` `MODE=` | `ai-merge` | `human-merge` |
| `onboard-consumer.sh` flag | `--ai-review-ai-merge` | `--ai-review-human-merge` |

Precedence is unchanged: an issue carrying both labels runs
`ai_review_human_merge`, and `ai_review_ai_merge` is suppressed. Under the
new names this reads as a sentence rather than requiring the comment that
currently explains it.

Two user-facing strings follow the rename:

+ promote-to-ready comment — "Pre-reviewed ✓ — promoted to ready. Merge is
  yours (no auto-merge in pre-preview mode)." becomes "Reviewed ✓ — promoted
  to ready. Merge is yours.";
+ block-comment prefix — `Pre-review held` becomes `Review held`. The
  `Auto-merge held` / `Auto-review held` prefixes on the AI-merge path are
  unchanged in wording.

### Compatibility

Three contract surfaces, deliberately given different promises.

**Inputs and labels — aliased for one major.** `auto-review:` and
`pre-preview:` remain declared on `workflow_call` with `DEPRECATED:` leading
their descriptions. Each gate script reads both env vars, ORs them, and
emits a `::warning::` annotation naming the replacement when the deprecated
spelling is the only one set. The OR and the warning live in the **script**,
not in workflow YAML, so both are reachable by Layer-1 fixtures — inline
YAML bash is neither linted nor tested.

The same tolerance applies to labels: a gate matches either
`ai-review-human-merge` or `ai-pre-preview` (respectively
`ai-review-ai-merge` or `ai-auto-review`), warning on the deprecated one.

**The `auto-review-enabled` output — aliased.** It is a real
`workflow_call` output; keeping it costs one duplicated `value:` line
pointing at the same expression.

**Stub inputs and assertion outputs — renamed outright.**
`stub-auto-review-enabled`, `stub-pre-preview-enabled`,
`*-merge-attempted`, `*-ready-attempted` and
`*-self-fix-iterations-used` are documented test-only, are empty on real
runs, and have exactly one consumer: this repo's own
`agent-implement.test.yml`. An alias would be maintenance with no reader.

`MODE=` values on `post-auto-review-block.sh` are internal — set by the
workflow, never by a consumer — and are renamed outright with their
fixtures.

### Label lifecycle

`ensure-issue-labels.sh` creates **only** the new labels. Old labels already
present in a consumer repo are never deleted: the gates still honour them,
and deleting a label strips it from every issue that carries it.

The pipeline does not migrate labels on its own — it does not silently
rewrite label state a human applied. `docs/CONSUMER-SETUP.md` documents the
bulk migration instead, run per repo when the maintainer chooses:

```bash
gh issue list --label ai-pre-preview --json number --jq '.[].number' \
  | xargs -I{} gh issue edit {} \
      --add-label ai-review-human-merge \
      --remove-label ai-pre-preview
```

### Design history is immutable

`docs/superpowers/plans/`, `docs/superpowers/specs/`, `CHANGELOG.md`
history, and the bodies of ADR-002 and ADR-004 keep the old names. They are
dated records of what was decided on those dates, and `DECISIONS.md` states
its own rule: supersession is captured by a follow-on entry, never by
editing prior history. Each of ADR-002 and ADR-004 gets a single appended
line pointing at ADR-009.

This is also the scope lever that makes the change tractable: of roughly
1000 occurrences across 47 files, about 950 are history. Excluding them
leaves ~15 live files.

## Scope

**Touched:**

+ `scripts/check-auto-review-gate.sh` → `check-ai-merge-gate.sh` (`git mv`)
+ `scripts/check-preview-gate.sh` → `check-human-merge-gate.sh` (`git mv`)
+ `scripts/post-auto-review-block.sh` — `MODE` values and prefixes
+ `scripts/self-fix-loop.sh`, `scripts/self-fix-pr.sh` — comments/wording
+ `scripts/verify-gh-mock-merge.sh` — comments referencing the job
+ `scripts/ensure-issue-labels.sh` — new label names + descriptions
+ `scripts/onboard-consumer.sh` — flags and the generated `with:` block
+ `.github/workflows/agent-implement.yml` — inputs, outputs, job ids, steps
+ `.github/workflows/agent-implement.test.yml` — stubs and assertions
+ `.github/workflows/agent.yml` — this repo's own caller
+ `.github/workflows/claude-implement.yml`
+ `tests/run-script-tests.sh` — gate sections
+ `commands/gh/implement.md`, `commands/gh/review.md`
+ `docs/CONSUMER-SETUP.md` — `with:` block + migration section
+ `docs/DECISIONS.md` — ADR-009 + two supersession lines
+ `CHANGELOG.md` — `Changed` and `Deprecated` entries

**Not touched:** `docs/superpowers/**`, `CHANGELOG.md` history, ADR-002 and
ADR-004 bodies.

**Not renamed:** `post-auto-review-block.sh`, `self-fix-loop.sh`,
`self-fix-pr.sh`, `check-merge-envelope.sh`, `review-pr.sh`,
`find-pipeline-pr.sh` — each is shared by both flows, so no actor-pair name
fits them.

## Testing

`tests/run-script-tests.sh` already drives both gates through `ISSUE_LABELS`
with no network access, so the new cases extend the existing sections. Per
the stack rule that every branch carries a fixture, each gate gets the full
matrix:

+ new input + new label → `enabled=true`, no warning
+ deprecated input + deprecated label → `enabled=true`, warning emitted
+ new input + deprecated label → `enabled=true`, warning emitted
+ deprecated input + new label → `enabled=true`, warning emitted
+ neither input → `enabled=false`, no warning
+ input set to a value outside `{true,false}` → exit 2

Layer 0 (`actionlint` + `shellcheck`) and Layer 2 (`act` on
`agent-implement.test.yml`) both run. Layer 2 is the one that matters here:
the renamed jobs are referenced through `needs.implement.outputs.*` and by
the test workflow's assertions, and a partially applied rename fails there
rather than in fixtures.

## Consequences

+ ADR-006 records **six consumer repos** — flowhub, FlowHub-CAS-AISE,
  quotes, quicktask-vikunja, bridge, agent-action-sandbox — of which three
  (flowhub, FlowHub-CAS-AISE, agent-action-sandbox) pin `@main`. Those three
  pick the rename up on merge with no action from them, which is the whole
  reason the inputs and labels are aliased rather than cut.
+ `VERSION` is already `2.0.0` against a newest tag of `v1.13.0`, so the
  contract change rides the in-flight major instead of forcing a new one.
+ The deprecated inputs, labels and the `auto-review-enabled` output are
  removed in **v3**. That removal is the follow-up issue, not part of this
  change.
+ This repo dogfoods flow 3 on itself via `agent.yml`. Because `agent.yml`
  calls `uses: ./.github/workflows/agent-implement.yml` and runs from the
  default branch on `issues` events, the implementing PR is reviewed by
  `main`'s pre-rename copy — the old names still work there, so there is no
  bootstrap problem and both files can change in one commit.
+ A grep for `pre-preview` will still return hits after this lands. They are
  all history, by design.

## Out of scope

+ Collapsing the two boolean inputs into one mode-valued `review-mode:`
  input. Considered and rejected for this change: it is a second contract
  change layered on the rename, and the rename is the part that buys
  clarity.
+ Renaming `self-fix` or any shared script.
+ Removing the deprecated names — that is v3.
