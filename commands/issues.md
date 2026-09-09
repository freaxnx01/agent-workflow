---
description: List open issues that are not WIP (no open PR), not parked, and not roadmap, newest first — optionally scoped to one milestone
argument-hint: "[<milestone> | pick]"
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## Argument — optional milestone scope

The argument is **optional** and chooses which issues to list:

| Argument | Meaning |
| --- | --- |
| *(none)* | Every in-scope issue, repo-wide. The default, unchanged. |
| `pick` | List the open milestones with their open counts, ask which to list, then scope to the answer. |
| `<name>` | Scope to one milestone — exact title, else a **unique** case-insensitive substring. |

Resolving `<name>`:

- An exact title match wins outright.
- Otherwise match open milestones whose title *contains* the argument,
  case-insensitively. Exactly one match → use it, and **say which title you
  resolved to** so a surprising match is visible. Zero matches, or more than
  one → print the open milestones and ask which, i.e. fall into `pick`.
- **Never** fall back to "all issues" when a name was given but did not
  resolve, and **never** create a milestone. Ask instead.

> Substring resolution here does **not** contradict `/milestone`'s "no fuzzy
> matching" rule. That rule protects *writes* — assigning or creating against a
> wrongly resolved name corrupts data. `/issues` only reads, an ambiguous argument
> never resolves silently, and every row prints its milestone, so a wrong guess
> is visible immediately rather than persisted.

**The milestones lookup is not optional on GitHub, even for an exact title.**
`/triage` filters with `gh issue list --milestone "<title>"` and so can skip the
lookup when the title is already exact. `/issues` cannot: it runs a GraphQL query
(it needs the timeline to drop WIP issues) and GraphQL filters by milestone
**number**, not title. There is no path from a user-typed title to a
`milestoneNumber` without listing the milestones first. Run the lookup on every
scoped invocation.

Whenever a milestone **is** in scope, say which one you scoped to.

## GitHub

List open issues in the current repo that are **not work-in-progress** — i.e. have no **open** PR — **not parked** (no `🧊 parked` label), and **not roadmap** (no `roadmap` label) — **newest first**. Issues whose only linked PR is already merged still count as not-WIP and are shown. Parked issues are deliberately deferred; list them with `/parked`. Roadmap issues are planned for a future milestone rather than current work; list them with `/roadmap`.

For `pick`, or to resolve any `<name>` (see above — required for an exact title
too), list the open milestones first. The **number** in the first column is what
the query below filters on:

```bash
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq 'sort_by(.due_on // "9999") | .[] | [.number, .title, (.due_on // "-"), .open_issues] | @tsv'
```

`gh issue list` can't see PR links, so query the timeline via GraphQL and drop any issue that has an open linked PR (a `Closes #`/cross-reference or a development-linked PR still in flight), then drop any issue carrying the `🧊 parked` label, then any carrying the `roadmap` label.

Add `-f ms=<number>` when a milestone is in scope; **omit the flag entirely** when
it is not (see the trap below — an empty value is not the same as no value):

```bash
gh api graphql \
  -f owner="$(gh repo view --json owner -q .owner.login)" \
  -f name="$(gh repo view --json name -q .name)" \
  -f ms="<resolved milestone number>" \
  -f query='
query($owner:String!,$name:String!,$ms:String){
  repository(owner:$owner,name:$name){
    issues(states:OPEN, first:100, filterBy:{milestoneNumber:$ms}, orderBy:{field:CREATED_AT, direction:DESC}){
      totalCount
      nodes{
        number title createdAt
        author{login}
        milestone{title dueOn}
        labels(first:20){nodes{name}}
        timelineItems(itemTypes:[CROSS_REFERENCED_EVENT,CONNECTED_EVENT], first:50){
          nodes{
            ... on CrossReferencedEvent{source{... on PullRequest{state}}}
            ... on ConnectedEvent{subject{... on PullRequest{state}}}
          }
        }
      }
    }
  }
}' \
  --jq '.data.repository.issues
    | "prefilter_total=\(.totalCount) fetched=\(.nodes | length)",
      (.nodes
        | map(select([.timelineItems.nodes[] | (.source // .subject) | .state] | map(select(. == "OPEN")) | length == 0))
        | map(select([.labels.nodes[].name] | index("🧊 parked") | not))
        | map(select([.labels.nodes[].name] | index("roadmap") | not))
        | .[] | {number, title, milestone: (.milestone.title // "-"), due: ((.milestone.dueOn // "-") | .[0:10]), labels: [.labels.nodes[].name], age: .createdAt, author: .author.login})'
```

`filterBy` filters **server-side**, so the call stays one request and the `first:100`
cap applies to the scoped set — do not fetch everything and discard non-matching
milestones in jq instead.

Three traps, all verified live against a repo with two open milestones:

- **`-f ms=` with an empty value returns zero issues, not all of them.** A null
  `$ms` (flag omitted) returns the full unscoped set — identical to having no
  `filterBy` at all — but an empty *string* silently matches nothing. So an unset
  shell variable interpolated into the flag produces a confident "no issues"
  rather than an error. Omit the flag; never pass it empty.
- **`filterBy:{milestone:}` is not an alias for the number.** For the same value
  that `milestoneNumber:"7"` returned 7 issues for, the older `milestone:` field
  returned **0**. Use `milestoneNumber:` only.
- **The due date is `.milestone.dueOn`** (camelCase), unlike Forgejo's `due_on`,
  and it is **null** for a milestone with no due date — hence the `// "-"`. Labels
  here are `.labels.nodes[].name` (the GraphQL shape), **not** `[.labels[].name]`,
  which is what `gh issue list --json labels` yields in `/triage`.

**Truncation guard:** `prefilter_total` is the server-side count *before* jq drops
WIP/parked/roadmap, so the visible count is twice-removed from it. A gap between
the two is normal. But if `fetched` is 100, say the list may be incomplete rather
than implying it is the whole set.

Show a compact table — number, title, **milestone + due date**, labels, age (relative), author. Render an issue with no milestone as `no milestone` rather than a blank column. No preamble. If there are none, just say so — and when a milestone was in scope, say which one, so "none" doesn't read as "nothing anywhere".

My arguments:
$ARGUMENTS

## Forgejo

List open issues in the current Forgejo repo that are **not work-in-progress** —
i.e. have no **open** linked PR — **not parked** (no `🧊 parked` label), and **not
roadmap** (no `roadmap` label) — **newest first**. Issues whose only linked PR is
already merged/closed still count as not-WIP and are shown. Parked issues are
deliberately deferred; list them with `/parked`. Roadmap issues are planned for
a future milestone rather than current work; list them with `/roadmap`.

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`). Prefer `tea` subcommands; use `tea api [-X METHOD] [-f k=v | -d JSON]
<path>` for anything tea lacks. The repo resolves from the cwd git remote — pass
`--repo owner/name` when outside a clone. Forgejo has **no GraphQL**, so PR↔issue
links are derived from REST.

Resolve `owner/name` from the clone's remote (needed for `tea api` paths):

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')   # e.g. freax/hello-forgejo
```

> `tea` infers the repo from the cwd for its subcommands, but `tea api` needs the
> explicit path above. Note `tea issues create` uses `--description`/`-d` (not
> `--body`); comments are `tea comment <index> "body"`.

For `pick`, or to resolve an ambiguous `<name>`, list the open milestones first —
here the **title** is what the check below compares, so no number is needed:

```bash
tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
for m in sorted(json.load(sys.stdin), key=lambda x: x.get("due_on") or "9999"):
    print(m["title"], m.get("due_on") or "-", m.get("open_issues", 0), sep="\t")'
```

### Approach

`tea issues list` can't tell you which issues have an open PR. Forgejo has no
GraphQL timeline, so derive WIP from the open PRs themselves: an issue is WIP if an
**open** PR closes it (`closes/fixes/resolves #N` in the PR title or body, or a
same-named `issue-N-*` branch). Then drop parked and roadmap issues, and any issue
outside the scoped milestone.

Set `want` in the second snippet below to the resolved milestone **title** when a
milestone is in scope; **leave it the empty string** when none is — an empty
`want` is what makes the check a no-op:

```bash
# repo resolved as above
# 1) issue numbers referenced by OPEN pull requests
tea api --login git-home "repos/$repo/pulls?state=open&limit=50&type=pulls" \
  | python3 -c '
import sys,json,re
prs=json.load(sys.stdin)
wip=set()
pat=re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", re.I)
for p in prs:
    for n in pat.findall((p.get("title") or "")+" "+(p.get("body") or "")): wip.add(int(n))
    m=re.match(r"issue-(\d+)", p.get("head",{}).get("ref","") or "")
    if m: wip.add(int(m.group(1)))
print(" ".join(map(str,sorted(wip))))' > /tmp/fj_wip.txt
# 2) open issues, newest first, minus WIP, minus parked, minus roadmap
tea api --login git-home "repos/$repo/issues?state=open&type=issues&limit=100&sort=created&order=desc" \
  | python3 -c '
import sys,json
want = ""                             # <- resolved milestone title when scoped, else ""
wip=set(int(x) for x in open("/tmp/fj_wip.txt").read().split())
for i in json.load(sys.stdin):
    labels=[l["name"] for l in i.get("labels") or []]
    if i["number"] in wip or "🧊 parked" in labels or "roadmap" in labels: continue
    m=i.get("milestone") or {}
    if want and (m.get("title") or "") != want: continue
    print(i["number"], "|", i["title"], "|", m.get("title") or "-", "|",
          (m.get("due_on") or "-")[:10], "|", ",".join(labels) or "-", "|",
          i["created_at"], "|", (i.get("user") or {}).get("login","?"))'
```

The Forgejo issues API also accepts a `&milestones=<name>` query parameter,
which would filter server-side like GitHub's `filterBy`. It is **not used here
because it has never been verified against a live `tea`** — switch to it once
someone confirms it, and delete the client-side check.

Forgejo spells the due date `due_on` (snake_case), unlike GitHub's `dueOn`. The
`limit=100` caps the fetch *before* the skips, so if 100 came back pre-filter, say
the list may be incomplete.

Show a compact table — number, title, **milestone + due date**, labels, age (relative), author. Render an issue with no milestone as `no milestone` rather than a blank column. No preamble. If there are none, just say so — and when a milestone was in scope, say which one, so "none" doesn't read as "nothing anywhere".

My arguments:
$ARGUMENTS

### Forgejo blockers

If you hit a blocker (repo not resolvable, `tea` login missing, PR-link regex
misses a convention this repo uses), find a fix and update this command for the
future.

## Azure DevOps

List open **work items** in the current project that are **not work-in-progress** —
i.e. have no **active** pull request linked — **not parked** (no `🧊 parked` tag),
and **not roadmap** (no `roadmap` tag) — **newest first**. Work items whose only
linked PR is already `completed`/`abandoned` still count as not-WIP and are shown.

### Two structural differences to hold on to

Neither has an equivalent on GitHub or Forgejo, and both change the query shape:

1. **Work items are project-scoped, not repo-scoped.** A repo does not own work
   items, so "this repo's issues" has to be *chosen* rather than read off the
   remote. This command scopes by **Area Path** matching the repo name (see the
   guard below — the failure mode is silence, not an error).
2. **There is no `az boards work-item list`.** The verbs are `create`, `delete`,
   `show`, `update` only. Every listing goes through **WIQL** via
   `az boards query --wiql`.

### Azure DevOps access

Needs `az` with the **`azure-devops` extension** (`az extension add --name
azure-devops`). Authenticate by exporting a PAT as `AZURE_DEVOPS_EXT_PAT` —
prefer an `.envrc` that direnv already allows over an interactive `az devops
login`, and remember the agent shell does not fire direnv hooks, so reach it with
`direnv exec <dir> …`. If neither a PAT nor a login is present, say so and point
at the PAT env var; **don't** fall through to a bare `az` call whose auth prompt
would hang.

`az devops invoke` is the arbitrary-REST escape hatch here, the counterpart of
`gh api` and `tea api`. Its own help warns the response shape is not fixed, so
always pass `--output json` and parse defensively.

Resolve org/project/repo from the remote with the shared helper — it handles the
`dev.azure.com` https form, the `<org>@` variant, the scp-style and `ssh://`
`v3/` forms, and legacy `<org>.visualstudio.com`:

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
resolve_azdo_context || { echo "not an Azure DevOps remote"; exit 1; }
org_url="https://dev.azure.com/$AZDO_ORG"
# Legacy remotes: if the remote host ends in .visualstudio.com and the call above
# 404s, retry with org_url="https://$AZDO_ORG.visualstudio.com".
echo "$AZDO_ORG / $AZDO_PROJECT / $AZDO_REPO"
```

> These are shell **variables**, deliberately, not a space-separated echo like
> `detect_forge`'s: an ADO project name may legitimately contain spaces. Quote
> every use of `"$AZDO_PROJECT"`.

### Step 1 — read the states and types from the project, don't assume them

**Do not hardcode a list of closed states.** State names are set by the project's
process template, so any fixed list is wrong somewhere: Basic is `To Do / Doing /
Done`, Agile is `New / Active / Resolved / Closed`, Scrum is `New / Approved /
Committed / Done / Removed`. Read the project's own metadata instead and use each
state's **`category`** — the categories are template-independent, and `Completed`
and `Removed` are the ones that mean "not open":

```bash
az devops invoke --org "$org_url" --area wit --resource workitemtypes \
  --route-parameters project="$AZDO_PROJECT" \
  --api-version 7.1 --output json \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
closed = sorted({s["name"] for t in d.get("value", [])
                 for s in t.get("states", [])
                 if s.get("category") in ("Completed", "Removed")})
print("|".join(closed))'
```

The same call also enumerates the valid **work item types**, which is what
`/new` needs on this forge — one lookup answers both. Cache it per invocation
rather than repeating it.

### Step 2 — WIQL for the candidate work items

Interpolate the closed-state list from step 1. `@project` resolves against
`--project`, so the team-project clause needs no quoting of its own:

```bash
az boards query --org "$org_url" --project "$AZDO_PROJECT" --output json --wiql "
SELECT [System.Id], [System.Title], [System.State], [System.Tags],
       [System.IterationPath], [System.CreatedDate], [System.CreatedBy]
FROM WorkItems
WHERE [System.TeamProject] = @project
  AND [System.AreaPath] UNDER '$AZDO_PROJECT\\$AZDO_REPO'
  AND [System.State] NOT IN ('Closed', 'Done', 'Removed')
  AND [System.Tags] NOT CONTAINS 'parked'
  AND [System.Tags] NOT CONTAINS 'roadmap'
ORDER BY [System.CreatedDate] DESC"
```

Two notes on the tag clauses:

- They match the bare word **`parked`**, not the full `🧊 parked`, on purpose:
  it keeps a non-ASCII literal out of a query string that crosses `az`, the REST
  layer and WIQL's own parser. The cost is that a tag merely *containing*
  "parked" would also be dropped — acceptable, since the convention is exactly
  one parked tag.
- `NOT CONTAINS` is a single WIQL operator; it is not spelled `NOT ... CONTAINS`.

### Step 3 — the Area Path guard (do not skip this)

Scoping by Area Path fails **silently**: a project that does not mirror repo names
into its area tree returns zero rows, which is indistinguishable from "no open
issues". So when step 2 comes back empty, check whether the area even exists
before reporting nothing:

```bash
az boards area project list --org "$org_url" --project "$AZDO_PROJECT" \
  --depth 3 --output json --query '[].name'
```

`--depth` **defaults to 1**, so nested areas are invisible without it — pass it.

If no area matches `$AZDO_REPO`, say exactly that: *"no Area Path matching
`<repo>` in project `<project>` — this project may not scope work items by repo."*
Then **ask** whether to re-run project-wide. **Never widen automatically** — in a
multi-repo project that silently presents other repos' work as this repo's.

### Step 4 — drop the WIP ones

Unlike Forgejo, links here are **first-class**, so this is a lookup rather than a
regex over PR text — the one place ADO is better than both other forges. Iterate
the **active PRs** (few) and collect their linked work items, rather than asking
each work item for its PRs (many):

```bash
for pr in $(az repos pr list --org "$org_url" --project "$AZDO_PROJECT" \
              --repository "$AZDO_REPO" --status active \
              --output tsv --query '[].pullRequestId'); do
  az repos pr work-item list --org "$org_url" --id "$pr" \
    --output tsv --query '[].id'
done | sort -u
```

`--status` takes **`active` / `completed` / `abandoned` / `all`** — there is no
`open`. "Not WIP" means no **`active`** PR; a `completed` or `abandoned` one does
not make a work item WIP. Drop any work item whose id appears in that list.

An **empty result here is a legitimate answer** — it means no active PRs, so
nothing is WIP and every candidate work item survives. Don't read it as a failed
lookup. It is, however, indistinguishable from a wrong `--query` path (see the
epistemic note at the end of this section), so if you expected WIP items and got
none, verify the shape before trusting the empty set.

### Step 5 — the milestone argument maps to Iteration Path

A milestone on this forge is an **iteration** (see ADR-011 for why Iteration Path
and not Area Path or a parent Feature). When the argument resolves to one, add a
clause to the step-2 query:

```bash
az boards iteration project list --org "$org_url" --project "$AZDO_PROJECT" \
  --depth 3 --output json --query '[].{name:name,path:path}'
```

```text
AND [System.IterationPath] UNDER '<resolved iteration path>'
```

`--depth` defaults to 1 here too, and **iterations nest** — unlike a flat GitHub
milestone — so a depth-1 listing hides the sprints that actually hold work items.
Match the argument against the leaf **name**, but filter on the full **path**.

Show a compact table — id, title, **iteration + finish date**, tags, age (relative), author. Render a work item with no iteration as `no milestone` rather than a blank column, so the column reads the same as on the other forges. No preamble. If there are none, just say so — and when an iteration was in scope, say which one, so "none" doesn't read as "nothing anywhere".

My arguments:
$ARGUMENTS

### Azure DevOps blockers

**Epistemic status: the command names and flags above were verified against `az`
2.87.0 with azure-devops 1.0.4 by running `--help` on every one of them — but the
JSON field names, the `workitemtypes` response shape, the WIQL clauses and every
`--query` path were *not* run against a live organization**, because none was
reachable from the machine where this was written.

`--query` deserves singling out, because its failure is quiet. It is a global `az`
argument, so it always *exists* — but a JMESPath like `[].pullRequestId` assumes
the response is a **top-level array**, and if a command instead wraps its results
in an object, the expression yields nothing and the step reports an empty result
rather than an error. If any `--query` here comes back empty where the web UI shows
data, re-run the same call with plain `--output json`, look at the real shape, and
fix the path — that is the most likely thing on this page to be wrong. That is the same status the `tea` sections carry,
and this repo has already been bitten by it once (`tea issues create` takes
`--description`, not `--body`).

So: if a field name, an `az devops invoke` resource, or a WIQL operator turns out
different in practice, **find the working form and update this command** — and
drop the paragraph above once a live run has confirmed the whole path.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
