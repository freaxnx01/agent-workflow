# Glossary

## Agent-owned body

Convention that an enriched issue's generated sections are written only by
agents, never hand-edited. Human corrections go in as comments. Keeps
regeneration idempotent and makes the comment thread the audit trail for why a
plan says what it says. The original description at the top of the body stays
human-owned — `/enrich` preserves it verbatim.

## Assumptions block

An `## Assumptions` section written by [quick-mode](#quick-mode). One entry per
decision the agent made unaided, each carrying the rejected alternative, the
evidence behind the choice (`file:line` for any claim about existing behaviour),
and a confidence marker. Confidence is `[high]` / `[med]` / `[low]`
— how likely the human is to disagree, not how sure the agent is that it works.

The unit of async review: scan `[low]` entries first, skim the rest.

## Consequences block

A `## Consequences` section written by [quick-mode](#quick-mode). One entry per
effect that was *not* a decision — collateral changes nobody chose but everybody
inherits. Examples: "pacing: each entry adds ~50ms to page load", "side effect:
adding a sea also marks it as 'recently modified' for sorting". Decisions go in
[Assumptions](#assumptions-block); consequences are what nobody chose.

## Enrichment run

A batch of parallel agent sessions that turn scoped issues into
implementation-ready ones across a repo group. Grouped by a shared
[run label](#run-label). Distinct from an implementation run, which consumes
those issues via `ai-implement`.

## Epic

An epic is **not a native GitHub object** — it's a convention layered on top of
issues, and there are two common ways to express it:

1. **A tracking issue with a checklist** of links to the sub-issues. Works
   everywhere, but the bookkeeping is manual — nothing keeps the checklist in
   sync with the issues it points at.
2. **Native sub-issues** — GitHub's parent/child relationship between issues,
   shown in the issue sidebar. Unlike milestones, this *does* nest: a parent
   issue can have children, and those children can have children of their own,
   so an "epic" issue can sit inside another "epic" issue. It's supported in
   the UI and via the REST/GraphQL API; the `gh` CLI has no first-class
   sub-issue command yet (verified against `gh` 2.92.0 — no `gh issue
   sub-issue`, no `--parent` flag on `gh issue edit`), so scripting it means
   going through `gh api`.

An epic answers **"what work, and what scope"**. See [Milestone](#milestone)
and [Label](#label) for the other two axes, and
[Milestones vs epics vs labels](#milestones-vs-epics-vs-labels) for how they
combine.

## Label

A label is an **orthogonal categorization axis** — `bug`, `epic`,
`needs-enrichment`, `🧊 parked` — and nothing more. It is a tag, not a
grouping or containment mechanism: labelling ten issues `epic` doesn't relate
them to each other or to anything else. An issue can carry any number of
labels at once.

In this repo, labels drive routing rather than structure: `needs-enrichment`
marks an issue for `/enrich`, `ai-implement` hands it to the agent-workflow,
`🧊 parked` keeps it out of `/issues`. A label named `epic` just marks an
issue as being an epic-tracker so it can be filtered for — it doesn't make
anything belong to it.

## Milestone

A milestone is a **native GitHub object** scoped to a single repository (a
repo can have many, but a milestone can't span repos), holding a due date and
a flat list of issues and PRs. Create one via repo → Issues → Milestones → New
Milestone, or:

```bash
gh api repos/{owner}/{repo}/milestones -f title=... -f due_on=...
```

Assign issues to it from the issue sidebar or with
`gh issue edit <n> --milestone <name>`.

Milestones are **date- or release-scoped**, they do **not nest**, and an issue
belongs to **at most one milestone at a time**. A milestone answers **"when
does this ship"** — not what the work is. See
[Milestones vs epics vs labels](#milestones-vs-epics-vs-labels).

## Milestones vs epics vs labels

GitHub gives three separate, non-overlapping mechanisms here, and it's worth
keeping them distinct rather than picking one to stand in for all of it — a
milestone is not an epic, and an epic is not a label:

- **[Epic](#epic)** — a parent tracking issue (optionally using native
  sub-issues for nesting). Answers *what work, what scope*.

- **[Milestone](#milestone)** — a date/release bucket. Answers *when does this
  ship*. One milestone can hold issues from several epics, and one epic's
  issues can spread across several milestones.

- **[Label](#label)** — a flat tag (e.g. `epic`) used to filter. Answers
  *nothing about structure*; it only marks.

## One-way door

A decision [quick-mode](#quick-mode) refuses to make alone: irreversible
operations, anything touching credentials, anything that spends money, anything
changing a public interface others depend on. These escalate to the human and
block the session.

Everything else is a two-way door — reversible, so the agent decides and records
it in the [assumptions block](#assumptions-block).

## Quick-mode

An `/enrich` variant that asks the human nothing. At each decision point the
agent chooses the option it would otherwise have recommended, records it in the
[assumptions block](#assumptions-block) and [consequences block](#consequences-block),
and continues. Escalates only on [one-way doors](#one-way-door).

Converts a synchronous interview into an async review queue: the human reviews
the finished issue rather than answering questions mid-session. The trade is
losing mid-interview steering — a wrong premise produces a complete plan built
on it, which has to be rejected wholesale rather than corrected at question
three. Confidence markers are the mitigation, not a cure.

## Revise

Regenerating an enriched issue's generated sections from its description and all
its comments. A fresh session, not a resumed one: the issue is the entire input.
Wholesale regeneration rather than delta patching, so repeated runs on unchanged
input produce the same result and two rounds of corrections can't half-apply.

## Run label

`run:<date>` — groups issues from one [enrichment run](#enrichment-run) across
repos. Needed because [milestones](#milestone) are scoped to a single repo and
so cannot span a repo group. Pairs with an [epic](#epic) tracking issue holding
the child checklist.

## Scope creep

Scope creep is when work quietly expands beyond what was originally asked for —
a bug fix that grows into a refactor, a small feature that pulls in unrelated
cleanup, or a discovery made mid-task ("found a flaky test", "this dependency
is vulnerable") that gets fixed on the spot instead of being written down for
later. It happens one small, reasonable-looking step at a time, which is what
makes it hard to notice from the inside — each hop seems justified, but three
or four hops away from the original request you're effectively doing a
different project without ever deciding to. This repo's convention is to treat
anything outside the stated scope as a **discovery**, not automatically a
**task**: capture it (`/capture-idea`, `docs/TODO.md`, `/new`)
and keep going on the original ask, only expanding scope when that expansion
is a deliberate decision rather than a drift. See
[`partials/scope-boundary.md`](../partials/scope-boundary.md) for the full
rule.

## Ship rate

Not one number — see
[`COMMAND-CHEATSHEET.md`](COMMAND-CHEATSHEET.md#what-ship-rate-means) for the
three a report actually shows and which denominator each uses. In short:
**shipped** means an issue that was dispatched at least once and closed by a
**merged** pull request. It is attribution, not causation — work the agent failed
at and a human then fixed still counts.

Definition kept there rather than duplicated here, because it comes with caveats
(a hand-closed issue never counts; a PR with no closing reference never counts)
that are useless separated from it.

## SDLC

Software Development Life Cycle — the end-to-end sequence from intake
(capturing a new requirement) through release and back into the backlog. A
working sketch of an AI-assisted SDLC for this workflow — full phase list
plus a four-loop Plan/Build/Validate/Operate framing — is captured as an idea,
not yet a settled convention: see
[`docs/ideas.md`](ideas.md#complete-ai-assisted-sdlc-loop).
