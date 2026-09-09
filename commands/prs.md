---
description: List pull requests awaiting review
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## GitHub

Show open pull requests that need review in the current repo.

- **My review requested** (priority):
  `gh pr list --state open --search "review-requested:@me" --json number,title,author,createdAt,reviewDecision`
- **Also awaiting review** — other open PRs not authored by me with
  `reviewDecision` of `REVIEW_REQUIRED` or empty, so nothing slips through.

Compact table: number, title, author, age, review state. Exclude drafts unless
that's all there is. If none, say so.

## Forgejo

Show open pull requests that need review in the current Forgejo repo.

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`). Resolve `owner/name` from the remote for `tea api`:

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
me=$(tea api --login git-home user 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["login"])')
```

### Approach

Forgejo has no GitHub `reviewDecision` / `review-requested:@me` search. Derive the
two buckets from the open PRs and their `requested_reviewers`:

```bash
tea api --login git-home "repos/$repo/pulls?state=open&limit=50&type=pulls" \
  | python3 -c "
import sys,json
me='$me'
prs=json.load(sys.stdin)
mine=[]; other=[]
for p in prs:
    if p.get('draft'): continue
    rr=[u.get('login') for u in (p.get('requested_reviewers') or [])]
    row=(p['number'], p['title'], (p.get('user') or {}).get('login','?'), p.get('created_at'))
    (mine if me in rr else other).append(row)
print('## My review requested')
for r in mine or [('—','none','','')]: print(*r, sep=' | ')
print('## Also awaiting review')
for r in other or [('—','none','','')]: print(*r, sep=' | ')
"
```

> If a PR has **no** requested reviewers and isn't authored by you, surface it under
> "also awaiting review" so nothing slips through. Forgejo also exposes per-PR
> review state via `repos/$repo/pulls/<n>/reviews` if you need approve/changes
> status — fetch it only when it matters, not for every PR in the list.

Compact table: number, title, author, age, bucket. Exclude drafts unless that's all
there is (agent/WIP PRs are often drafts). If none, say so.

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
