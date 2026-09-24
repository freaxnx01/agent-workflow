---
description: List, create, assign, or triage milestones — list | new <name> [due <date>] | assign <issue> to <name> | triage
argument-hint: list | new <name> [due <date>] | assign <issue> to <name> | triage
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## GitHub

Manage milestones in the current GitHub repo with **`gh`**.

A milestone is the *when does this ship* axis: repo-scoped, no nesting, one due
date, at most one per issue. It is not an epic (*what work, what scope*) and not a
label (*a filter tag*) — see `docs/glossary.md` in agent-workflow.

### Parse the verb

**Four verbs only** — `list`, `new`, `assign`, `triage`.

- No arguments at all → treat it as `list`.
- A first word that isn't one of the four → print the four usage forms below and
  **stop**. Don't guess the intent, don't fuzzy-match.

```text
/milestone list
/milestone new <name> [due <date>]
/milestone assign <issue> to <name>
/milestone triage
```

### Three rules that apply to every verb

> **`gh milestone` does not exist** (`unknown command "milestone" for "gh"`). Only
> assignment has a first-class flag; creation and listing go through `gh api`.
>
> **Report every write from a read-back — never from the exit code.** This is not
> hypothetical: `gh issue create --label needs-enrichment` has been observed printing
> the issue URL and exiting `0` while silently dropping the label, because the token
> lacked label-write permission. After `new` and `assign`, re-read and report what
> the read-back says, not what the write returned.
>
> **Sort milestones locally, never with the API's `sort=due_on`.** GitHub's own
> `sort=due_on&direction=asc` returns **undated** milestones **first**, so a repo
> holding one dated and one undated milestone lists the undated one at the top —
> where `/new` puts its pre-selected proposal. Use `sort_by(.due_on // "9999")`
> instead: soonest due first, undated last. Verified 2026-09-09. The Forgejo
> sections below already use this `"9999"` sentinel in `python3`; do not "simplify"
> the GitHub calls back to the API parameter.

Resolve the repo once — `gh api` paths need it:

```bash
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
```

### list

Open milestones, each with its **open issues nested underneath**. Milestones with
zero issues are shown too — that's the point, they're what you want to see right
after `/milestone new`. Issues with *no* milestone are **not** listed; that's what
`/issues` is for.

Two calls, grouped locally — cost is fixed regardless of milestone count, and the
milestone call returns the API's own issue counts to cross-check against:

```bash
gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq 'sort_by(.due_on // "9999") | .[] | [.title, (.due_on // "-"), .open_issues, .closed_issues] | @tsv'

gh issue list --state open --limit 200 --json number,title,milestone \
  --jq '.[] | [(.milestone.title // "-"), .number, .title] | @tsv'
```

Group the second output by milestone title and render a compact tree — title, due
date, `open/closed` counts, then the issues. No preamble. If there are no open
milestones, just say so.

**Truncation guard.** Print the API's `open_issues` count next to the number of
issues actually shown. When they differ, say so *and* say what it can mean — the
issue query hit its 200 limit, **or** pull requests are assigned to that milestone
(`open_issues` counts issues *and* PRs together, while `gh issue list` excludes
PRs). Don't claim truncation when it might be PRs.

### new

```bash
# with a due date — normalize a bare YYYY-MM-DD to MIDDAY UTC, deliberately:
# midnight would let a viewer timezone offset render the previous day.
gh api "repos/$repo/milestones" \
  -f title="<name>" \
  -f due_on="<YYYY-MM-DD>T12:00:00Z"

# no due date given — omit the field entirely, don't pass an empty value
gh api "repos/$repo/milestones" -f title="<name>"
```

Then **read back** and report from the read-back:

```bash
gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq '.[] | select(.title == "<name>") | [.number, .title, (.due_on // "-")] | @tsv'
```

Confirm the `due_on` that came back is the date I asked for. A `422` with
`already_exists` means the title is taken — report the existing milestone and
**stop**; don't retry with a variant name.

### assign

```bash
gh issue edit <issue> --milestone "<name>"
```

Then **read back**:

```bash
gh issue view <issue> --json number,milestone --jq '[.number, (.milestone.title // "-")] | @tsv'
```

If the milestone name doesn't exist, `gh` rejects it — print the open milestones
(the `list` call above) and stop. **No fuzzy matching, no silent creation.**

### triage

Open issues with **no milestone** — the gap `list` deliberately doesn't show.
Two phases: show the whole gap first, then walk it one issue at a time.

Excludes `🧊 parked` (paused on purpose) and `roadmap` (*planned for future work,
not yet scheduled to a milestone* — being un-milestoned is its whole meaning, so
nagging about it is noise). Pull requests are excluded by `gh issue list`.

**Phase 1 — show the gap.** Newest first:

```bash
gh issue list --state open --limit 200 --json number,title,labels,milestone,createdAt \
  --jq 'map(select(.milestone == null))
    | map(select([.labels[].name] | index("🧊 parked") | not))
    | map(select([.labels[].name] | index("roadmap") | not))
    | sort_by(.createdAt) | reverse
    | .[] | [.number, .title, (([.labels[].name] | join(",")) | if . == "" then "-" else . end)] | @tsv'
```

Print the count with the list. **Truncation guard:** the query caps at 200 — if that
many came back, say the list may be incomplete rather than implying it's the whole
gap. If nothing came back, say the gap is empty and **stop — do not enter the walk.**

**Phase 2 — walk it.** Fetch the open milestones **once**, before the walk:

```bash
gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq 'sort_by(.due_on // "9999") | .[] | [.title, (.due_on // "-")] | @tsv'
```

Then, for each issue newest first: show number, title, labels; offer the milestone
titles plus `skip`; on an answer, assign and **read back**:

```bash
gh issue edit <issue> --milestone "<name>"
gh issue view <issue> --json number,milestone --jq '[.number, (.milestone.title // "-")] | @tsv'
```

Report from the read-back, never from the exit code.

Rules for the walk:

- **One issue at a time.** No bulk-assign, no "apply to the rest".
- **`skip` is always offered**, and skipping is silent — don't re-prompt.
- **Never assign without an explicit answer.** No default milestone, no inferring
  from labels or title. Unanswered means skipped.
- **Never create a milestone.** An unknown name → print the open milestones and
  stop; point at `/milestone new`. No fuzzy matching, no silent creation.
- **Stop cleanly** when told to, and report how many were assigned and how many
  remain.

### No forge context

If `gh` isn't on `PATH`, isn't authenticated, or the cwd isn't a GitHub clone, say
which of those it is, point at `gh auth login`, and stop.

My arguments:
$ARGUMENTS

---

If you hit a blocker (a `gh api` field renamed, `due_on` coming back a day off, a
token missing milestone-write permission), find a fix and update this command for
the future.

## Forgejo

Manage milestones in the current Forgejo repo with **`tea`** (login `git-home`).

A milestone is the *when does this ship* axis: repo-scoped, no nesting, one due
date, at most one per issue. It is not an epic (*what work, what scope*) and not a
label (*a filter tag*) — see `docs/glossary.md` in agent-workflow.

### Parse the verb

**Four verbs only** — `list`, `new`, `assign`, `triage`.

- No arguments at all → treat it as `list`.
- A first word that isn't one of the four → print the four usage forms below and
  **stop**. Don't guess the intent, don't fuzzy-match.

```text
/milestone list
/milestone new <name> [due <date>]
/milestone assign <issue> to <name>
/milestone triage
```

### Two rules that apply to every verb

> **Report every write from a read-back — never from the exit code.** A forge CLI
> can exit `0` while silently dropping a field the token lacked permission for —
> that has already happened in this workflow with a label on issue creation. After
> `new` and `assign`, re-read and report what the read-back says.
>
> **`tea api` has no `--jq`** — pipe into `python3 -c`, same idiom as
> `/issues` and `/prs`. `tea` subcommands infer the repo from the cwd, but
> `tea api` needs the explicit `owner/name` path below.

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')   # e.g. freax/hello-forgejo
```

### list

Open milestones, each with its **open issues nested underneath**. Milestones with
zero issues are shown too — that's the point, they're what you want to see right
after `/milestone new`. Issues with *no* milestone are **not** listed; that's what
`/issues` is for.

Two calls, grouped locally — cost is fixed regardless of milestone count, and the
milestone call returns the API's own issue counts to cross-check against:

```bash
tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
for m in sorted(json.load(sys.stdin), key=lambda x: x.get("due_on") or "9999"):
    print(m["title"], m.get("due_on") or "-", m.get("open_issues", 0), m.get("closed_issues", 0), sep="\t")'

tea api --login git-home "repos/$repo/issues?state=open&type=issues&limit=100" | python3 -c '
import sys, json
for i in json.load(sys.stdin):
    m = i.get("milestone") or {}
    print(m.get("title") or "-", i["number"], i["title"], sep="\t")'
```

Group the second output by milestone title and render a compact tree — title, due
date, `open/closed` counts, then the issues. No preamble. If there are no open
milestones, just say so.

**Truncation guard.** Print the API's `open_issues` count next to the number of
issues actually shown. When they differ, say so *and* say what it can mean — the
issue query hit its `limit=100`, **or** pull requests are assigned to that
milestone (`open_issues` counts issues *and* PRs together, while the query above
passes `type=issues`). Don't claim truncation when it might be PRs.

### new

Creation has no built-in duplicate guard (unlike GitHub's `422 already_exists`), so
check first:

```bash
tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
want = "<name>"
for m in json.load(sys.stdin):
    if m["title"] == want:
        print(m["id"], m["title"], m.get("due_on") or "-", sep="\t")
        sys.exit(1)'
```

If that prints a match, report the existing milestone and **stop**; don't retry
with a variant name and don't create it.

```bash
# with a due date — tea parses loose date strings, so a bare YYYY-MM-DD is fine
tea milestones create --login git-home --title "<name>" --deadline "<YYYY-MM-DD>"

# no due date given — omit the flag entirely, don't pass an empty value
tea milestones create --login git-home --title "<name>"
```

Then **read back** and report from the read-back:

```bash
tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
want = "<name>"
for m in json.load(sys.stdin):
    if m["title"] == want:
        print(m["id"], m["title"], m.get("due_on") or "-", sep="\t")'
```

Confirm the deadline that came back is the date I asked for.

### assign

`tea milestones issues add` takes the milestone **name** — use it rather than a raw
`tea api -X PATCH …/issues/<n>`, which would need a name→id lookup first:

```bash
tea milestones issues add --login git-home "<name>" <issue>
```

Then **read back**:

```bash
tea api --login git-home "repos/$repo/issues/<issue>" | python3 -c '
import sys, json
i = json.load(sys.stdin)
m = i.get("milestone") or {}
print(i["number"], m.get("title") or "-", sep="\t")'
```

If the milestone name doesn't exist, print the open milestones (the `list` call
above) and stop. **No fuzzy matching, no silent creation.**

### triage

Open issues with **no milestone** — the gap `list` deliberately doesn't show.
Two phases: show the whole gap first, then walk it one issue at a time.

Excludes `🧊 parked` (paused on purpose) and `roadmap` (*planned for future work,
not yet scheduled to a milestone* — being un-milestoned is its whole meaning, so
nagging about it is noise). Pull requests are excluded by `type=issues`.

**Phase 1 — show the gap.** Newest first:

```bash
tea api --login git-home "repos/$repo/issues?state=open&type=issues&limit=100&sort=created&order=desc" \
  | python3 -c '
import sys,json
rows=[]
for i in json.load(sys.stdin):
    if i.get("milestone"): continue
    labels=[l["name"] for l in i.get("labels") or []]
    if "🧊 parked" in labels or "roadmap" in labels: continue
    rows.append((i["number"], i["title"], ",".join(labels) or "-"))
print(len(rows), "un-milestoned")
for n,t,l in rows: print(n, "|", t, "|", l)'
```

If nothing came back, say the gap is empty and **stop — do not enter the walk.**

**Phase 2 — walk it.** Fetch the open milestones **once**, before the walk:

```bash
tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
for m in sorted(json.load(sys.stdin), key=lambda x: x.get("due_on") or "9999"):
    print(m["title"], m.get("due_on") or "-", sep="\t")'
```

Then, for each issue newest first: show number, title, labels; offer the milestone
titles plus `skip`; on an answer, assign and **read back** using the same mechanics
as `## assign`:

```bash
tea milestones issues add --login git-home "<name>" <issue>
tea api --login git-home "repos/$repo/issues/<issue>" | python3 -c '
import sys, json
i = json.load(sys.stdin)
m = i.get("milestone") or {}
print(i["number"], m.get("title") or "-", sep="\t")'
```

Report from the read-back, never from the exit code.

Rules for the walk:

- **One issue at a time.** No bulk-assign, no "apply to the rest".
- **`skip` is always offered**, and skipping is silent — don't re-prompt.
- **Never assign without an explicit answer.** No default milestone, no inferring
  from labels or title. Unanswered means skipped.
- **Never create a milestone.** An unknown name → print the open milestones and
  stop; point at `/milestone new`. No fuzzy matching, no silent creation.
- **Stop cleanly** when told to, and report how many were assigned and how many
  remain.

### No forge context

If `tea` isn't on `PATH`, there's no `git-home` login, or the remote isn't the
homelab Forgejo (`git.home.freaxnx01.ch`), say which of those it is, point at
`tea login add`, and stop.

My arguments:
$ARGUMENTS

---

`tea`'s milestone flags here were verified from tea's own source
(`cmd/milestones/*.go`, `cmd/flags/issue_pr.go`), not from a live run — `tea` wasn't
installed on the machine where this command was written. If a flag turns out
different (this repo already has precedent: `tea issues create` uses
`--description`/`-d`, not `--body`), find the right one and **update this command**
so the next run doesn't rediscover it.

## Azure DevOps

A milestone on this forge is an **iteration** — see **ADR-012** for why Iteration
Path and not Area Path or a parent Feature.

### Setup

Source the shared helpers once. `azdo.sh` holds the query primitives; do not
inline `az` calls that duplicate them.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
source "$HOME/.claude/scripts/lib/azdo.sh"
resolve_azdo_context || { echo "not an Azure DevOps remote"; exit 1; }
org_url="$(azdo_org_url)"
team="$AZDO_PROJECT Team"     # the default team; a project may have others
```

Needs `az` with the **`azure-devops` extension** and a PAT in
`AZURE_DEVOPS_EXT_PAT` — prefer an `.envrc` direnv already allows, reached with
`direnv exec <dir> …`, since the agent shell fires no direnv hook. If neither a
PAT nor a login is present, say so and stop; **don't** fall through to a bare
`az` call whose auth prompt would hang.

### Parse the verb

**Four verbs only** — `list`, `new`, `assign`, `triage`. Same forms as the other
forges:

```text
/milestone list
/milestone new <name> [due <date>]
/milestone assign <issue> to <name>
/milestone triage
```

No arguments → `list`. A first word that isn't one of the four → print the four
forms and **stop**. Don't guess, don't fuzzy-match.

### Three rules that apply to every verb

> **Iterations nest; GitHub milestones are flat.** `--depth` **defaults to 1**,
> which hides exactly the sprints that hold work items. Always pass it — verified:
> with `Sprint 1\Week A` present, both `--depth 1` *and* the default report
> `Sprint 1` as childless, while `--depth 2` and `3` show `Week A`.
>
> **Match the argument against the leaf `name`, but filter on the full `path`.**
> Two sprints under different parents may share a leaf name; the path is what is
> unique and what `System.IterationPath` stores.
>
> **Report every write from a read-back — never from the exit code.** The same
> rule the GitHub section carries, and it bites harder here: `az` has been
> observed printing an error to stderr while the step still continues. After
> `new` and `assign`, re-read and report what the read-back says.

### list

```bash
azdo_iterations
```

That wraps `az boards iteration project list … --depth 3` and selects
`children[]`, not a top-level `[]` — the response is a single object, so the
obvious query returns nothing at all, with no error. It also tolerates `children`
being `null` on a project with no iterations, which would otherwise make
`length(children)` fail.

Show name, full path and finish date. If there are none, say so plainly.

### new

**Creation is two steps.** The first makes the iteration exist as a project
classification node; the second is what makes it **assignable**. Skipping the
second leaves an iteration that looks created and cannot be used:

```bash
az boards iteration project create --name "<name>" \
  --org "$org_url" --project "$AZDO_PROJECT" --output json --only-show-errors

# The identifier comes from the listing, not from the create response's `id`.
iid=$(az boards iteration project list --org "$org_url" --project "$AZDO_PROJECT" \
        --depth 3 --output json --only-show-errors \
      | python3 -c '
import sys, json
name = sys.argv[1]
for c in (json.load(sys.stdin).get("children") or []):
    if c["name"] == name:
        print(c["identifier"]); break' "<name>")

az boards iteration team add --team "$team" --id "$iid" \
  --org "$org_url" --project "$AZDO_PROJECT" --output none --only-show-errors
```

Verified: before `iteration team add` the new iteration is absent from
`az boards iteration team list`; after it, it appears. Read that list back and
report from it.

A `due <date>` argument maps to the iteration's **finish date**, set with
`--finish-date YYYY-MM-DD` on the create. There is no separate "due" field.

`VS402371` on create means the name is already in use under that parent — report
it as "already exists", not as a failure to create.

### assign

An issue on this forge is a **work item**, and assignment sets its
`System.IterationPath` to the iteration's **full path**:

```bash
az boards work-item update --id <work-item-id> --org "$org_url" \
  --fields "System.IterationPath=$AZDO_PROJECT\\<iteration name>" \
  --output tsv --only-show-errors --query 'fields."System.IterationPath"'
```

Unlike `System.Tags`, this field **replaces** rather than appends — it holds one
value. To unassign, set it back to the project root (`$AZDO_PROJECT` alone).

Resolve `<name>` to a path via `list` first, and if it matches no iteration, say
which names exist rather than creating one implicitly.

### triage

Work items with **no** iteration — the equivalent of "no milestone". An item at
the project root (`System.IterationPath` equal to `$AZDO_PROJECT`) is unassigned:

```bash
rc=0; ids=$(azdo_wiql "SELECT [System.Id] FROM WorkItems
WHERE [System.TeamProject] = @project
  AND [System.AreaPath] UNDER '$AZDO_PROJECT\\$AZDO_REPO'
  AND [System.IterationPath] = '$AZDO_PROJECT'
ORDER BY [System.CreatedDate] DESC") || rc=$?
```

Capture the status rather than calling bare: sourcing `azdo.sh` applies `set -e`,
and `azdo_wiql` returns **2** when the Area Path does not exist (`TF51011`) —
which is a different answer from "nothing is unassigned" and must not be reported
as one. See its header for the full idiom.

Then resolve fields with `azdo_fields "$ids"` and show a compact table. Offer to
assign each to an iteration, one at a time; never bulk-assign without asking.

### No forge context

If `resolve_azdo_context` fails, report the remote and stop — don't guess an org
or project.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
