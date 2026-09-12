---
description: What to implement next — open issues in implementation order, each with its status and whether it is already in flight
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

This command takes **no arguments**. Scoping by milestone belongs to `/triage`
and `/issues`; adding it here would duplicate their resolution rules.

## What this answers

`/triage` asks *what is broken and what is cheap*. `/queue` asks a different
question: **what should I build next, and what is already being built?**

So it keeps two things `/triage` drops:

- **Work in flight stays in the list**, marked — an issue with a linked PR, a
  local branch or worktree, or a running pipeline is the first thing you need
  to see, not the first thing to filter out. `/issues` hides those on purpose;
  here they lead.
- **Order reflects sequence, not category** — blockers before what they block,
  same code area adjacent, so one pass through a file serves both.

This is a reading aid. **Do not start any work from it.**

## Ordering

Two stages. **Place** every issue in exactly one bucket, then **adjust** the
resulting list. Keeping these apart matters: the adjustments are re-positioning
rules, not bucket predicates, and treating them as a fifth and sixth bucket
makes them unreachable for anything that already matched 1–4.

**Stage 1 — place.** First match wins:

1. **Already in flight** — finish before starting anything new. Half-done work
   is the most expensive thing in the list.
2. **Blocks something else** — an issue another one waits on.
3. **Breaks normal use** — a defect that stops the product doing its job on the
   primary device or path. Read the body for *what the user cannot do*, not for
   the word "bug".
4. **Everything else**, cheapest first — small and self-contained before large
   or vague.

Within a bucket, ready-to-dispatch beats not-ready: an issue still carrying
`needs-enrichment` needs `/enrich` before `/gh:implement`, which is real work
sitting in front of it.

**Stage 2 — adjust**, in this order:

1. **Move every blocked issue behind the issue it waits on.** If the blocker is
   closed or absent, leave it in place and say the blocker is gone — do not
   silently treat it as unblocked.
2. **Cluster by area.** Move an issue that touches the same code as one already
   placed to sit directly after it — but never past a blocker relationship set
   by the previous step. Clustering is a convenience; dependency order is not.

An issue that is both blocked *and* in flight stays in bucket 1: something is
already happening to it, which is what the reader needs to know first.

## Dependencies are inferred — say so

Dependencies are **not recorded anywhere structured**, so you derive them from
issue titles and bodies, from labels, and from what the code shows. That is a
guess, and a guess presented as fact is worse than no order at all.

So, every run:

- Print **one line per ordering decision that isn't obvious** — which issue
  waits on which, and what you read that from.
- End with a sentence saying the order is a proposal derived from issue text,
  not from recorded dependencies.
- When two issues could go either way, say so rather than picking silently.

**An explicit `Blocked by #N` or `Depends on #N` line in an issue body wins over
your own reading** — say when you used one. Both fetches below extract those
references from the **full body**, as their own `blocked_by` field, precisely
because the body text you read is truncated to a preview. Never look for a
dependency line in the preview: on an enriched issue the whole implementation
plan sits in the body, so anything past the first few hundred characters is not
there. Nothing creates these lines today; they are simply honoured when present,
so the convention can grow without another change here.

## Output

One table, ordered, no grouping headers — the order *is* the message:

| # | Title | Status | In flight | Why here |
|---|---|---|---|---|

- **Status** — the readiness of the issue: needs enrichment, ready to
  dispatch, enrichment running, blocked.
- **In flight** — empty for most rows. Otherwise what is in flight and where:
  a linked PR number, a branch or worktree name, or a running pipeline.
- **Why here** — three to six words. The reason this row sits at this
  position, not a summary of the issue.

Render the table in the language the conversation is being held in — the
headings above are the English form; translate them when the session is not.

Close with the count of issues that need enrichment before they can be
dispatched at all — that number is the queue's real length, and it is usually
larger than people expect.

## GitHub

One GraphQL call gets the issues **and** their PR links, so in-flight detection
costs no extra request. Keep parked and roadmap out; keep work in flight **in**,
because showing it is the point.

```bash
gh api graphql \
  -f owner="$(gh repo view --json owner -q .owner.login)" \
  -f name="$(gh repo view --json name -q .name)" \
  -f query='
query($owner:String!,$name:String!){
  repository(owner:$owner,name:$name){
    issues(states:OPEN, first:100, orderBy:{field:CREATED_AT, direction:ASC}){
      totalCount
      nodes{
        number title createdAt
        labels(first:20){nodes{name}}
        body
        linked: timelineItems(itemTypes:[CONNECTED_EVENT], first:50){
          nodes{ ... on ConnectedEvent{subject{... on PullRequest{number state}}} }
        }
        mentioned: timelineItems(itemTypes:[CROSS_REFERENCED_EVENT], first:50){
          nodes{ ... on CrossReferencedEvent{source{... on PullRequest{number state}}} }
        }
      }
    }
  }
}' \
  --jq '.data.repository.issues
    | "prefilter_total=\(.totalCount) fetched=\(.nodes | length)",
      (.nodes
        | map(select([.labels.nodes[].name] | index("🧊 parked") | not))
        | map(select([.labels.nodes[].name] | index("roadmap") | not))
        | .[] | {
            number, title,
            labels: [.labels.nodes[].name],
            body_len: ((.body // "") | length),
            body: ((.body // "") | gsub("\n"; " ") | .[0:400]),
            blocked_by: ([ (.body // "")
                           | scan("(?i)(?:blocked by|depends on)[[:space:]]*#([0-9]+)") ]
                         | flatten | map(tonumber) | unique),
            linked_prs: [.linked.nodes[].subject | select(.state == "OPEN") | .number],
            mentioned_prs: [.mentioned.nodes[].source | select(.state == "OPEN") | .number]
          })'
```

Labels here are `.labels.nodes[].name` — the GraphQL shape — **not**
`[.labels[].name]`, which is what `gh issue list --json labels` yields.

**`linked_prs` and `mentioned_prs` are not the same signal.** A `ConnectedEvent`
means someone actually linked the PR to the issue, so a non-empty `linked_prs`
is in flight. A `CrossReferencedEvent` fires when *any* open PR merely names
`#N` in its body or a comment — a PR saying "similar to #42" cross-references
42 without anybody working on it. So treat `mentioned_prs` as a hint worth one
sentence, never as grounds for bucket 1, and say which of the two a row rests on.

`blocked_by` is extracted from the **full** body; `body` is a 400-char preview
for reading only. Ordering is `CREATED_AT ASC`, so the oldest issue is row one
before you re-order — that keeps a long-ignored issue from hiding at the bottom
of the fetch.

**Truncation guard:** the cap of 100 applies *before* the parked/roadmap filter,
so if 100 came back pre-filter, say the list may be incomplete rather than
implying it is the whole set.

### Local signals the forge cannot see

An issue can be in flight with nothing on the forge yet — someone is working in
a branch or worktree that has never been pushed. Check locally as well:

```bash
git worktree list
git branch --list
git status -sb | head -1
```

Match a branch or worktree to an issue by its number (`feat/123-…`), and
otherwise by name against the issue title — say when the match is by name,
because that one is a guess. A dirty worktree on such a branch is a stronger
in-flight signal than the branch existing alone; mention it when you see it.

Pipeline state lives in labels: `ai:running` means a dispatch is executing,
`enrichment-ongoing` means a `/enrich` holds the lock, `ai-implement` means it is
queued. Treat all three as in flight.

## Forgejo

Same question, same output, same ordering. Forgejo has no timeline equivalent,
so in-flight detection needs a second call and matches PRs to issues by text.

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`):

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
tea api --login git-home "repos/$repo/issues?state=open&type=issues&limit=100&sort=oldest" \
  | python3 -c '
import sys, json, re
dep = re.compile(r"(?:blocked by|depends on)\s*#(\d+)", re.I)
for i in json.load(sys.stdin):
    labels = [l["name"] for l in i.get("labels") or []]
    if "🧊 parked" in labels or "roadmap" in labels: continue
    body = i.get("body") or ""
    blocked = sorted({int(n) for n in dep.findall(body)})
    print(i["number"], "||", i["title"], "||", ",".join(labels) or "-",
          "||", len(body),
          "||", ",".join(map(str, blocked)) or "-",
          "||", body[:400].replace(chr(10), " "))'
```

**`sort=oldest`, and no `order` parameter.** The Forgejo issues API takes `sort`
from a fixed enum (`relevance`, `latest`, `oldest`, `recentupdate`,
`leastupdate`, `mostcomment`, `leastcomment`, `nearduedate`, `farduedate`;
default `latest`) and has no `order` at all — a `sort=created&order=asc` pair is
silently ignored and returns newest-first, which with `limit=100` would drop
exactly the oldest issues this ordering exists to surface.

`blocked` comes from the **full** body, before the 400-char preview is cut.

Then the open PRs, to find which issues they belong to:

```bash
tea api --login git-home "repos/$repo/pulls?state=open&limit=100" | python3 -c '
import sys, json, re
closes = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", re.I)
mentions = re.compile(r"#(\d+)")
branch = re.compile(r"^(?:issue-)?(?:[a-z]+/)?(\d+)[-_]")
for p in json.load(sys.stdin):
    text = (p.get("title") or "") + " " + (p.get("body") or "")
    ref = (p.get("head") or {}).get("ref") or ""
    strong = {int(n) for n in closes.findall(text)}
    m = branch.match(ref)
    if m: strong.add(int(m.group(1)))
    weak = {int(n) for n in mentions.findall(text)} - strong
    print(p["number"], "||", p.get("title") or "-",
          "||", ",".join(map(str, sorted(strong))) or "-",
          "||", ",".join(map(str, sorted(weak))) or "-")'
```

Three columns, and the last two carry different weight — the same split the
GitHub half makes:

- **strong** — a closing keyword, or a branch named for the issue
  (`issue-123-…`, `feat/123-…`). Treat as in flight.
- **weak** — the issue number appears somewhere in the PR text without either.
  A hint, not grounds for bucket 1.

Both are sorted numerically, so `#9` precedes `#10`. The match is still
**textual**: a PR that names its issue nowhere and uses an unnumbered branch
stays invisible. Say so when you report, rather than implying the in-flight
column is complete.

The local-signal checks (`git worktree list`, `git branch --list`,
`git status -sb`) apply unchanged — they are forge-independent.

## Azure DevOps

`detect_forge` said `azdo`, so the remote is an Azure DevOps one — and **this
command has no Azure DevOps section yet**. Say exactly that and **stop**.

Do **not** fall back to the GitHub or Forgejo section. Neither `gh` nor `tea` can
read ADO work items, so running either against this remote fails confusingly.
`/issues` is the only command with ADO support today — see **ADR-012** in
`docs/DECISIONS.md` for the object mapping, and `TODO.md` for the port status.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.

---

If you run into blockers — a forge shape that doesn't match, an in-flight signal
this misses, an ordering rule that keeps producing a sequence you then have to
correct by hand — find a solution and update this command so the next run
inherits it.
