# Cheat Sheet — driving the issue→PR pipeline

Quick reference for the commands you actually chain together, in the order you
chain them, plus what the numbers at the end of it mean.

This is deliberately **not** a list of all 37 commands — that list already exists
in three places and rots the moment one is added:

- [`commands/README.md`](../commands/README.md#commands) — grouped by family, with prose
- `/commands` — generated live from each command's `description:` front-matter
- [root README](../README.md#slash-commands--where-they-come-from-and-how-they-get-there) — where each command comes from and how it installs

What this page adds is the **path**, and the two places you measure it.

---

## The path

```text
             ┌── measure the queue ──┐              ┌── measure the outcome ──┐
             │                       │              │                         │
/capture-idea → /new → /triage → /enrich → /gh:implement → /gh:review → /done
                                     ▲          │
                                     │          └─ the pipeline runs unattended
                              /ai-funnel                 (10–25 min)
                                                  /ai-stats
```

| Step | Command | What it produces |
|---|---|---|
| Capture | `/capture-idea <idea>` | a line in the repo's `docs/ideas.md` — no issue yet |
| File | `/new` | an issue, usually carrying `needs-enrichment` |
| Sort | `/triage` | labels, milestone, and a `🧊 parked` decision for what isn't now |
| **Enrich** | `/enrich <N>` | a spec, a plan, and the plan **inlined into the issue body** |
| Dispatch | `/gh:implement <N>` | the `ai-implement` label — the pipeline takes it from here |
| Review | *(automatic)* | the pipeline reviews its own PR; `/gh:review <N>` for a second opinion |
| Close | `/done <N>` | the issue closed and the milestone tidied |

**`/enrich` is the step that gates everything.** The pipeline reads only the issue
**body**, so a spec committed to `docs/` that never got inlined is invisible to it.
`/gh:implement` refuses an issue with no `## Implementation Plan` heading, and
that refusal is the single most common reason a dispatch never happens.

### Variants worth knowing

- `/enrich <N> --quick` — suppresses the clarifying questions and the approval
  gate, and records every unaided decision under `## Assumptions` with a
  confidence marker. Still escalates on one-way doors (irreversible operations,
  credentials, anything that spends money, a public interface others depend on).
- `/enrich-phased` — for an issue too large for one plan; splits it into phases
  first.
- `/route <N>` — decides *whether* an issue belongs in the pipeline at all
  before you spend enrichment on it.
- `/work <N>` — implement locally instead of dispatching. The escape hatch when
  the pipeline is the wrong tool.

---

## The two measurement points

They answer different questions and neither substitutes for the other.

| | `/ai-funnel` | `/ai-stats` |
|---|---|---|
| Question | **Can I fill the queue?** | **Did the dispatches pay?** |
| Position | before dispatch | after dispatch |
| Scope | one repo, all issues | one or many repos, dispatched issues only |
| Blind to | how well runs went | every issue that was never dispatched |

### `/ai-funnel` — backlog readiness

```text
total → open → live (not parked) → carrying a plan → ready to dispatch
                                 ↘ blocked on enrichment
```

The headline is **queue depth**: how many issues could be dispatched *right now*.
It applies `/gh:implement`'s own preconditions, so an issue counted there is one
that command will accept — open, not `🧊 parked`, not already carrying
`ai-implement`, no `needs-enrichment` / `❓ to-be-defined`, and a plan in the body.

```bash
/ai-funnel                          # current repo
/ai-funnel --milestone september    # one milestone (case-insensitive substring)
/ai-funnel --state open
/ai-funnel --limit all              # every row of the blocked/ready tables
```

It also reports the **turn budget** each open issue will get, and warns when a
plan's task headings are at the wrong level — `## Task N` instead of `### Task N`
scores zero in `classify-turns.sh` and silently lands a large plan on the 50-turn
floor. That one is invisible otherwise: the body looks completely enriched.

### `/ai-stats` — dispatch outcomes

```bash
/ai-stats                    # current repo
/ai-stats --all              # every repo under the authenticated owner
/ai-stats --since 30d        # Nd / Nw / Nm, or an ISO date
/ai-stats --limit all
```

Ship rate, cost per shipped issue, a per-issue A–F grade, and breakdowns by
agent, model and enrichment state. Nothing extra is tracked — it is reconstructed
from the `ai-implement` label events and the `## ai-implement run` comments the
pipeline already posts.

---

## What "ship rate" means

> Two notes in this page are **time-bound** and named as such: the parked-issue remedy
> (#321) and the review-held row (#322). Each of those issues carries an acceptance
> criterion to delete its note from here when it lands, so a fixed bug does not leave
> wrong advice behind. (#319's divergence note was removed when it landed — that is the
> mechanism working.)

**It is three different numbers, and a report shows all three.** Reading the wrong
one is the usual way this gets misquoted.

| Row | Formula | Where |
|---|---|---|
| **Issue shipped** | shipped issues ÷ **dispatched issues** | `/ai-stats` |
| **Shipped by the pipeline** | shipped issues ÷ **dispatched issues** | `/ai-funnel` |
| **Per dispatch shipped** | shipped issues ÷ **dispatch attempts** | `/ai-stats` |
| **First-attempt shipped** | shipped on attempt 1 ÷ issues dispatched once | `/ai-stats` |

The first two are **the same measure** — `ai-stats.sh`'s record set is
dispatched-only (`select(.dispatches | length > 0)`, `:174`), so its denominator
already matches `/ai-funnel`'s.

"Per dispatch shipped" is always the **lowest** of them, because a re-dispatch adds
to the denominator without adding an issue. That gap *is* the re-dispatch rate: if
"issue shipped" is 67% and "per dispatch" is 50%, a third of your dispatches were
second tries.

### "Shipped" means closed by a merged PR — nothing more

Specifically: **dispatched at least once, and closed by a pull request that was
merged.** It is attribution, not causation. An issue the agent failed at, that a
human then fixed and merged, still counts as shipped. Don't read it as an agent
success rate — for that, compare it against **first-attempt shipped** and the
per-issue grades.

Two things make it read **low** rather than high, so a low number is not
automatically bad news:

- **An issue closed by hand never counts.** `/ai-funnel` reports those separately
  as *shipped by hand* precisely so they don't silently drag the rate down.
- **A PR that never linked its issue never counts.** The pipeline emits a
  `::warning::` for this (`scripts/check-issue-link.sh`), but the ship rate has
  no way to recover the link after the fact. That warning names the durable fix:
  set `PIPELINE_APP_ID` / `PIPELINE_APP_PRIVATE_KEY` so the PR is authored by
  your own GitHub App rather than `app/github-actions`, and GitHub forms the
  reference normally.

### Both commands read shipped the same way

`ClosedEvent.closer` unioned with `closedByPullRequestsReferences` — the first catches a
PR authored by `app/github-actions` (every PR this pipeline opens), for which GitHub
forms **no closing reference**; the second catches an issue closed by hand that a merged
PR still points at.

If you are looking at a report generated before #319 landed, its shipped count is **too
low** and its grades are too harsh — `shipped` gates the grade
(`if $shipped | not then "F"`), so issues that shipped cleanly on the first cheap attempt
read `F`. On the repo this was measured against, the fix moved the ship rate from 36% to
79% and the grades from A3/B2/F9 to A5/B6/F3, without a single run changing.

Setting `PIPELINE_APP_ID` / `PIPELINE_APP_PRIVATE_KEY` is still worth doing: it makes the
PR author your own App, so GitHub forms the closing reference and the issue **auto-closes
on merge** rather than needing a hand-close.

### The rate you should be suspicious of

A high ship rate over a handful of issues, next to a backlog nobody enriched.
`/ai-stats` cannot see the backlog — an issue that was never dispatched leaves no
dispatch record to count — so it will report the good number without the context
that makes it small. **Run `/ai-funnel` first.** If enrichment coverage is 10%,
the ship rate is measuring a sample, not a pipeline.

---

## Reading a run report

Each dispatch leaves a `## ai-implement run` comment. What to look at:

| Field | Why it matters |
|---|---|
| **Outcome** | `success` here is the *classifier's* verdict — see the caveat below |
| **Turns: N / cap M** | N close to M means the budget was the constraint; N far below M and a failure means something else killed it |
| **Duration** | compare against `claude-timeout-minutes` (default **10**), which is unlinked from the turn budget |
| **Plan** | `enriched` / `none` / `unknown` — `none` means the run was guessing |
| **Cost** | the per-attempt figure `/ai-stats` sums |

> **On re-triggering a PR's checks:** an empty commit is the right tool because it
> fires a `push` event, which the required workflows subscribe to. Close/reopen is not
> the alternative — it only churns the timeline and re-fires `issues: labeled`
> handlers. It is **not** the reason a closing reference goes missing: GitHub never
> forms one for an `app/github-actions`-authored PR in the first place (see the ship
> rate section), so there is nothing for a reopen to break.

A run killed on **wall clock** truncates the agent's output stream, so there is no
terminal result event to classify. Cross-check a `success` against the job
conclusions when the duration is suspiciously close to the cap: the work is often
complete and pushed, with nothing pointing at the PR.

---

## When it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `/gh:implement` refuses | no `## Implementation Plan` in the body | `/enrich <N>` — a spec in `docs/` is not enough |
| Dispatch does nothing | `needs-enrichment` or `❓ to-be-defined` still on the issue | remove the label; `/ai-funnel` flags this as a *stale* label when a plan is already present |
| Run burns its whole budget, no PR | dispatched with no plan → `UNPLANNED_MAX_TURNS`, spent rediscovering the decomposition | enrich, then redispatch |
| Big plan, tiny budget | task headings are `## Task N`, not `### Task N` | fix the heading level; `/ai-funnel` names the affected issues |
| `ai:review-blocked` | the review returned `request_changes` | read the verdict; if it faults the *plan*, correct the spec and re-enrich rather than redispatching |
| `🧊 parked` after N runs | the attempt cap | re-enrich, **then** raise `max-attempts` by one in the consumer's `agent.yml` — the cap counts append-only run reports and cannot yet be told you re-enriched ([#321](https://github.com/freaxnx01/agent-workflow/issues/321)). Comment the bump with a revert-when-#321-lands note; it weakens the guard repo-wide |
| Review "held", PR exists | the PR was opened ready-for-review, not draft | review by hand; [#322](https://github.com/freaxnx01/agent-workflow/issues/322) |
| PR has no CI | agent-authored PRs don't start workflows | push an **empty commit** — it fires `push`, which the required workflows do listen to |

---

## While a dispatch runs — don't watch it

A run is unattended for 10–25 minutes. Spend that window enriching the **next**
wave, not tailing a log. Two rules learned the hard way:

- **Batch specs and plans into one docs PR.** A repo that runs its full CI matrix
  on docs-only PRs burns a cycle per PR for no added review value.
- **Pick the next wave for no file collision** with what is already running. Two
  concurrent runs editing one file produce a conflict that reads like a pipeline
  failure but is a batch-composition mistake.

`/ai-funnel`'s blocker table is what you pick from.

---

## See also

- [`CONSUMER-SETUP.md`](CONSUMER-SETUP.md) — wiring a repo up in the first place
- [`DEFAULT-MODEL-CHEATSHEET.md`](DEFAULT-MODEL-CHEATSHEET.md) — choosing the model
- [`glossary.md`](glossary.md) — the vocabulary
- [`DECISIONS.md`](DECISIONS.md) — ADR-004 (pre-preview: agent self-review → human
  merge), ADR-009 (actor-pair naming: `pre-preview` → `ai-review-human-merge`,
  `auto-review` → `ai-review-ai-merge`)
