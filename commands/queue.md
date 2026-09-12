---
description: What to implement next — open issues in implementation order, each with its status and whether it is already in flight
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## What this answers

`/triage` asks *what is broken and what is cheap*. `/queue` asks a different
question: **what should I build next, and what is already being built?**

So it keeps two things `/triage` drops:

- **Work in flight stays in the list**, marked — an issue with an open PR, a
  local branch or worktree, or a running pipeline is the first thing you need
  to see, not the first thing to filter out. `/issues` hides those on purpose;
  here they lead.
- **Order reflects sequence, not category.** Blockers before the things they
  block; same code area adjacent, so one pass through a file serves both.

This is a reading aid. **Do not start any work from it.**

## Ordering

Apply in this order, first match wins:

1. **Already in flight** — finish before starting anything new. Half-done work
   is the most expensive thing in the list.
2. **Blocks something else** — an issue another one waits on.
3. **Breaks normal use** — a defect that stops the product doing its job on the
   primary device or path. Read the body for *what the user cannot do*, not for
   the word "bug".
4. **Cheap and independent** — small, self-contained, no dependants. Easiest
   first.
5. **Same area as something above** — cluster issues touching the same code,
   directly after the one they share it with.
6. **Blocked or waiting** — last, each naming what it waits on.

Ready-to-dispatch beats not-ready within a bucket: an issue still carrying
`needs-enrichment` needs `/enrich` before `/gh:implement`, which is real work
sitting in front of it.

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

**If an issue body carries an explicit `Blocked by #N` (or `Depends on #N`)
line, honour it over your own reading** and say you did. Nothing creates those
lines today; they are simply respected when present, so the convention can grow
without a change here.

## Output

One table, ordered, no grouping headers — the order *is* the message:

| # | Title | Status | In flight | Why here |
|---|---|---|---|---|

- **Status** — the readiness of the issue: needs enrichment, ready to
  dispatch, enrichment running, blocked.
- **In flight** — empty for most rows. Otherwise what is in flight and where:
  an open PR number, a branch or worktree name, or a running pipeline.
- **Why here** — three to six words. The reason this row sits at this
  position, not a summary of the issue.

Render the table in the language the conversation is being held in — the
headings above are the English form; translate them when the session is not.

Close with the count of issues that need enrichment before they can be
dispatched at all — that number is the queue's real length, and it is usually
larger than people expect.

## GitHub

One GraphQL call gets the issues **and** their linked-PR state, so in-flight
detection costs no extra request. Keep parked and roadmap out; keep WIP **in**,
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
        timelineItems(itemTypes:[CROSS_REFERENCED_EVENT,CONNECTED_EVENT], first:50){
          nodes{
            ... on CrossReferencedEvent{source{... on PullRequest{number state}}}
            ... on ConnectedEvent{subject{... on PullRequest{number state}}}
          }
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
            open_prs: [.timelineItems.nodes[] | (.source // .subject)
                       | select(.state == "OPEN") | .number]
          })'
```

Labels here are `.labels.nodes[].name` — the GraphQL shape — **not**
`[.labels[].name]`, which is what `gh issue list --json labels` yields.

`open_prs` non-empty means in flight on the forge. Ordering is `CREATED_AT ASC`
so the oldest issue is row one before you re-order; that keeps a long-ignored
issue from hiding at the bottom of the fetch.

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

My arguments:
$ARGUMENTS

## Forgejo

Same question, same output, same ordering. Forgejo has no cheap equivalent of
the GitHub timeline query, so in-flight detection needs two calls: the issues,
then the open pull requests, matched by issue reference.

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`):

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
tea api --login git-home "repos/$repo/issues?state=open&type=issues&limit=100&sort=created&order=asc" \
  | python3 -c '
import sys, json
for i in json.load(sys.stdin):
    labels = [l["name"] for l in i.get("labels") or []]
    if "🧊 parked" in labels or "roadmap" in labels: continue
    body = (i.get("body") or "")
    print(i["number"], "||", i["title"], "||", ",".join(labels) or "-",
          "||", len(body), "||", body[:400].replace(chr(10), " "))'
```

Then the open PRs, to find which issues they belong to:

```bash
tea api --login git-home "repos/$repo/pulls?state=open&limit=100" | python3 -c '
import sys, json, re
for p in json.load(sys.stdin):
    text = (p.get("title") or "") + " " + (p.get("body") or "") + " " + (p.get("head", {}).get("ref") or "")
    refs = sorted(set(re.findall(r"#(\d+)", text)))
    print(p["number"], "||", p.get("title") or "-", "||", ",".join(refs) or "-")'
```

That match is **textual**, not a real link — a PR that never names its issue
stays invisible here. Say so when you report, rather than implying the in-flight
column is complete.

The local-signal checks (`git worktree list`, `git branch --list`,
`git status -sb`) apply unchanged — they are forge-independent.

My arguments:
$ARGUMENTS

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
