# Draft — `/status` command and `STATUS.md`

**Move on landing:** the fenced command body below belongs at `commands/status.md`.
It was drafted here because the bridge MCP path allowlist covers `docs/**/*.md` and
root `*.md` only — `commands/` is not writable through it. Once moved, delete this
draft and run `setup/link-commands.sh` so `/status` resolves.

## Why

`/roadmap`, `/issues` and `/milestone` all answer "what's the state of things" with
a live forge query. That works while a session is warm and costs several round-trips
plus the tokens to read them back. After `/clear`, or at the start of a fresh
session, or for a subagent that only needs orientation rather than authority, the
same answer should be one file read.

`STATUS.md` is that file: **generated, committed, never hand-edited**. Issues stay
canonical. The file is a cache whose staleness is bounded by regenerating it at the
end of `/done` and `/wrap-up`.

Borrowed shape (not mechanism) from `AlexPEClub/ai-coding-starter-kit`, whose
`features/INDEX.md` is the tracker itself because that project has no forge in the
loop. Deliberately **not** borrowed: the hand-maintained `Next Available ID`
counter, the `PROJ-X` namespace parallel to issue numbers, and per-file status
emoji. See `docs/ai-notes/` for the fuller comparison.

## States

Derived from signals that already exist — no new label vocabulary:

| State | Signal |
| --- | --- |
| `Parked` | `parked` label |
| `Roadmap` | `roadmap` label |
| `WIP` | open linked PR (GitHub timeline) or `issue-N-*` branch (Forgejo) — same rule `/issues` uses |
| `Blocked` | a `Blocked by:` reference that resolves to a still-open issue |
| `Ready` | none of the above |

Blocker parsing delegates to `scripts/parse-chain.sh` so the `Blocked by:` marker
format has exactly one definition.

Note what is **not** a state: "enriched" / "spec written". There is currently no
machine-readable marker for it, and inventing one here would have meant guessing at
`enrich.md`'s output shape. If a marker is added later (a label, or a stable heading
in the issue body), a `Spec` column is a small change to the renderer.

## The command

````markdown
---
description: Generate STATUS.md — a committed snapshot of the repo's work ledger for cold agent context
argument-hint: show | write
---

Regenerate `STATUS.md`: a **generated, committed** snapshot of every open issue in
this repo, grouped by milestone. Issues stay canonical — this file is a cache, so a
fresh session (or a session after `/clear`) can orient with one file read instead of
several forge round-trips.

Never hand-edit `STATUS.md`. It is overwritten wholesale on every run, and the
banner at the top says so.

## Parse the verb

**Two verbs only** — `show`, `write`.

- No arguments → treat it as `show`.
- A first word that isn't one of the two → print the two usage forms and **stop**.
  Don't guess, don't fuzzy-match.

```text
/status show    # render to stdout, touch nothing
/status write   # overwrite STATUS.md in the working tree (does not commit)
```

`write` leaves the file modified-but-uncommitted on purpose — `/commit` or `/done`
picks it up with the rest of the change. Don't commit it from here.

Detect the forge, then run the matching collection section. Both produce the same
normalized JSON; the **Render** section below is shared.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## Normalized shape

Each collection section writes a JSON array to `/tmp/status_issues.json`:

```json
[
  {
    "number": 42,
    "title": "Add API compatibility gate",
    "body": "...",
    "updated": "2026-08-20T09:14:00Z",
    "labels": ["P1", "ai-chain"],
    "milestone": "v0.9",
    "wip": true
  }
]
```

`wip` means an **open** linked PR exists (or, on Forgejo, an `issue-N-*` branch) —
the same definition `/issues` uses. Keep the two in step: if one changes, change
both.

## GitHub

```bash
gh api graphql \
  -f owner="$(gh repo view --json owner -q .owner.login)" \
  -f name="$(gh repo view --json name -q .name)" \
  -f query='
query($owner:String!,$name:String!){
  repository(owner:$owner,name:$name){
    issues(states:OPEN, first:100, orderBy:{field:UPDATED_AT, direction:DESC}){
      nodes{
        number title body updatedAt
        milestone{title}
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
  --jq '[.data.repository.issues.nodes[] | {
    number, title,
    body: (.body // ""),
    updated: .updatedAt,
    labels: [.labels.nodes[].name],
    milestone: (.milestone.title // null),
    wip: ([.timelineItems.nodes[] | (.source // .subject) | .state]
          | map(select(. == "OPEN")) | length > 0)
  }]' > /tmp/status_issues.json
```

## Forgejo

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`). No GraphQL, so PR↔issue links come from the open PRs themselves.

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')

# 1) issue numbers referenced by OPEN pull requests
tea api --login git-home "repos/$repo/pulls?state=open&limit=50&type=pulls" \
  | python3 -c '
import sys, json, re
wip=set()
pat=re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", re.I)
for p in json.load(sys.stdin):
    for n in pat.findall((p.get("title") or "")+" "+(p.get("body") or "")): wip.add(int(n))
    m=re.match(r"issue-(\d+)", (p.get("head") or {}).get("ref","") or "")
    if m: wip.add(int(m.group(1)))
print(" ".join(map(str, sorted(wip))))' > /tmp/fj_wip.txt

# 2) open issues → normalized JSON
tea api --login git-home "repos/$repo/issues?state=open&type=issues&limit=100&sort=updated&order=desc" \
  | python3 -c '
import sys, json
wip=set(int(x) for x in open("/tmp/fj_wip.txt").read().split())
out=[]
for i in json.load(sys.stdin):
    ms=i.get("milestone") or {}
    out.append({
        "number": i["number"],
        "title": i["title"],
        "body": i.get("body") or "",
        "updated": i.get("updated_at"),
        "labels": [l["name"] for l in i.get("labels") or []],
        "milestone": ms.get("title"),
        "wip": i["number"] in wip,
    })
json.dump(out, open("/tmp/status_issues.json","w"))'
```

## Render

Shared by both forges. Reads `/tmp/status_issues.json`, writes `/tmp/STATUS.md`.

Blocker parsing delegates to **`parse-chain.sh`** — the `Blocked by:` marker format
lives there and nowhere else. Do not re-implement the regex here; if the marker
format changes, `parse-chain.sh` is the one place to change it.

```bash
PARSE_CHAIN="$HOME/.claude/scripts/parse-chain.sh"
[ -f "$PARSE_CHAIN" ] || PARSE_CHAIN="scripts/parse-chain.sh"

PARSE_CHAIN="$PARSE_CHAIN" python3 - <<'PY' > /tmp/STATUS.md
import json, os, subprocess, datetime, collections

issues = json.load(open("/tmp/status_issues.json"))
parse_chain = os.environ["PARSE_CHAIN"]
open_numbers = {i["number"] for i in issues}

def blockers(body):
    if "Blocked by" not in body:
        return []
    try:
        out = subprocess.run(["bash", parse_chain], input=body, text=True,
                             capture_output=True,
                             env={**os.environ, "ISSUE_BODY": ""})
    except Exception:
        return []
    for line in out.stdout.splitlines():
        if line.startswith("blocked-by="):
            return [r for r in line[len("blocked-by="):].split() if r]
    return []

PRIO = {"P0", "P1", "P2"}

def state(i, blks):
    labels = i["labels"]
    if "parked" in labels: return "Parked"
    if "roadmap" in labels:   return "Roadmap"
    if i["wip"]:              return "WIP"
    # a blocker still in the open set blocks; anything else is closed
    if any(int(b.lstrip("#")) in open_numbers for b in blks): return "Blocked"
    return "Ready"

def prio(i):
    for l in i["labels"]:
        if l in PRIO: return l
    return "—"

def cell(s):
    return (s or "").replace("|", "\\|").strip()

def rel(ts):
    if not ts: return "—"
    t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    d = (datetime.datetime.now(datetime.timezone.utc) - t).days
    return "today" if d == 0 else (f"{d}d" if d < 30 else f"{d//30}mo")

rows = []
for i in issues:
    blks = blockers(i["body"])
    rows.append({**i, "blockers": blks, "state": state(i, blks), "prio": prio(i)})

counts = collections.Counter(r["state"] for r in rows)
order = ["Blocked", "WIP", "Ready", "Roadmap", "Parked"]
summary = " · ".join(f"{counts[s]} {s.lower()}" for s in order if counts[s])

L = ["# Status", "",
     "<!-- generated by /status — do not hand-edit; regenerate instead -->", "",
     f"Open issues: **{len(rows)}** — {summary or 'none'}. "
     f"Generated {datetime.date.today().isoformat()}.", "",
     "Issues are canonical; this file is a cache so a fresh session can orient in "
     "one read. Blocked-by comes from the `Blocked by:` marker in the issue body.",
     ""]

def table(rs):
    out = ["| # | Title | Prio | Blocked by | State | Updated |",
           "| --- | --- | --- | --- | --- | --- |"]
    for r in sorted(rs, key=lambda r: (order.index(r["state"]), r["prio"], -r["number"])):
        out.append(f"| #{r['number']} | {cell(r['title'])} | {r['prio']} | "
                   f"{' '.join(r['blockers']) or '—'} | {r['state']} | "
                   f"{rel(r['updated'])} |")
    return out

active = [r for r in rows if r["state"] not in ("Parked", "Roadmap")]
milestones = collections.defaultdict(list)
for r in active:
    milestones[r["milestone"]].append(r)

for name in sorted((m for m in milestones if m), key=str.lower):
    L += [f"## {name}", ""] + table(milestones[name]) + [""]

if None in milestones:
    L += ["## Unscheduled", "",
          "No milestone assigned — triage with `/triage` or schedule with "
          "`/milestone`.", ""] + table(milestones[None]) + [""]

for label, cmd in (("Roadmap", "/roadmap list"), ("Parked", "/parked")):
    if counts[label]:
        L += [f"**{label}:** {counts[label]} issue(s) — list with `{cmd}`.", ""]

L += ["---", "", "Regenerate with `/status write`. Never edit this file by hand."]
print("\n".join(L))
PY
```

Then, depending on the verb:

- `show` → print `/tmp/STATUS.md` to the conversation, then remove it. Change
  nothing in the working tree.
- `write` → `cp /tmp/STATUS.md STATUS.md`, then report the summary line and
  `git diff --stat -- STATUS.md`. Do **not** commit.

If `/tmp/status_issues.json` is an empty array, say the repo has no open issues,
write a `STATUS.md` containing just the banner and that sentence, and stop.

## Wiring it up

`STATUS.md` only pays for itself if agents actually read it. In a consumer repo:

- Reference it from `CLAUDE.md` with `@STATUS.md` so it loads with project context.
- Regenerate at the end of `/done` and `/wrap-up`, so staleness is bounded by one
  work session rather than by memory.

## Unknown host

Report the detected host and that no authed GitHub or Forgejo login matched it;
point at `gh auth login` / `tea login add`. Don't guess a forge.

My arguments:
$ARGUMENTS

---

If you hit a blocker (GraphQL field renamed, `tea` flags differ, `parse-chain.sh`
not linked), find a fix and update this command for the future.
````

## Example output

What `STATUS.md` looks like in a repo with two milestones and one unscheduled item:

````markdown
# Status

<!-- generated by /status — do not hand-edit; regenerate instead -->

Open issues: **7** — 1 blocked · 2 wip · 3 ready · 1 parked. Generated 2026-08-24.

Issues are canonical; this file is a cache so a fresh session can orient in one
read. Blocked-by comes from the `Blocked by:` marker in the issue body.

## v0.9 — gate evidence

| # | Title | Prio | Blocked by | State | Updated |
| --- | --- | --- | --- | --- | --- |
| #214 | Emit structured gate results | P0 | — | WIP | today |
| #216 | Metrics from gate results | P0 | #214 | Blocked | 2d |
| #215 | Declare gate taxonomy | P1 | — | Ready | 4d |

## v1.0 — forge parity

| # | Title | Prio | Blocked by | State | Updated |
| --- | --- | --- | --- | --- | --- |
| #198 | Forge-agnostic commands | P1 | — | WIP | today |
| #203 | tea milestone read-back | P2 | — | Ready | 9d |

## Unscheduled

No milestone assigned — triage with `/triage` or schedule with `/milestone`.

| # | Title | Prio | Blocked by | State | Updated |
| --- | --- | --- | --- | --- | --- |
| #221 | API compatibility gate | — | — | Ready | 1d |

**Parked:** 1 issue(s) — list with `/parked`.

---

Regenerate with `/status write`. Never edit this file by hand.
````

## Open questions before landing

- **Regeneration hook.** Adding it to `/done` and `/wrap-up` is the cheap option.
  A `post-merge` git hook would be tighter but fires on machines that may not have
  `gh`/`tea` authed.
- **Sort order.** Currently blocked-first, then WIP, then ready. Argument for
  WIP-first: it is what you are actually holding. Easy to flip in `order`.
- **Multi-repo.** This is per-repo by design. The cross-repo view is `bridge`'s job
  (`cross_forge_status`, `bridge next`) and should not be duplicated here.
- **`Spec` column.** Blocked on there being a machine-readable enrichment marker.
