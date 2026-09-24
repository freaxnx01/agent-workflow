---
description: Recently implemented (closed) issues
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## GitHub

List recently implemented issues — closed issues, most recently closed first:

`gh issue list --state closed --limit 30 --json number,title,closedAt,labels,stateReason --jq 'sort_by(.closedAt) | reverse'`

Prefer issues closed as **completed** (`stateReason` = `COMPLETED`); list any that
were closed **not planned** separately at the end. Compact table: number, title,
when closed (relative), labels. Concise.

## Forgejo

List recently implemented issues in the current Forgejo repo — closed issues, most
recently closed first.

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`). `tea issues list --state closed` works from inside the clone:

```bash
tea issues list --login git-home --state closed --fields index,title,updated,labels 2>/dev/null
```

For precise "closed at" ordering, query the API and sort by `closed_at`:

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
tea api --login git-home "repos/$repo/issues?state=closed&type=issues&limit=30&sort=updated&order=desc" \
  | python3 -c '
import sys,json
rows=[i for i in json.load(sys.stdin)]
rows.sort(key=lambda i:i.get("closed_at") or "", reverse=True)
for i in rows:
    labels=[l["name"] for l in i.get("labels") or []]
    print(i["number"],"|",i["title"],"|",i.get("closed_at"),"|",",".join(labels) or "-")'
```

> **Forgejo has no `stateReason`** (no GitHub-style "completed" vs "not planned"
> distinction) — a closed issue is just closed. So, unlike `/done`, this can't
> split completed from not-planned. If you need that signal, infer it from labels
> (e.g. a `wontfix`/`duplicate` label) and list those separately.

Compact table: number, title, when closed (relative), labels. Concise.

## Azure DevOps

Recently **completed** work items.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
source "$HOME/.claude/scripts/lib/azdo.sh"
resolve_azdo_context || { echo "not an Azure DevOps remote"; exit 1; }
```

Closed is `State IN (closed states)` — the inverse of every other query here — and
the state list is **derived**, never written out, because it is template-specific:
a Basic project has `Done`, an Agile-derived one does not.

```bash
rc=0; ids=$(azdo_wiql "SELECT [System.Id] FROM WorkItems
WHERE [System.TeamProject] = @project
  AND [System.AreaPath] UNDER '$AZDO_PROJECT\\$AZDO_REPO'
  AND [System.State] IN ($(azdo_closed_states))
  AND [System.ChangedDate] >= @today - 30
ORDER BY [System.ChangedDate] DESC" | tr '\n' ',' | sed 's/,$//') || rc=$?
```

Capture `azdo_wiql`'s status; never call it bare. Sourcing `azdo.sh` applies
`set -e`, and the function returns **2** when the Area Path does not exist
(`TF51011`) — a different answer from "nothing matched", which must not be
reported as one.

`@today - 30` is valid WIQL and is the recency window; adjust the number rather
than filtering in the shell. There is no "closed at" field to sort on —
`System.ChangedDate` is the closest, and it moves on any edit, so treat the
ordering as approximate and say so if it matters.

Resolve fields with `azdo_fields "$ids"` and show id, title, state and iteration.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
