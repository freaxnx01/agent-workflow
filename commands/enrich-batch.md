---
description: Interactive batch enrichment — group, interview, fan out /enrich --headless, interview again
argument-hint: [<issue>...] [--milestone <name>]
---

Enrich several issues in one session: pick and group them, ask the human the
real design questions up front, fan out one `/enrich <n> --headless` subagent
per issue, then relay the reports and ask again. `/enrich` itself stays a
one-issue command; this is the interactive counterpart to `/autopilot`, with a
human in the loop.

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

Each fenced bash block runs as a separate shell, so variables do not carry
over. Substitute resolved values (issue numbers, the milestone name, a worktree
path) into each block as literals.

## GitHub

`$ARGUMENTS` may carry issue numbers, `--milestone <name>`, both, or nothing.

### Step 1 — Select

Candidates are what the unattended lane would take: open, `needs-enrichment`,
non-empty body, none of `parked`, `enrichment-ongoing`, `needs-human`,
`ai-implement`. With no arguments, that list is the batch:

```bash
source "$HOME/.claude/scripts/lib/autopilot-candidates.sh"
autopilot_candidates "$(gh repo view --json nameWithOwner -q .nameWithOwner)" 100
```

With `--milestone <name>`, keep only the candidates in that milestone:

```bash
source "$HOME/.claude/scripts/lib/autopilot-candidates.sh"
repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
autopilot_candidates "$repo" 100 \
  | grep -Fxf <(gh issue list --repo "$repo" --milestone "<name>" --state open \
                  --limit 200 --json number --jq '.[].number') || true
```

With explicit numbers, keep only those that are candidates. For each number
that is not, read why and say so in one line (closed, `parked`, lock held,
already `needs-human` or `ai-implement`, empty body):

```bash
gh issue view <n> --json state,labels,body \
  --jq '{state, labels: [.labels[].name], empty_body: ((.body // "") | test("^\\s*$"))}'
```

An empty batch ends the command here.

### Step 2 — Group

Read every issue (`gh issue view <n> --json title,body,labels,comments`) and
sort it into one of three groups:

- **quick and clear**: the issue pins the change down; no open design choice.
- **needs decisions**: a real design choice the repo cannot settle on its own.
- **bugs that need cause-finding**: the cause is not known yet.

Pick each issue's model per [Cost rules](enrich.md#cost-rules); graphics and
design work for new things goes to Fable. Show one table and state which model
you picked for each issue and why:

| Issue | Group | Model | Why |
|---|---|---|---|

### Step 3 — Interview first

A headless run cannot ask (`AskUserQuestion` is forbidden there), and it sends
every `[low]` decision to `needs-human`. So ask now, before anything is
dispatched.

For each issue in **needs decisions** (and any other issue where you found a
real choice), ask with `AskUserQuestion`:

- Only real design questions: a choice the issue and the repo leave open, that
  changes what gets built. Do not ask what a subagent can read from the code.
- 2–4 options per question. Put your recommended option first, labelled
  "(Recommended)", and say in its description why you recommend it.
- Batch up to 4 questions per `AskUserQuestion` call.

Record the answers per issue. They go into that issue's subagent prompt, and
the spec records each one as a `[confirmed]` assumption, not as the subagent's
own guess.

### Step 4 — Dispatch

One `Agent` call per issue, each in its own worktree. Run **at most 4** at once
(see [Concurrency](enrich.md#concurrency)): send up to four calls in one
message, and start the next issue only when one finishes.

Every subagent prompt carries that issue's confirmed answers verbatim. An
answer that stays in this session and not in the prompt is lost: the
subagent sees only its prompt.

```text
Agent(
  description: "Enrich #<n>",
  subagent_type: "general-purpose",
  isolation: "worktree",
  model: "sonnet" | "opus" | "fable",   # from the Step 2 table
  prompt: """
    Enrich GitHub issue #<n> in <owner/repo>. Invoke the Skill tool with
    skill "enrich" and args "<n> --headless", and follow it to the end.

    Confirmed answers. Record each in the spec's Assumptions block as
    [confirmed], quoting the answer; do not re-decide them:
    - <question> → <answer>

    [bugs only] Before planning, reproduce the bug headless with the repo's
    own tooling (for example Playwright for a web UI, or the test runner for
    a library) and pin the cause with numbers: the measured value, the
    input that triggers it, the file:line. If you cannot reproduce it,
    escalate the way headless mode does (needs-human) instead of planning.

    Do not apply ai-implement and do not run /gh:implement.

    Report: outcome (ready / needs-human / stopped with error), spec and
    plan paths, every [med] and [low] assumption verbatim, any dependency
    on another issue's plan, your worktree path and branch.
  """
)
```

Bug reproduction stays mandatory (see [No dry runs](enrich.md#no-dry-runs)).
For the other groups, no dry runs.

### Step 5 — Interview after

Relay each subagent's report: issue, group, model, outcome, spec and plan
paths. Then ask the human, with `AskUserQuestion`, about the riskiest `[med]`
assumptions across the batch: those that change behaviour, a public interface
or the data, not wording. Lead with your recommended answer.

When an answer changes something, amend all three: the spec, the plan **and**
the issue body. The issue body is what the pipeline reads; a spec fixed
without the body ships the old decision. Mark the assumption `[confirmed]`,
push the files the way [enrich.md Step 5](enrich.md#step-5--push-to-remote)
does, and edit the body the way its Step 6 does.

An issue that came back `needs-human` and whose open decision is now answered
goes back to Step 4 with the answer as `[confirmed]`. Remove the label first:
`gh issue edit <n> --remove-label needs-human`.

### Step 6 — Housekeeping

**Locks of cut-off runs.** A subagent cut off mid-run (usage limit, crash, no
report) leaves its `enrichment-ongoing` lock behind for 24 hours. Release it
only for issues **this batch** dispatched; a lock on any other issue may be
another session's:

```bash
gh issue view <n> --json labels --jq '[.labels[].name] | index("enrichment-ongoing") != null'
gh issue edit <n> --remove-label enrichment-ongoing
```

**Drafts of cut-off runs.** Before removing a cut-off run's worktree, save its
draft spec and plan to the scratchpad, then resume: dispatch the issue again
(Step 4) and name the saved files in the prompt as the starting point.

```bash
wt="<worktree path from the Agent result>"
dest="<scratchpad>/enrich-batch/<n>"
mkdir -p "$dest"
git -C "$wt" status --porcelain
git -C "$wt" diff origin/main --name-only -- docs
# copy each draft spec/plan listed above into "$dest"
```

**Finished worktrees.** Remove one only when it is clean **and** has no commits
missing from main. `git log origin/main..HEAD` compares SHAs; after a
rebase-merge of the docs PR the landed commits have new SHAs, so for anything
it lists, `git cherry` decides (`+` = a patch not on main):

```bash
wt="<worktree path>"
branch="$(git -C "$wt" branch --show-current)"
git -C "$wt" fetch origin
dirty="$(git -C "$wt" status --porcelain)"
ahead="$(git -C "$wt" log --oneline origin/main..HEAD)"
missing=""
if [[ -n "$ahead" ]]; then
  missing="$(git -C "$wt" cherry origin/main HEAD | grep '^+' || true)"
fi
if [[ -z "$dirty" && -z "$missing" ]]; then
  git worktree remove "$wt" && git branch -D "$branch"
else
  printf 'keeping %s\ndirty:\n%s\nnot on main:\n%s\n' "$wt" "$dirty" "$missing"
fi
```

Report every worktree kept, and why.

**Landing order.** When two plans in the batch touch the same files or one
needs the other first, record the landing order in both specs ("Lands after
#<m>: <reason>"), and push it the same way as Step 5's amendments.

### Scope boundary

This session enriches. It never dispatches (`ai-implement`, `/gh:implement`),
never reviews and never merges code. The docs PR that `/enrich` merges for its
own spec and plan is allowed; nothing else is.

`/enrich`'s Step 7 ends with "run `/gh:implement`". Do not relay that as a
next step. Close with **Notes for the implement session**: the dispatch order
and the dependencies between issues, as plain notes, not as steps or offers.

## Forgejo

Not supported — `--headless` is GitHub-only (see
[enrich.md Headless mode](enrich.md#headless-mode)). Run `/enrich <n>` per
issue instead.

## Azure DevOps

Not supported, for the same reason. Run `/enrich <n>` per work item instead.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.

---

If you run into blockers, find a solution and update this command for the future.
