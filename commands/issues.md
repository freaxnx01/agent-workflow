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

## Unknown host

Report the detected host and that no authed GitHub or Forgejo login matched
it; point at `gh auth login` / `tea login add`. Don't guess a forge.
