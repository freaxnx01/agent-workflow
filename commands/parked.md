---
description: List and triage parked issues — list | unpark <n> | repark <n> "<reason>" | review
argument-hint: list | unpark <n> | repark <n> "<reason>" | review
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## GitHub

Manage parked issues in the current GitHub repo with **`gh`**.

### Parse the verb

**Four verbs only** — `list`, `unpark`, `repark`, `review`.

- No arguments at all → treat it as `list`.
- A first word that isn't one of the four → print the four usage forms below and
  **stop**. Don't guess the intent, don't fuzzy-match.

```text
/parked list
/parked unpark <n>
/parked repark <n> "<reason>"
/parked review
```

### list

List open issues in the current repo that are **parked** — i.e. carry the
`parked` label — **newest first**. Keep the existing table shape and add a
`reason` column from the most recent `parked:` comment.

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
        comments(last:100){nodes{body}}
      }
    }
  }
}' \
  --jq '.data.repository.issues.nodes
    | map(select([.labels.nodes[].name] | index("parked")))
    | .[] | [ .number, .title,
              ([.labels.nodes[].name] | join(",")),
              .createdAt, .author.login,
              ( [ .comments.nodes[] | (.body // "") | select(startswith("parked:")) ]
                | last // "—" | split("\n")[0] ) ] | @tsv'
```

Show a compact table — number, title, labels, age (relative), author, reason.
No preamble. If there are none, just say so.

### unpark

Remove only the `parked` label, then confirm from a read-back:

```bash
gh issue edit <n> --remove-label "parked"
gh issue view <n> --json number,labels --jq '[.number, ([.labels[].name] | join(","))] | @tsv'
```

Report from the read-back. If `parked` is still present, say the removal
failed and stop — do not continue to routing.

**Then offer the recorded milestone back.** `repark` writes a `milestone-was:` line
into its reason comment. Read it and **ask** before assigning — never restore
silently:

```bash
gh issue view <n> --json comments \
  --jq '[.comments[] | (.body // "") | select(startswith("parked:"))] | last // ""
        | split("\n") | map(select(startswith("milestone-was:"))) | first // ""
        | sub("^milestone-was:\\s*"; "")'
```

- **Empty output** — nothing was recorded (parked by hand, or `repark` found it
  already in `backlog`). Say nothing and carry on to routing — in particular,
  **don't say where the issue sits**: a hand-parked issue keeps whatever
  milestone it had, a legacy one may have none, and nothing here read it back.
- **A still-open milestone** — offer to restore it (`gh issue edit <n> -m "<name>"`),
  then read back and report from the read-back. On a decline, leave the milestone
  as it is — after a `repark` round trip that is `backlog`.
- **A closed or deleted milestone** — say so and leave the milestone as it is. Do
  not recreate it and do not substitute another.

If the issue also has `needs-enrichment`, say so before routing. Then delegate:
read and follow `~/.claude/commands/route.md` (i.e. run `/route <n>`).
`/parked` must not reimplement route logic.

### repark

`repark` keeps labels as-is, appends a fresh reason comment, and **moves the
issue to the `backlog` milestone**. It records the milestone it moved away from
in that comment, so `unpark` can offer it back. Check `backlog` and capture
the current milestone **before** writing anything:

```bash
# 1 — backlog must exist before anything is written
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
rc=0
found=$(gh api "repos/$repo/milestones?state=open&per_page=100" \
        --jq '[.[] | select(.title == "backlog")] | length') || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "Could not read the milestones of $repo (gh exit $rc). That is not a missing 'backlog' — fix the read, then re-run."
  exit 1
fi
if [ "$found" != "1" ]; then
  echo "No open 'backlog' milestone in $repo. Create it with /milestone new backlog, then re-run."
  exit 1
fi

# 2 — capture the current milestone (empty string when there is none)
was=$(gh issue view <n> --json milestone --jq '.milestone.title // ""')

# 3 — reason comment; milestone-was only for a real milestone other than backlog
if [ -n "$was" ] && [ "$was" != "backlog" ]; then
  gh issue comment <n> --body "parked: <reason>
milestone-was: $was"
else
  gh issue comment <n> --body "parked: <reason>"
fi
```

**A missing `backlog` stops the command before the comment.** Report it,
point at `/milestone new backlog`, and never create it yourself. A closed
`backlog` counts as missing.

**A failed read is not a missing milestone.** `gh`'s status is captured
separately, because an expired token, a network error or a rate limit all make
the substitution empty — the same as a repo with no `backlog`. Both stop before
any write, but only one of them is fixed by creating a milestone, so they must
not be reported as the same thing.

`milestone-was:` sits on the **second** line deliberately: every reason read-back
here takes `split("\n")[0]`, so `/parked list` and the confirmation below keep
showing the reason alone, never the bookkeeping line. It is left out when the
issue was already in `backlog`, so `unpark` never offers `backlog` back.

Then read back the newest comment whose body starts with `parked:` and confirm
from it, never from the exit code:

```bash
gh issue view <n> --json comments \
  --jq '[.comments[] | (.body // "") | select(startswith("parked:"))] | last // "—" | split("\n")[0]'
```

Only then move it:

```bash
# 4 — move it to backlog, now that the previous name is recorded in the comment
gh issue edit <n> --milestone backlog
gh issue view <n> --json number,milestone --jq '[.number, (.milestone.title // "-")] | @tsv'
```

**Why `backlog`.** A parked issue is paused on purpose and not scheduled, and
every open issue lives in a milestone. `backlog` is where unscheduled work goes
(freaxnx01/ai-instructions#61). `/milestone triage` skips `parked` issues inside
`backlog`, so they do not nag. `unpark` offers the recorded milestone back, so
the round trip is recoverable, but only when `repark` is what moved it.

Report the milestone from the read-back. It must say `backlog`. **Coverage is
partial by construction:** the move only happens when `/parked repark` runs.
Labelling an issue by hand in the web UI leaves its milestone in place.

If no reason argument was provided, ask for one and stop. Never edit the issue
body and never edit a previous comment.

### review

Walk the parked issues from `list`, newest first, one at a time. For each issue:
show number, title, labels, age, and current reason; ask *still valid to stay
parked?* with options `unpark` / `repark` / `skip`.

- One issue at a time. No bulk actions.
- Never act without an explicit answer. Unanswered means skipped.
- `skip` is silent and never re-prompts.
- Stop cleanly when told to.
- **`unpark` chosen mid-walk is deferred**, not run immediately — running
  `/route` per issue would derail the one-at-a-time walk with a heavy
  interactive analysis. Record the issue number and continue the walk; after the
  walk completes, run `/route <n>` for each unparked issue number and list
  those numbers in the tally.
- Report a final tally: unparked, reparked, skipped, remaining.

My arguments:
$ARGUMENTS

## Forgejo

Manage parked issues in the current Forgejo repo with **`tea`** (login
`git-home`).

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`). Resolve `owner/name` from the clone's remote (needed for `tea api`):

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
```

### Parse the verb

**Four verbs only** — `list`, `unpark`, `repark`, `review`.

- No arguments at all → treat it as `list`.
- A first word that isn't one of the four → print the four usage forms below and
  **stop**. Don't guess the intent, don't fuzzy-match.

```text
/parked list
/parked unpark <n>
/parked repark <n> "<reason>"
/parked review
```

### list

Forgejo has no GraphQL, so we can't get everything in one query. List parked
issues first, then fetch comments for each parked issue to extract the newest
`parked:` reason.

```bash
# open PRs → set of referenced issue numbers (for the WIP annotation)
tea api --login git-home "repos/$repo/pulls?state=open&limit=50&type=pulls" \
  | python3 -c '
import sys,json,re
pat=re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", re.I)
wip=set()
for p in json.load(sys.stdin):
    for n in pat.findall((p.get("title") or "")+" "+(p.get("body") or "")): wip.add(int(n))
open("/tmp/fj_wip.txt","w").write(" ".join(map(str,sorted(wip))))'

# parked issues, newest first — filter client-side (the labels= query param breaks
# on a label name containing a space + emoji; it isn't URL-encoded by tea api)
tea api --login git-home "repos/$repo/issues?state=open&type=issues&limit=100&sort=created&order=desc" \
  | python3 -c '
import sys,json
wip=set(int(x) for x in open("/tmp/fj_wip.txt").read().split())
for i in json.load(sys.stdin):
    labels=[l["name"] for l in i.get("labels") or []]
    if "parked" not in labels: continue
    print(i["number"],"|",i["title"],"|",",".join(labels),"|",i["created_at"],"|",(i.get("user") or {}).get("login","?"),"|","WIP" if i["number"] in wip else "")'

# then, per parked issue number, its most recent reason
tea api --login git-home "repos/$repo/issues/<n>/comments" \
  | python3 -c '
import sys,json
reasons=[c["body"] for c in json.load(sys.stdin) if (c.get("body") or "").startswith("parked:")]
print(reasons[-1].split("\n")[0] if reasons else "—")'
```

> Client-side filtering is used deliberately: `labels=parked` in the query string
> isn't URL-encoded by `tea api`, so the space+emoji breaks the request.

Show a compact table — number, title, labels, age (relative), author, open-PR
note, reason. No preamble. If there are none, just say so.

### unpark

Remove only the `parked` label, then confirm from a read-back:

```bash
tea issues edit <n> --login git-home --remove-labels "parked"

tea api --login git-home "repos/$repo/issues/<n>" | python3 -c '
import sys,json
i=json.load(sys.stdin)
print(i["number"], ",".join([l["name"] for l in i.get("labels") or []]), sep="\t")'
```

Report from the read-back. If `parked` is still present, say removal failed
and stop — do not continue to routing.

**Then offer the recorded milestone back** — same rules as the GitHub section: ask
first, open milestones only, never recreate a closed one.

```bash
tea api --login git-home "repos/$repo/issues/<n>/comments" | python3 -c '
import sys, json
bodies = [(c.get("body") or "") for c in json.load(sys.stdin)
          if (c.get("body") or "").startswith("parked:")]
lines = bodies[-1].split("\n") if bodies else []
was = [l for l in lines if l.startswith("milestone-was:")]
print(was[-1].split(":", 1)[1].strip() if was else "")'
```

Restore with `tea milestones issues add --login git-home "<name>" <n>`, then read
back. On a decline or a closed milestone, leave the milestone as it is — after a
`repark` round trip that is `backlog`. On an empty record, say nothing about the
milestone: it was never read. Same rules as the GitHub section.

If the issue also has `needs-enrichment`, say so before routing. Then delegate:
read and follow `~/.claude/commands/route.md` (i.e. run `/route <n>`).
`/parked` must not reimplement route logic.

### repark

`repark` keeps labels as-is, appends a fresh reason comment, and **moves the
issue to the `backlog` milestone** — recording the milestone it moved away from
so `unpark` can offer it back. Check `backlog` and capture the current milestone
**before** writing anything:

```bash
# 0 — backlog must exist before anything is written
rc=0
found=$(tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
print("yes" if any(m.get("title") == "backlog" for m in json.load(sys.stdin)) else "no")') || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "Could not read the milestones of $repo (exit $rc). That is not a missing 'backlog' — fix the read, then re-run."
  exit 1
fi
if [ "$found" != "yes" ]; then
  echo "No open 'backlog' milestone in $repo. Create it with /milestone new backlog, then re-run."
  exit 1
fi

# 1 — capture the current milestone (empty when there is none)
was=$(tea api --login git-home "repos/$repo/issues/<n>" | python3 -c '
import sys, json
m = json.load(sys.stdin).get("milestone") or {}
print(m.get("title") or "")')

# 2 — reason comment; milestone-was only for a real milestone other than backlog
if [ -n "$was" ] && [ "$was" != "backlog" ]; then
  tea comment <n> "parked: <reason>
milestone-was: $was"
else
  tea comment <n> "parked: <reason>"
fi
```

`milestone-was:` sits on the **second** line deliberately — every reason read-back
here takes the first line only, so it stays invisible to `/parked list`.

Then read back the newest comment whose body starts with `parked:` and confirm
from it, never from the exit code:

```bash
tea api --login git-home "repos/$repo/issues/<n>/comments" | python3 -c '
import sys,json
comments=json.load(sys.stdin)
reasons=[(c.get("body") or "") for c in comments if (c.get("body") or "").startswith("parked:")]
print(reasons[-1].split("\n")[0] if reasons else "—")'
```

Only then move it:

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

**A failed read is not a missing milestone.** The read's status is captured
separately, because an unreachable host or an expired token would otherwise
report "no `backlog`" for a milestone that exists. Both stop before any write,
but only one of them is fixed by creating a milestone.

**Why `backlog`.** A parked issue is paused on purpose and not scheduled, and
every open issue lives in a milestone. `backlog` is where unscheduled work goes
(freaxnx01/ai-instructions#61). `/milestone triage` skips `parked` issues inside
`backlog`, so they do not nag. `unpark` offers the recorded milestone back, so
the round trip is recoverable, but only when `repark` is what moved it.

Report the milestone from the read-back. It must say `backlog`. **Coverage is
partial by construction:** the move only happens when `/parked repark` runs.
Labelling an issue by hand in the web UI leaves its milestone in place.

Forgejo issues hold one milestone, so `tea milestones issues add` moves the
issue rather than adding a second one. That is taken from tea's source, not
a live run. If the read-back shows the old milestone, fall back to
`tea api --login git-home -X PATCH "repos/$repo/issues/<n>"` with the
`backlog` milestone's id, then fix and update this command.

If no reason argument was provided, ask for one and stop. Never edit the issue
body and never edit a previous comment.

### review

Walk the parked issues from `list`, newest first, one at a time. For each issue:
show number, title, labels, age, open-PR note, and current reason; ask *still
valid to stay parked?* with options `unpark` / `repark` / `skip`.

- One issue at a time. No bulk actions.
- Never act without an explicit answer. Unanswered means skipped.
- `skip` is silent and never re-prompts.
- Stop cleanly when told to.
- **`unpark` chosen mid-walk is deferred**, not run immediately — running
  `/route` per issue would derail the one-at-a-time walk with a heavy
  interactive analysis. Record the issue number and continue the walk; after the
  walk completes, run `/route <n>` for each unparked issue number and list
  those numbers in the tally.
- Report a final tally: unparked, reparked, skipped, remaining.

My arguments:
$ARGUMENTS

## Azure DevOps

Parked **work items** — and, unlike every other forge section here, this one
genuinely writes.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
source "$HOME/.claude/scripts/lib/azdo.sh"
resolve_azdo_context || { echo "not an Azure DevOps remote"; exit 1; }
```

### Tags on this forge

**The label is `parked`, plain ASCII — not `🧊 parked`.** Azure DevOps rejects
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
  AND [System.Tags] CONTAINS 'parked'
ORDER BY [System.CreatedDate] DESC" | tr '\n' ',' | sed 's/,$//') || rc=$?
```

Capture the status; `azdo_wiql` returns **2** when the Area Path does not exist,
which is not "nothing is parked". Resolve fields with `azdo_fields "$ids"`.

`CONTAINS` on `System.Tags` matches **whole tags** despite the operator's name,
so this will not catch `unparked` or `parked-later`. Verified.

### unpark `<n>`

Read the current tags, drop `parked`, write the rest back:

```bash
cur=$(azdo_fields "<n>" | python3 -c 'import sys,json; print(json.loads(sys.stdin.readline())["tags"])')
new=$(python3 -c '
import sys
tags = [t.strip() for t in sys.argv[1].split(";") if t.strip() and t.strip() != "parked"]
print(";".join(tags))' "$cur")
azdo_set_tags "<n>" "$new"
```

Report from that read-back, not from an exit code. If `new` is empty the item
ends with no tags at all, which is correct and is why `azdo_set_tags` accepts an
empty value.

**Then offer the recorded iteration back.** `repark` writes an `iteration-was:`
comment whenever it moved the item out of a sprint. Read the newest one and
**ask** before writing — never restore silently:

```bash
was=$(azdo_comments "<n>" | sed -n 's/^iteration-was: *//p' | tail -1)
```

- **Empty output** — nothing was recorded (parked by hand, or `repark` found the
  item already at the root). It stays where it is; say nothing about the
  iteration, because nothing here read it back.
- **An iteration that still exists** — check `$was` against `azdo_iterations`,
  offer to restore it, then report from the read-back:

  ```bash
  az boards work-item update --id "<n>" --org "$(azdo_org_url)" \
    --fields "System.IterationPath=$was" \
    --output tsv --only-show-errors --query 'fields."System.IterationPath"'
  ```

- **An iteration that no longer exists** — say so and leave the item at the root.
  Do not create it and do not substitute another.

These are the same rules as the GitHub section's `milestone-was:` offer; only
the record's spelling differs, because this forge schedules with an iteration
rather than a milestone.

### repark `<n>` "<reason>"

Add `parked` to the existing tags the same way. Capture the iteration **before**
anything moves it, then post the reason — there is no field for it — and the
record of where the item came from:

```bash
# 1 — the iteration being left; the project root means "already in backlog"
was=$(azdo_fields "<n>" | python3 -c 'import sys, json; print(json.loads(sys.stdin.readline())["iteration"])')

# 2 — the reason, and the record only when there is a sprint to record
az boards work-item update --id "<n>" --org "$(azdo_org_url)" \
  --discussion "<reason>" --output none --only-show-errors
if [ -n "$was" ] && [ "$was" != "$AZDO_PROJECT" ]; then
  az boards work-item update --id "<n>" --org "$(azdo_org_url)" \
    --discussion "iteration-was: $was" --output none --only-show-errors
fi
```

**The record is its own comment, not a second line of the reason.** GitHub and
Forgejo put `milestone-was:` on line two because their read-backs take the first
line; here the reader is `azdo_comments`, which strips the HTML the API wraps a
body in — so a newline arrives as a `<br>` that is removed without leaving a
space, gluing the record onto the end of the reason. `azdo_comments` prints one
comment per line, so a separate comment is the only spelling that survives the
round trip.

Then move the item to the project **root iteration**, this forge's `backlog`.
The root always exists, so there is no missing-backlog case here:

```bash
# 3 — move it to backlog, now that the previous iteration is recorded
az boards work-item update --id "<n>" --org "$(azdo_org_url)" \
  --fields "System.IterationPath=$AZDO_PROJECT" \
  --output tsv --only-show-errors --query 'fields."System.IterationPath"'
```

Report from that read-back: it must print `$AZDO_PROJECT` alone. A sprint is
scheduling, and reparking discards it, so `unpark` has to be able to offer it
back — the same round trip the other two forges get from `milestone-was:`.

### review

Walk the parked items oldest first and ask, one at a time, whether each should be
unparked. Never bulk-unpark.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
