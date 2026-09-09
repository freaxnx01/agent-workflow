---
description: List and triage parked (🧊) issues — list | unpark <n> | repark <n> "<reason>" | review
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
`🧊 parked` label — **newest first**. Keep the existing table shape and add a
`reason` column from the most recent `🧊 parked:` comment.

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
    | map(select([.labels.nodes[].name] | index("🧊 parked")))
    | .[] | [ .number, .title,
              ([.labels.nodes[].name] | join(",")),
              .createdAt, .author.login,
              ( [ .comments.nodes[] | (.body // "") | select(startswith("🧊 parked:")) ]
                | last // "—" | split("\n")[0] ) ] | @tsv'
```

Show a compact table — number, title, labels, age (relative), author, reason.
No preamble. If there are none, just say so.

### unpark

Remove only the `🧊 parked` label, then confirm from a read-back:

```bash
gh issue edit <n> --remove-label "🧊 parked"
gh issue view <n> --json number,labels --jq '[.number, ([.labels[].name] | join(","))] | @tsv'
```

Report from the read-back. If `🧊 parked` is still present, say the removal
failed and stop — do not continue to routing.

**Then offer the recorded milestone back.** `repark` writes a `milestone-was:` line
into its reason comment. Read it and **ask** before assigning — never restore
silently:

```bash
gh issue view <n> --json comments \
  --jq '[.comments[] | (.body // "") | select(startswith("🧊 parked:"))] | last // ""
        | split("\n") | map(select(startswith("milestone-was:"))) | first // ""
        | sub("^milestone-was:\\s*"; "")'
```

- **Empty output** — nothing was recorded (parked by hand, or it had no milestone).
  Say nothing and carry on to routing.
- **A still-open milestone** — offer to restore it (`gh issue edit <n> -m "<name>"`),
  then read back and report from the read-back.
- **A closed or deleted milestone** — say so and leave it un-milestoned. Do not
  recreate it and do not substitute another.

If the issue also has `needs-enrichment`, say so before routing. Then delegate:
read and follow `~/.claude/commands/route.md` (i.e. run `/route <n>`).
`/parked` must not reimplement route logic.

### repark

`repark` keeps labels as-is, appends a fresh reason comment, and **strips the
milestone** — recording the stripped name in that comment so `unpark` can offer it
back. Capture the milestone **before** stripping, or the name is gone:

```bash
# 1 — capture the current milestone (empty string when there is none)
was=$(gh issue view <n> --json milestone --jq '.milestone.title // ""')

# 2 — reason comment; the milestone-was line is added only when there was one
if [ -n "$was" ]; then
  gh issue comment <n> --body "🧊 parked: <reason>
milestone-was: $was"
else
  gh issue comment <n> --body "🧊 parked: <reason>"
fi
```

`milestone-was:` sits on the **second** line deliberately: every reason read-back
here takes `split("\n")[0]`, so `/parked list` and the confirmation below keep
showing the reason alone, never the bookkeeping line.

Then read back the newest comment whose body starts with `🧊 parked:` and confirm
from it, never from the exit code:

```bash
gh issue view <n> --json comments \
  --jq '[.comments[] | (.body // "") | select(startswith("🧊 parked:"))] | last // "—" | split("\n")[0]'
```

Only then strip it:

```bash
# 3 — strip, now that the name is safely recorded in the comment
gh issue edit <n> --remove-milestone
gh issue view <n> --json number,milestone --jq '[.number, (.milestone.title // "-")] | @tsv'
```

**Why the strip.** A parked issue is paused on purpose and not scheduled, so a
milestone contradicts the label — and `/milestone triage` filters `🧊 parked`
out of the un-milestoned gap, so it can never surface the contradiction. `unpark`
offers the recorded milestone back, so the round trip is recoverable — but only
when `repark` is what stripped it.

Report the milestone from the read-back. Removal on an issue that has no milestone
is a **no-op that exits 0** (verified 2026-09-09), so run it unconditionally.
**Coverage is partial by construction:** it only fires when `/parked repark` runs —
labelling an issue by hand in the web UI leaves its milestone in place.

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
`🧊 parked:` reason.

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
    if "🧊 parked" not in labels: continue
    print(i["number"],"|",i["title"],"|",",".join(labels),"|",i["created_at"],"|",(i.get("user") or {}).get("login","?"),"|","WIP" if i["number"] in wip else "")'

# then, per parked issue number, its most recent reason
tea api --login git-home "repos/$repo/issues/<n>/comments" \
  | python3 -c '
import sys,json
reasons=[c["body"] for c in json.load(sys.stdin) if (c.get("body") or "").startswith("🧊 parked:")]
print(reasons[-1].split("\n")[0] if reasons else "—")'
```

> Client-side filtering is used deliberately: `labels=🧊 parked` in the query string
> isn't URL-encoded by `tea api`, so the space+emoji breaks the request.

Show a compact table — number, title, labels, age (relative), author, open-PR
note, reason. No preamble. If there are none, just say so.

### unpark

Remove only the `🧊 parked` label, then confirm from a read-back:

```bash
tea issues edit <n> --login git-home --remove-labels "🧊 parked"

tea api --login git-home "repos/$repo/issues/<n>" | python3 -c '
import sys,json
i=json.load(sys.stdin)
print(i["number"], ",".join([l["name"] for l in i.get("labels") or []]), sep="\t")'
```

Report from the read-back. If `🧊 parked` is still present, say removal failed
and stop — do not continue to routing.

**Then offer the recorded milestone back** — same rules as the GitHub section: ask
first, open milestones only, never recreate a closed one.

```bash
tea api --login git-home "repos/$repo/issues/<n>/comments" | python3 -c '
import sys, json
bodies = [(c.get("body") or "") for c in json.load(sys.stdin)
          if (c.get("body") or "").startswith("🧊 parked:")]
lines = bodies[-1].split("\n") if bodies else []
was = [l for l in lines if l.startswith("milestone-was:")]
print(was[-1].split(":", 1)[1].strip() if was else "")'
```

Restore with `tea milestones issues add --login git-home "<name>" <n>`, then read
back.

If the issue also has `needs-enrichment`, say so before routing. Then delegate:
read and follow `~/.claude/commands/route.md` (i.e. run `/route <n>`).
`/parked` must not reimplement route logic.

### repark

`repark` keeps labels as-is, appends a fresh reason comment, and **strips the
milestone** — recording the stripped name so `unpark` can offer it back. Capture it
**before** stripping, or the name is gone:

```bash
# 1 — capture the current milestone (empty when there is none)
was=$(tea api --login git-home "repos/$repo/issues/<n>" | python3 -c '
import sys, json
m = json.load(sys.stdin).get("milestone") or {}
print(m.get("title") or "")')

# 2 — reason comment; the milestone-was line only when there was one
if [ -n "$was" ]; then
  tea comment <n> "🧊 parked: <reason>
milestone-was: $was"
else
  tea comment <n> "🧊 parked: <reason>"
fi
```

`milestone-was:` sits on the **second** line deliberately — every reason read-back
here takes the first line only, so it stays invisible to `/parked list`.

Then read back the newest comment whose body starts with `🧊 parked:` and confirm
from it, never from the exit code:

```bash
tea api --login git-home "repos/$repo/issues/<n>/comments" | python3 -c '
import sys,json
comments=json.load(sys.stdin)
reasons=[(c.get("body") or "") for c in comments if (c.get("body") or "").startswith("🧊 parked:")]
print(reasons[-1].split("\n")[0] if reasons else "—")'
```

Parking also **strips the milestone**:

```bash
# read the current milestone — `remove` takes the name, not an id
tea api --login git-home "repos/$repo/issues/<n>" | python3 -c '
import sys, json
m = json.load(sys.stdin).get("milestone") or {}
print(m.get("title") or "")'

# then, only if that printed a name:
tea milestones issues remove --login git-home "<name>" <n>
```

**Why the strip.** A parked issue is paused on purpose and not scheduled, so a
milestone contradicts the label — and `/milestone triage` filters `🧊 parked`
out of the un-milestoned gap, so it can never surface the contradiction. `unpark`
offers the recorded milestone back, so the round trip is recoverable — but only
when `repark` is what stripped it.

Report the milestone from the read-back. Removal on an issue that has no milestone
is a **no-op that exits 0** (verified 2026-09-09), so run it unconditionally.
**Coverage is partial by construction:** it only fires when `/parked repark` runs —
labelling an issue by hand in the web UI leaves its milestone in place.

`tea milestones issues remove` mirrors the `add` form used by `/milestone assign`
and carries the same epistemic caveat as every other `tea` flag here — taken from
tea's source, not a live run. If it misbehaves, the fallback is
`tea api --login git-home -X PATCH "repos/$repo/issues/<n>"` with `{"milestone":0}`;
fix it and update this command.

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

`detect_forge` said `azdo`, so the remote is an Azure DevOps one — and **this
command has no Azure DevOps section yet**. Say exactly that and **stop**.

Do **not** fall back to the GitHub or Forgejo section. Neither `gh` nor `tea` can
read ADO work items, so running either against this remote fails confusingly at
best; on a command that *writes*, it would aim the write at the wrong forge
entirely. `/issues` is the only command with ADO support today — see **ADR-011**
in agent-workflow's `docs/DECISIONS.md` for the object mapping, and its `TODO.md`
for the port status.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
