---
description: Recommend how to implement an issue — by complexity & readiness
argument-hint: <issue number>
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## GitHub

Help me pick the **right implementation route** for issue #$ARGUMENTS (strip any
leading `#`). Read the issue, judge it, recommend one route with reasoning, then
offer to run it. Do **not** dispatch anything until I confirm.

### Step 1 — Read the issue

```bash
gh issue view <N> --comments --json number,title,state,labels,body,assignees
```

Also note any linked spec/plan files and existing PRs. If it's closed, parked
(`🧊 parked`), or already assigned to an agent, say so and stop.

### Step 2 — Readiness gate (first, non-negotiable)

An agent needs **acceptance criteria + scope + no blocking unknowns**. If the issue
is missing any, or carries `needs-enrichment` / `❓ to-be-defined`:

- Recommend **`/enrich <N>`** (or **`/enrich-phased <N>`** if it's large or
  spans multiple subsystems) and **stop** — don't route an unready issue to any agent.

### Step 3 — Assess the work

Judge the issue on:

- **Complexity & novelty** — mechanical/well-trodden vs. cross-cutting, architectural,
  or subtle.
- **Correctness/security sensitivity** — auth, money, data integrity, concurrency,
  migrations.
- **Breadth** — one file vs. many modules. (If it's really several independent
  subsystems, recommend decomposing into separate issues first.)
- **Locality needs** — does it need things only a local maintainer has: real secrets /
  a live DB, manual/visual verification, hardware, or back-and-forth design iteration?

### Step 4 — Map to a route

| Situation | Route | Why |
|---|---|---|
| Not ready (no AC / scope / open unknowns) | **`/enrich`** then re-run | agents guess badly without AC |
| Needs local secrets, live DB, manual/visual verify, or design iteration | **`/work <N>`** (local, in-session) | only you have the env; you drive it, subagent-driven |
| Ready · small/mechanical · well-trodden | **`/gh:assign <N> claude`** (or **`/gh:implement <N>`** + cheap OpenCode model, Step 4b) | Copilot disabled — Claude direct-assign or the OpenCode pipeline are the cheapest routes left |
| Ready · complex reasoning / architecture / subtle correctness / security | **`/gh:assign <N> claude`** *or* **`/gh:implement <N>`** | stronger reasoning where it matters |
| Want the label-pipeline (`agent.yml`) rather than a direct assignee | **`/gh:implement <N>`** | pipeline path; Claude opens a draft PR |

**How the routes differ (say this when relevant):**

- **`/gh:assign`** → hands the issue to a GitHub **coding agent** on its own branch/PR.
  **Copilot is disabled as of 2026-09-01** — always use **claude**.
- **`/gh:implement`** → applies the `ai-implement` label, which fires the repo's
  **agent-workflow** (`agent.yml`) → Claude implements and opens a draft PR.
- **`/work`** → **local, in this session**: brainstorm → plan → worktree →
  subagent-driven. Best when you want to stay in the loop or the work isn't
  cloud-friendly.

A rough rule of thumb: **mechanical → Claude direct-assign or OpenCode-cheap**,
**needs real judgement → Claude**, **needs your machine or your eyes → local
`/work`**, **not ready → enrich first**. (Copilot disabled as of 2026-09-01.)

### Step 4b — If the route is the agent-workflow, also pick the model

Only when the chosen route is **`/gh:implement`** (the `agent.yml` agent-workflow).
That pipeline can run either **Claude Code** or **OpenCode → OpenRouter**, selected by
`agent:*` + `model:*` labels (label beats the repo's `default-model`). Pick from the
policy below by the **shape** of the work, derived from the OpenCode×OpenRouter model
comparison (provenance: the living [model-comparison report](https://github.com/freaxnx01/agent-workflow/blob/main/docs/model-comparison.md) in agent-workflow `docs/`).

> **OpenCode needs tool-use models.** Never route OpenCode to `model:qwen-coder`
> (no tool endpoint) or `model:codestral` (emits malformed tool calls → no edits).
> Costs are rough $/M (in/out).

| Task shape | Recommend | Why |
|---|---|---|
| Straightforward feature / endpoint / CRUD | `agent:opencode` + `model:minimax-m2` | Tool-use coder; the repo's `default-model` is the safe fallback. `model:gpt-oss-120b` is **retired** — it won a single benchmark round but shipped only 2 of 10 real runs |
| Validation- / architecture-heavy | `agent:opencode` + `model:gemini-flash` (~0.10/0.40) | Most idiomatic structure (DTOs, model-binding validation) in the comparison |
| Bugfix / small mechanical | `agent:opencode` (repo `default-model`) | Cheap for bounded changes; escalate if it stalls |
| Ambiguous / high-stakes / large refactor | `agent:claude` + `model:sonnet` (or `model:opus` if truly high-stakes) | Reliability and judgement over cost |

Before recommending an OpenCode model, sanity-check the repo can honour it: the pinned
agent-workflow ref must include that `model:*` label (set listed in agent-workflow
`docs/CONSUMER-SETUP.md`) and `OPENROUTER_API_KEY` must be set. If not, fall back to
`agent:claude` + `model:sonnet` and say why. Running it means adding the chosen
`agent:*` + `model:*` **alongside** `ai-implement` in one `gh issue edit`.

> **Caveat — thin evidence.** The model policy currently rests on a *single* task type on
> one stack (.NET). Treat it as a starting default; prefer the safer (Claude) pick when
> the task differs materially, and widen the evidence (run the comparison on a bugfix, a
> refactor, a UI change) before hard-trusting per-shape picks.

### Step 5 — Recommend, then offer to run

Print:

- A one-line verdict: the recommended route + the **exact command** to run. If the route
  is the agent-workflow, include the chosen **agent + model** and the label set to apply.
- 1–2 sentences of reasoning tied to what you saw in the issue (workflow choice **and**,
  for the pipeline route, the model choice + rough cost).
- The runner-up route and when it'd be better.

Then ask if I want you to run the recommended command now. Only run it after I confirm.
For the agent-workflow route, "run it" means applying the `agent:*` + `model:*` +
`ai-implement` labels (the readiness gate from `/gh:implement` still applies first).

### Tools

`gh` (issue read), and the sibling commands `/enrich`, `/enrich-phased`,
`/gh:assign`, `/gh:implement`, `/work`.

---

If you hit a blocker (issue not found, ambiguous readiness, a route that doesn't fit
the situation, a routed model label missing in the repo, or a model shape-pick that
consistently underperforms), reason it out, recommend the closest sensible option, and
update this command for the future — including the Step 4b model policy as new
comparison data lands.

## Forgejo

Help me pick the **right implementation route** for Forgejo issue #$ARGUMENTS (strip
any leading `#`). Read the issue, judge it, recommend one route with reasoning, then
offer to run it. Do **not** dispatch anything until I confirm.

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`).

### Step 1 — Read the issue

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
tea issues $ARGUMENTS --login git-home
tea api --login git-home "repos/$repo/issues/$ARGUMENTS/comments"
```

Note any linked spec/plan files and existing PRs. If it's closed, parked
(`🧊 parked`), or already being worked (an `issue-$ARGUMENTS-*` branch or open PR
exists), say so and stop.

### Step 2 — Readiness gate (first, non-negotiable)

An agent/implementer needs **acceptance criteria + scope + no blocking unknowns**.
If the issue is missing any, or carries `needs-enrichment` / `❓ to-be-defined`:

- Recommend **`/enrich <N>`** (or **`/enrich-phased <N>`** if it's large or
  spans multiple subsystems) and **stop** — don't route an unready issue.

### Step 3 — Assess the work

Judge the issue on **complexity & novelty**, **correctness/security sensitivity**
(auth, money, data integrity, migrations), **breadth** (one file vs. many modules —
if it's really several independent subsystems, recommend decomposing into separate
issues first), and **locality needs** (real secrets, a live DB, manual/visual
verification, hardware, or back-and-forth design iteration).

### Step 4 — Map to a route

| Situation | Route | Why |
|---|---|---|
| Not ready (no AC / scope / open unknowns) | **`/enrich <N>`** then re-run | implementers guess badly without AC |
| Ready · anything implementable | **`/work <N>`** (local, in-session) | brainstorm → plan → worktree → subagent-driven; you stay in the loop |

> **No cloud coding-agent route on Forgejo (yet).** GitHub's `/gh:assign`
> (Copilot/Claude bots) and `/gh:implement` (the `agent.yml` agent-workflow) have
> **no native Forgejo equivalent**. The plan is to add a self-hosted **Forgejo
> Actions** pipeline (label → runner runs Claude Code → opens a PR) as a future
> tier; until that runner + `ANTHROPIC_API_KEY` secret exist, **every implementable
> issue routes to local `/work`**. When the pipeline lands, add an
> `/fj:implement` row here and a model-policy step.

### Step 5 — Recommend, then offer to run

Print a one-line verdict (recommended route + exact command), 1–2 sentences of
reasoning tied to what you saw, and the runner-up. Then ask if I want you to run it.
Only run after I confirm.

---

If you hit a blocker (issue not found, ambiguous readiness, or the Forgejo Actions
pipeline becomes available and this routing table is now stale), reason it out,
recommend the closest sensible option, and update this command for the future.

## Unknown host

Report the detected host and that no authed GitHub or Forgejo login matched
it; point at `gh auth login` / `tea login add`. Don't guess a forge.
