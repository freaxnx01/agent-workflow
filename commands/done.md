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

`detect_forge` said `azdo`, so the remote is an Azure DevOps one — and **this
command has no Azure DevOps section yet**. Say exactly that and **stop**.

Do **not** fall back to the GitHub or Forgejo section. Neither `gh` nor `tea` can
read ADO work items, so running either against this remote fails confusingly at
best; on a command that *writes*, it would aim the write at the wrong forge
entirely. `/issues` is the only command with ADO support today — see **ADR-012**
in agent-workflow's `docs/DECISIONS.md` for the object mapping, and its `TODO.md`
for the port status.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
