---
description: Open issues ordered bugs/fixes first, then quick wins — optionally scoped to one milestone, minus parked/roadmap
argument-hint: "[<milestone> | pick]"
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## Argument — optional milestone scope

The argument is **optional** and chooses which issues to triage:

| Argument | Meaning |
| --- | --- |
| *(none)* | Every in-scope issue. The default, unchanged. |
| `pick` | List the open milestones with their open counts, ask which to triage, then scope to the answer. |
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
> wrongly resolved name corrupts data. `/triage` only reads, an ambiguous argument
> never resolves silently, and every row prints its milestone, so a wrong guess
> is visible immediately rather than persisted.

When a milestone **is** in scope, skip the closing un-milestoned count — it is
zero by construction. Say which milestone you scoped to instead.

## GitHub

Fetch open issues with body, labels, and **milestone**, dropping the ones that
aren't current work — **not parked** (no `🧊 parked` label) and **not roadmap**
(no `roadmap` label). Parked issues are deliberately deferred; list them with
`/parked`. Roadmap issues are planned for a future milestone rather than current
work; list them with `/roadmap`.

For `pick`, or to resolve an ambiguous `<name>`, list the open milestones first:

```bash
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq 'sort_by(.due_on // "9999") | .[] | [.title, (.due_on // "-"), .open_issues] | @tsv'
```

Do the exclusion **in the query, not by eye** — a `--jq` filter can't be skipped,
a prose instruction can. Add `--milestone "<title>"` when one is in scope; drop
that flag entirely when it is not:

```bash
gh issue list --state open --limit 100 \
  --milestone "<resolved title>" \
  --json number,title,labels,body,createdAt,milestone \
  --jq 'map(select([.labels[].name] | index("🧊 parked") | not))
    | map(select([.labels[].name] | index("roadmap") | not))
    | .[] | [
        .number,
        (.milestone.title // "-"),
        ((.milestone.dueOn // "-") | .[0:10]),
        .title,
        (([.labels[].name] | join(",")) | if . == "" then "-" else . end),
        ((.body // "") | length),
        ((.body // "") | gsub("\n"; " ") | .[0:200])
      ] | @tsv'
```

`--milestone` filters **server-side**, so the call stays one cheap request — do
not fetch everything and discard non-matching milestones in jq instead. It
filters milestone *membership only*, so the parked/roadmap `--jq` filters above
stay regardless.

Two field-shape traps: `gh issue list --json labels` yields `[.labels[].name]` —
**not** `.labels.nodes[].name`, which is the GraphQL shape `/issues` uses — and
the due date is `.milestone.dueOn` (camelCase), unlike Forgejo's `due_on`.

The body is truncated to a 200-char preview, so its **full character count is
emitted as its own column** — that length, not the preview, is the "short and
well-defined" signal bucket 2 relies on. Never judge scope from the preview.

**Truncation guard:** the fetch caps at 100 *before* jq drops parked/roadmap, so
the visible count is twice-removed from the repo total. If 100 issues came back
pre-filter, say the list may be incomplete rather than implying it is the whole
set.

**WIP is deliberately not excluded here.** Dropping issues with an open linked PR
needs the GraphQL timeline query that `/issues` runs; `/triage` stays a single
cheap `gh issue list` call. Use `/issues` when you want the WIP filter too.

Then present them ordered for triage:

1. **Bugs / fixes first** — issues whose labels or title/body signal a defect
   (labels like `bug`, `type:bug`, `defect`, `regression`, `fix`; or clear
   bug wording).
2. **Then quick wins** — remaining low-complexity / small-scope issues
   (short, well-defined; labels like `good-first-issue`, `chore`, `docs`,
   `small`). Easiest first, by your judgment from title/body/labels.
3. **Everything else** after that.

For each: number, title, key labels, **milestone + due date**, body length, and a 3–6 word
reason it's in that bucket. Milestone is **shown, not sorted on** — the buckets
stay bugs → quick wins → rest, because triage asks *what's broken and what's
cheap*, not *when does it ship*. Render an issue with no milestone as
`no milestone` rather than a blank column, and close with a count of those — they
are what `/milestone triage` walks. Be concise — this is a reading aid, don't
start any work.

My arguments:
$ARGUMENTS

## Forgejo

Fetch open issues (with body, labels, and milestone) from the current Forgejo
repo, then present them ordered for triage. Same exclusions as the GitHub section
— **not parked**, **not roadmap** — applied in the query, not by eye.

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`):

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
tea api --login git-home "repos/$repo/issues?state=open&type=issues&limit=100&sort=created&order=desc" \
  | python3 -c '
import sys, json
for i in json.load(sys.stdin):
    labels = [l["name"] for l in i.get("labels") or []]
    if "🧊 parked" in labels or "roadmap" in labels: continue
    m = i.get("milestone") or {}
    print(i["number"], "||", m.get("title") or "-", "||", (m.get("due_on") or "-")[:10],
          "||", i["title"], "||", ",".join(labels) or "-",
          "||", len(i.get("body") or ""),
          "||", (i.get("body") or "")[:200].replace(chr(10), " "))'
```

For `pick`, or to resolve an ambiguous `<name>`, list the open milestones first:

```bash
tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
for m in sorted(json.load(sys.stdin), key=lambda x: x.get("due_on") or "9999"):
    print(m["title"], m.get("due_on") or "-", m.get("open_issues", 0), sep="\t")'
```

To scope the fetch to a resolved milestone, add a title check to the loop
already shown above, beside the label skip:

```python
    want = "<resolved title>"          # omit this pair of lines when unscoped
    if want and (m.get("title") or "") != want: continue
```

The Forgejo issues API also accepts a `&milestones=<name>` query parameter, which
would filter server-side like `gh`'s `--milestone`. It is **not used here because
it has never been verified against a live `tea`** — switch to it once someone
confirms it, and delete the client-side check.

Forgejo spells the due date `due_on` (snake_case), unlike `gh`'s `dueOn`. As in
the GitHub half, the body is a 200-char preview and its **full length is its own
column** — that is the "short and well-defined" signal for bucket 2, not the
preview. The `limit=100` caps the fetch *before* the label skip, so if 100 came
back pre-filter, say the list may be incomplete.

### Ordering

Present them ordered for triage:

1. **Bugs / fixes first** — issues whose labels or title/body signal a defect
   (labels like `bug`, `type:bug`, `defect`, `regression`, `fix`; or clear bug
   wording).
2. **Then quick wins** — remaining low-complexity / small-scope issues (short,
   well-defined; labels like `good-first-issue`, `chore`, `docs`, `small`). Easiest
   first, by your judgment from title/body/labels.
3. **Everything else** after that.

For each: number, title, key labels, **milestone + due date**, body length, and a 3–6 word
reason it's in that bucket. Milestone is **shown, not sorted on** — the buckets
stay bugs → quick wins → rest. Render an issue with no milestone as
`no milestone` rather than a blank column, and close with a count of those — they
are what `/milestone triage` walks — it detects Forgejo the same way this
command does. Be concise — this is a reading aid, don't start any work.

My arguments:
$ARGUMENTS

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
