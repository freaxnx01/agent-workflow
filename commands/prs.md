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

Show open pull requests that need review in the current repo.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
source "$HOME/.claude/scripts/lib/azdo.sh"
resolve_azdo_context || { echo "not an Azure DevOps remote"; exit 1; }
org_url="$(azdo_org_url)"
```

**`--status` takes `active` / `completed` / `abandoned` / `all` — there is no
`open`.** Passing `open` is not an error you will notice; it simply matches
nothing. "Needs review" means `active`.

```bash
az repos pr list --org "$org_url" --project "$AZDO_PROJECT" \
  --repository "$AZDO_REPO" --status active \
  --output json --only-show-errors
```

This response **is** a top-level array, unlike the classification-node listings
in `/milestone` and `/issues`, so `--query '[].pullRequestId'` is correct here.
Both PR `--query` paths were checked against a live organization; don't "fix"
them to `children[]`.

Reviewer state lives on each PR's `reviewers[]`, with `vote` as an **integer**.
Measured against a live PR by casting each vote and reading it back, rather than
taken from the docs:

| `vote` | meaning | `az repos pr set-vote --vote` |
|---|---|---|
| `10` | approved | `approve` |
| `5` | approved with suggestions | `approve-with-suggestions` |
| `0` | no vote yet | `reset` |
| `-5` | waiting for author | `wait-for-author` |
| `-10` | rejected | `reject` |

So "awaiting review" is a PR with at least one reviewer whose `vote` is `0`, and
"my review requested" is one where that reviewer is me. There is no
`review-requested:@me` search equivalent — filter the list locally.

Linked work items, which is what makes a PR reviewable in context:

```bash
az repos pr work-item list --org "$org_url" --id <pr> \
  --output tsv --only-show-errors --query '[].id'
```

Compact table: id, title, author, age, review state, linked work items. Exclude
drafts (`isDraft: true`) unless that's all there is. If none, say so.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
