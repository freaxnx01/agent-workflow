---
description: List and triage roadmap issues — list | promote <n> to <milestone> | defer <n> "<reason>"
argument-hint: list | promote <n> to <milestone> | defer <n> "<reason>"
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## GitHub

Manage roadmap issues in the current GitHub repo with **`gh`**.

### Parse the verb

**Three verbs only** — `list`, `promote`, `defer`.

- No arguments at all → treat it as `list`.
- A first word that isn't one of the three → print the three usage forms below and
  **stop**. Don't guess the intent, don't fuzzy-match.

```text
/roadmap list
/roadmap promote <n> to <milestone>
/roadmap defer <n> "<reason>"
```

### list

List open issues in the current repo that carry the `roadmap` label — newest first.
Show a compact table: number, title, labels, age (relative), author, and latest
`roadmap:` reason.

```bash
gh api graphql \
  -f owner="$(gh repo view --json owner -q .owner.login)" \
  -f name="$(gh repo view --json name -q .name)" \
  -f query='
query($owner:String!,$name:String!){
  repository(owner:$owner,name:$name){
    issues(states:OPEN, first:100, orderBy:{field:CREATED_AT, direction:DESC}){
      nodes{
        number title createdAt
        author{login}
        labels(first:20){nodes{name}}
        comments(last:20){nodes{body}}
      }
    }
  }
}' \
  --jq '.data.repository.issues.nodes
    | map(select([.labels.nodes[].name] | index("roadmap")))
    | .[] | [ .number, .title,
              ([.labels.nodes[].name] | join(",")),
              .createdAt, .author.login,
              ( [ .comments.nodes[].body | select(startswith("roadmap:")) ]
                | last // "—" | split("\n")[0] ) ] | @tsv'
```

If there are none, say the roadmap is empty and stop. This includes repos where the
`roadmap` label doesn't exist at all. Do not create the label.

### promote

`promote <n> to <milestone>` moves an issue from `backlog` to the chosen
milestone in two writes, in this order, each confirmed by read-back:

```bash
# 1) schedule it
gh issue edit <n> --milestone "<milestone>"
gh issue view <n> --json number,milestone --jq '[.number, (.milestone.title // "-")] | @tsv'

# 2) only if scheduling read-back shows the milestone
gh issue edit <n> --remove-label "roadmap"
gh issue view <n> --json number,labels --jq '[.number, ([.labels[].name] | join(","))] | @tsv'
```

If milestone assignment fails (including unknown milestone), print open milestones
and stop. No fuzzy matching, no silent creation:

```bash
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq 'sort_by(.due_on // "9999") | .[] | [.title, (.due_on // "-")] | @tsv'
```

If step 1 read-back does not show the milestone, stop and do not remove the label.
`gh issue edit --milestone` replaces the milestone, so the step-1 read-back
showing `<milestone>` is the proof that the issue left `backlog`.
After both read-backs confirm, offer `/route <n>` (read and follow
`~/.claude/commands/route.md`) rather than running it automatically.

### defer

`defer <n> "<reason>"` appends a roadmap reason comment, **moves the issue to
the `backlog` milestone**, and otherwise keeps labels unchanged. Check
`backlog` first, before any write:

```bash
# 1 — backlog must exist before anything is written
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
if [ "$(gh api "repos/$repo/milestones?state=open&per_page=100" \
        --jq '[.[] | select(.title == "backlog")] | length')" != "1" ]; then
  echo "No open 'backlog' milestone in $repo. Create it with /milestone new backlog, then re-run."
  exit 1
fi

# 2 — reason comment, confirmed from a read-back
gh issue comment <n> --body "roadmap: <reason>"
gh issue view <n> --json comments --jq '.comments | last | .body | split("\n")[0]'

# 3 — roadmap work is unscheduled — move it to backlog
gh issue edit <n> --milestone backlog
gh issue view <n> --json number,milestone --jq '[.number, (.milestone.title // "-")] | @tsv'
```

**A missing `backlog` stops the command before the comment.** Report it,
point at `/milestone new backlog`, and never create it yourself. A closed
`backlog` counts as missing.

**Why `backlog`.** A roadmap issue is *planned for future work, not yet
scheduled*, and every open issue lives in a milestone. `backlog` is where
unscheduled work goes (freaxnx01/ai-instructions#61). `/milestone triage` skips
`roadmap` issues inside `backlog`, so they do not nag. `/roadmap promote` is the
exact inverse: it moves the issue to a named milestone, then removes the label.
`defer` records no `milestone-was:`, because `promote` always names its target.

Report the milestone from the read-back. It must say `backlog`. **Coverage is
partial by construction:** the move only happens when `/roadmap defer` runs.
Labelling an issue `roadmap` by hand in the web UI leaves its milestone in
place.

If no reason argument was provided, ask for one and stop. Never edit the issue body
and never edit a previous comment.

### No forge context

If `gh` isn't on `PATH`, isn't authenticated, or the cwd isn't a GitHub clone, say
which of those it is, point at `gh auth login`, and stop.

My arguments:
$ARGUMENTS

---

If you hit a blocker (missing auth, renamed fields, or a milestone write/read-back
mismatch), find a fix and update this command for the future.

## Forgejo

Manage roadmap issues in the current Forgejo repo with **`tea`** (login
`git-home`).

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`). Resolve `owner/name` from the clone's remote (needed for `tea api`):

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
```

### Parse the verb

**Three verbs only** — `list`, `promote`, `defer`.

- No arguments at all → treat it as `list`.
- A first word that isn't one of the three → print the three usage forms below and
  **stop**. Don't guess the intent, don't fuzzy-match.

```text
/roadmap list
/roadmap promote <n> to <milestone>
/roadmap defer <n> "<reason>"
```

### list

Forgejo has no GraphQL. List open issues newest first, filter roadmap issues
client-side, then read comments per roadmap issue to extract the newest `roadmap:`
reason.

```bash
tea api --login git-home "repos/$repo/issues?state=open&type=issues&limit=100&sort=created&order=desc" \
  | python3 -c '
import sys,json
for i in json.load(sys.stdin):
    labels=[l["name"] for l in i.get("labels") or []]
    if "roadmap" not in labels: continue
    print(i["number"], "|", i["title"], "|", ",".join(labels), "|", i["created_at"], "|", (i.get("user") or {}).get("login","?"))'

tea api --login git-home "repos/$repo/issues/<n>/comments" \
  | python3 -c '
import sys,json
reasons=[c["body"] for c in json.load(sys.stdin) if c.get("body","").startswith("roadmap:")]
print(reasons[-1].split("\n")[0] if reasons else "—")'
```

If there are none, say the roadmap is empty and stop. Do not create the `roadmap`
label.

### promote

Before writing, verify the exact flags with `tea milestones issues add --help` and
`tea issues edit --help`.

`promote <n> to <milestone>` moves an issue from `backlog` to the chosen
milestone in two writes, each with read-back:

```bash
# 1) schedule it
tea milestones issues add --login git-home "<milestone>" <n>
tea api --login git-home "repos/$repo/issues/<n>" | python3 -c '
import sys,json
i=json.load(sys.stdin)
m=i.get("milestone") or {}
print(i["number"], m.get("title") or "-", sep="\t")'

# 2) only if scheduling read-back confirms
tea issues edit <n> --login git-home --remove-labels "roadmap"
tea api --login git-home "repos/$repo/issues/<n>" | python3 -c '
import sys,json
i=json.load(sys.stdin)
print(i["number"], ",".join([l["name"] for l in i.get("labels") or []]), sep="\t")'
```

If milestone assignment fails or read-back still shows no milestone, stop and do not
remove the label. `tea milestones issues add` replaces the milestone, so the
step-1 read-back showing `<milestone>` is the proof that the issue left
`backlog`. For unknown milestone names, print open milestones and stop (no
fuzzy matching, no silent creation):

```bash
tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
for m in sorted(json.load(sys.stdin), key=lambda x: x.get("due_on") or "9999"):
    print(m["title"], m.get("due_on") or "-", sep="\t")'
```

After both read-backs confirm, offer `/route <n>` (read and follow
`~/.claude/commands/route.md`) rather than running it automatically.

### defer

`defer <n> "<reason>"` appends a roadmap reason comment, **moves the issue to
the `backlog` milestone**, and keeps labels unchanged. Check `backlog` first,
before any write:

```bash
# 0 — backlog must exist before anything is written
if ! tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
sys.exit(0 if any(m["title"] == "backlog" for m in json.load(sys.stdin)) else 1)'; then
  echo "No open 'backlog' milestone in $repo. Create it with /milestone new backlog, then re-run."
  exit 1
fi
```

```bash
tea comment <n> "roadmap: <reason>"
tea api --login git-home "repos/$repo/issues/<n>/comments" | python3 -c '
import sys,json
comments=json.load(sys.stdin)
reasons=[c.get("body","") for c in comments if c.get("body","").startswith("roadmap:")]
print(reasons[-1].split("\n")[0] if reasons else "—")'
```

Deferring then **moves the issue to `backlog`** — roadmap work is unscheduled:

```bash
# move it to backlog — `add` replaces any milestone the issue had
tea milestones issues add --login git-home "backlog" <n>
tea api --login git-home "repos/$repo/issues/<n>" | python3 -c '
import sys, json
i = json.load(sys.stdin)
print(i["number"], (i.get("milestone") or {}).get("title") or "-", sep="\t")'
```

**A missing `backlog` stops the command before the comment.** Report it,
point at `/milestone new backlog`, and never create it yourself. A closed
`backlog` counts as missing.

**Why `backlog`.** A roadmap issue is *planned for future work, not yet
scheduled*, and every open issue lives in a milestone. `backlog` is where
unscheduled work goes (freaxnx01/ai-instructions#61). `/milestone triage` skips
`roadmap` issues inside `backlog`, so they do not nag. `/roadmap promote` is the
exact inverse: it moves the issue to a named milestone, then removes the label.
`defer` records no `milestone-was:`, because `promote` always names its target.

Report the milestone from the read-back. It must say `backlog`. **Coverage is
partial by construction:** the move only happens when `/roadmap defer` runs.
Labelling an issue `roadmap` by hand in the web UI leaves its milestone in
place.

Forgejo issues hold one milestone, so `tea milestones issues add` moves the
issue rather than adding a second one. That is taken from tea's source, not
a live run. If the read-back shows the old milestone, fall back to
`tea api --login git-home -X PATCH "repos/$repo/issues/<n>"` with the
`backlog` milestone's id, then fix and update this command.

If no reason argument was provided, ask for one and stop. Never edit the issue body
and never edit a previous comment.

### No forge context

If `tea` isn't on `PATH`, there's no `git-home` login, or the remote isn't the
homelab Forgejo (`git.home.freaxnx01.ch`), say which of those it is, point at
`tea login add`, and stop.

My arguments:
$ARGUMENTS

---

If you hit a blocker (repo not resolvable, `tea` flags differ, or read-back doesn't
match the write), find a fix and update this command for the future.

## Azure DevOps

Roadmap **work items** — the same shape as `/parked`, keyed on the `roadmap` tag.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
source "$HOME/.claude/scripts/lib/azdo.sh"
resolve_azdo_context || { echo "not an Azure DevOps remote"; exit 1; }
```

### Tags on this forge

**The tags here are plain `roadmap` and `parked`.** Azure DevOps rejects
emoji in tag names (`TF401407`), so the GitHub and Forgejo spelling cannot exist
here. See **ADR-016**; this is a per-forge difference, not a typo to "fix".

**Write tags with `azdo_set_tags`, never with `--fields`.**
`az boards work-item update --fields "System.Tags=..."` **appends** — successive
calls accumulate — and an empty value is a silent **no-op**, so removing a tag is
impossible through it. `azdo_set_tags` does a json-patch `replace`, which both
shrinks and clears.

Tags come back separated by a **semicolon *and* a space**, not a bare `;`.
Splitting on `;` alone leaves leading whitespace on every tag after the first.

### list

```bash
rc=0; ids=$(azdo_wiql "SELECT [System.Id] FROM WorkItems
WHERE [System.TeamProject] = @project
  AND [System.AreaPath] UNDER '$AZDO_PROJECT\\$AZDO_REPO'
  AND [System.State] NOT IN ($(azdo_closed_states))
  AND [System.Tags] CONTAINS 'roadmap'
ORDER BY [System.CreatedDate] DESC" | tr '\n' ',' | sed 's/,$//') || rc=$?
```

### promote `<n>` to `<milestone>`

Drop the `roadmap` tag with `azdo_set_tags` — reading the current tags and
writing back the remainder, as `/parked`'s unpark does — then set the iteration:

```bash
az boards work-item update --id "<n>" --org "$(azdo_org_url)" \
  --fields "System.IterationPath=$AZDO_PROJECT\\<iteration>" \
  --output tsv --only-show-errors --query 'fields."System.IterationPath"'
```

`System.IterationPath` **replaces** rather than appends — unlike `System.Tags`,
it holds a single value — so `--fields` is correct for it. Resolve `<milestone>`
against `azdo_iterations` first; if it matches nothing, say which exist rather
than creating one implicitly.

### defer `<n>` "<reason>"

Add `roadmap` to the existing tags via `azdo_set_tags`, post the reason with
`--discussion`, then move the item to the project **root iteration**, this
forge's `backlog`:

```bash
az boards work-item update --id "<n>" --org "$(azdo_org_url)" \
  --fields "System.IterationPath=$AZDO_PROJECT" \
  --output tsv --only-show-errors --query 'fields."System.IterationPath"'
```

Report from that read-back. The root always exists, so there is no
missing-backlog case on this forge.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
