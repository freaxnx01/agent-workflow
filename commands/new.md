---
description: Create an issue from notes, labeled needs-enrichment
argument-hint: <notes describing the issue>
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## GitHub

Create a GitHub issue in the current repo with `gh issue create`.

- **Title**: `<type>(<scope>): <concise summary>` per ai-instructions'
  [Issue Title Conventions](https://github.com/freaxnx01/ai-instructions/blob/main/.ai/base-instructions.md#issue-title-conventions)
  — same Conventional Commits format as this org's commits/PR titles.
  Classify my notes as `feat` (a new capability — "add", "support for", a new
  mode/screen/entry point), `fix` (something is broken, wrong, or behaves
  unexpectedly and should be corrected), or `chore` (maintenance — refactor,
  docs, cleanup, tooling, deps); `test`/`ci`/`perf` apply too if that's what
  the notes describe. This is a judgment call on what the notes actually
  describe, not a keyword match. `<scope>` is optional — include it when
  there's an obvious one, omit it (`type: summary`, no parens) when there
  isn't. Don't add a `type:*` label for this — the title prefix is the whole
  signal, see the linked convention.
- **Body**: my notes, lightly cleaned up — keep my meaning, don't invent scope or
  pad. Add a short context line only if it's obvious from the repo.
- **Label**: `needs-enrichment` (always). If that label doesn't exist yet, create
  it first (`gh label create needs-enrichment` with a sensible color), then retry.
- **Milestone**: see [Milestone selection (GitHub)](#milestone-selection-github)
  below. It replaces the old "only if my notes name one, otherwise don't set one
  and don't ask" rule.
- Don't assign or add other labels unless I said so.

Write the cleaned-up notes to a temp file first (`mktemp`) — `--body-file` needs a
path, not inline text — then pass it as `<notes-file>`:

```bash
gh issue create --title "<type>(<scope>): <concise title>" --body-file <notes-file> \
  --label needs-enrichment [-m "<milestone>"]
```

After creating, print the issue number, title, and URL — **read back** rather than
trusting the exit code (`gh issue create` has been seen exiting `0` while silently
dropping the label). Report the milestone from the read-back; when the fallback
should have assigned `backlog` and the read-back shows none, say so rather than
claiming it. If there's no `gh`/repo context, say so and stop.

```bash
gh issue view <number> --json number,title,url,labels,milestone
```

### Milestone selection (GitHub)

**Four cases, in order — the first that matches wins.** Resolve the repo once:
`repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)`.

**1 — My notes name a milestone.** Pass it as `-m "<name>"`. If it doesn't exist
yet, **ask** me before creating it (and ask for a due date); never create one
silently. If I give no due date, omit `-f due_on=…` entirely — never pass an empty
value. `gh milestone` doesn't exist, so create it with `gh api`, sending the due
date at **midday UTC** — GitHub keeps only the date and reads it back as
`T00:00:00Z`. On 2026-10-16 a midnight-UTC write read back one day early (cause
not established), while `T12:00:00Z` kept the requested date:

```bash
gh api "repos/$repo/milestones" -f title="<name>" -f due_on="<YYYY-MM-DD>T12:00:00Z"
```

If my notes name no milestone, read the open ones. **`backlog` is the fallback
bucket, not an active milestone** (ai-instructions#61): list only the **active**
ones — open and not titled `backlog` — **sorted locally**, see *The sort rule*
below, and separately check whether `backlog` exists. Take case 2, 3, or 4 by how
many active milestones came back:

```bash
gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq 'sort_by(.due_on // "9999") | map(select(.title != "backlog")) | .[] | [.title, (.due_on // "-")] | @tsv'
gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq 'map(select(.title == "backlog")) | length'
```

The second prints `1` when `backlog` exists and `0` when it does not. The match is
the exact, case-sensitive title.

**2 — Zero active milestones.** Assign `backlog` with `-m "backlog"`, silently,
and report it from the read-back (same discipline as case 3). `/new` no longer
offers or creates a monthly general bucket.

**3 — Exactly one active milestone.** Assign it silently with `-m "<name>"`. The
read-back must show it: a silent assignment is always *reported*, never implicit.
`backlog` is not counted, so a repo holding one other milestone plus `backlog`
lands here, not in case 4.

**4 — Two or more active milestones.** Ask. Offer the active titles in sorted
order, then `backlog` as the last option, and the **first active entry is the
proposal** (pre-selected). Rules:

- **Silence is never an assignment *to an active milestone*.** No answer, or a
  declined question, means `backlog`.
- **`backlog` replaces the old "no milestone" option.** There is no un-milestoned
  answer while `backlog` exists.
- This pre-selection does **not** contradict `/milestone triage`'s "No default
  milestone, no inferring from labels or title". That rule forbids assigning
  *without an explicit answer*, which this still requires for an active
  milestone. Don't "fix" the apparent contradiction by removing the pre-selection.
- A picker caps at four options, so above three active milestones it can't hold
  them all plus `backlog` — fall back to a numbered plain-text list that names the
  first entry as the proposal and lists `backlog` last.

**`backlog` missing** (the second command printed `0`). Say so in the output —
"no `backlog` milestone in `<repo>`; create it with `/milestone new backlog`" —
and **never create it from `/new`**; it is created by hand, with `/milestone`'s
confirmation and due-date rules. A closed `backlog` counts as missing, and
`/milestone new backlog` reports the closed one and stops. Where the fallback was
needed (case 2, or case 4 with no answer) file the issue with **no milestone** and
say that in the report; the issue is the deliverable, so a missing bucket never
aborts filing. In case 4 the `backlog` option is then left out.

**The sort rule.** `sort_by(.due_on // "9999")` — soonest due first, **undated
last**. Do **not** use the API's own `sort=due_on&direction=asc`: it returns
undated milestones **first**, which would propose an undated milestone over a
dated one (verified 2026-09-09 against a repo holding one of each). The `"9999"`
sentinel is the same idiom the Forgejo sections below already use.

**`/new` never guesses roadmap/parked intent from my notes.** At creation time an
issue carries only `needs-enrichment` — nothing adds those labels. What happens
to the milestone of an issue *entering* those states belongs to `/roadmap defer`
and `/parked repark` (#644), not to `/new`.

My notes:
$ARGUMENTS

## Forgejo

Create an issue in the current Forgejo repo with **`tea`** (login `git-home`).

- **Title**: `<type>(<scope>): <concise summary>` — same classification and
  format as the GitHub section above.
- **Body**: my notes, lightly cleaned up — keep my meaning, don't invent scope or
  pad. Add a short context line only if it's obvious from the repo.
- **Label**: `needs-enrichment` (always). If that label doesn't exist yet, create it
  first, then retry.
- **Milestone**: see [Milestone selection (Forgejo)](#milestone-selection-forgejo)
  below. It replaces the old "only if my notes name one, otherwise don't set one
  and don't ask" rule.
- Don't assign or add other labels unless I said so.

```bash
# create the label if missing (idempotent: ignore "already exists")
tea labels create --login git-home --name needs-enrichment --color "#d4c5f9" \
  --description "Needs a spec/plan before an agent can implement" 2>/dev/null || true

# create the issue — NOTE: tea uses --description / -d for the body (not --body)
tea issues create --login git-home \
  --title "<type>(<scope>): <concise title>" \
  --description "<cleaned-up notes>" \
  --labels needs-enrichment \
  -m "<milestone>"            # the case 1-4 result, backlog included
```

`tea api` needs the explicit `owner/name` path (plain `tea` subcommands infer it
from cwd):

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
```

After creating, print the issue number, title, and URL — **read back** rather than
trusting the exit code (a forge CLI can exit `0` while silently dropping a field
the token lacked permission for, same as `gh issue create` has with a label).
Report the label and the milestone from the read-back, not from the write:

```bash
tea api --login git-home "repos/$repo/issues/<number>" | python3 -c '
import sys, json
i = json.load(sys.stdin)
labels = [l["name"] for l in i.get("labels", [])]
m = i.get("milestone") or {}
print(i["number"], i["title"], i.get("html_url") or "-", labels, m.get("title") or "-", sep="\t")'
```

If there's no `tea` login or repo context (not inside a Forgejo clone, or remote
isn't `git.home.freaxnx01.ch`), say so and stop.

### Milestone selection (Forgejo)

Same four cases as the GitHub section — **the first that matches wins** — with
`tea` mechanics. The behavioural rules (confirm before creating, declining never
aborts issue creation, silence is never an assignment to an active milestone,
`backlog` as the fallback, no roadmap/parked guessing) are identical and are not
restated here; read them there.

**1 — My notes name a milestone.** Pass it as `-m "<name>"`. If it doesn't exist
yet, **ask** before creating it (and ask for a due date); never create one
silently. If I give no due date, omit `--deadline` entirely — never pass an empty
value.

Otherwise read the open milestones. This is the existing `/milestone list` idiom,
and its `"9999"` sentinel is already the sort rule — soonest due first, **undated
last**. `backlog` is the fallback bucket, not an active milestone, so the snippet
prints the **active** ones as `active` rows and reports `backlog` on its own line:

```bash
tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
ms = json.load(sys.stdin)
for m in sorted(ms, key=lambda x: x.get("due_on") or "9999"):
    if m["title"] != "backlog":
        print("active", m["title"], m.get("due_on") or "-", sep="\t")
print("backlog", "yes" if any(m["title"] == "backlog" for m in ms) else "no", sep="\t")
'
```

**2 — Zero active milestones.** Assign `backlog` with `-m "backlog"`, silently,
and report it from the read-back. The monthly general bucket is no longer offered
or created.

**3 — Exactly one active milestone.** Assign it silently, and let the read-back
report it. `backlog` is not counted.

**4 — Two or more active milestones.** Ask, first active entry pre-selected, then
`backlog` as the last option; silence or a decline means `backlog`.

**`backlog` missing** (the snippet's last line says `no`). Say so — "no `backlog`
milestone in `<repo>`; create it with `/milestone new backlog`" — and never create
it from `/new`. Where the fallback was needed, file the issue with no milestone and
say so; leave the `backlog` option out of case 4.

`tea`'s milestone flags carry the same epistemic caveat as `/milestone`'s — verified
from tea's source, not a live run. If one misbehaves, fix it and update this command.

My notes:
$ARGUMENTS

If you hit a blocker (label create rejects the color format, repo not resolvable),
find a fix and update this command for the future. The `-m "<milestone>"` flag on
`tea issues create` above is likewise unverified against a live run — same
epistemic status as `/milestone`'s flags — so check it against tea's own source
if it misbehaves, and update this command.

## Azure DevOps

Create a **work item** from notes.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
source "$HOME/.claude/scripts/lib/azdo.sh"
resolve_azdo_context || { echo "not an Azure DevOps remote"; exit 1; }
```

### Pick the type first

There is no universal default. **Which types exist is template-specific** — a
Basic project offers `Issue`, `Epic`, `Task` and the test/feedback types and has
**no `Bug` at all**, while an Agile-derived one does. Read the list and choose
from it rather than assuming:

```bash
azdo_work_item_types
```

If the notes describe a defect and no defect-shaped type exists, say so and use
the project's general type rather than inventing one.

### Create

Create **Markdown-format** items, so the body is stored verbatim and `/enrich`
can later inline the plan (ADR-025). `azdo_create_markdown_item` takes the type,
title, area, tags and a body file. Set the Area Path, or the item lands at the
project root and will not be found by any of the repo-scoped queries in
`/issues`, `/queue` or `/triage`:

```bash
body_file="$(mktemp)"; trap 'rm -f "$body_file"' EXIT
printf '%s\n' "<body>" > "$body_file"
azdo_create_markdown_item "<type>" "<title>" "$AZDO_PROJECT\\$AZDO_REPO" "" "$body_file"
```

The tags argument is the semicolon-delimited `System.Tags` string; empty
creates the item without tags.

**No milestone fallback here.** A milestone on this forge is an iteration (ADR-012)
and this create sets only Area Path and description, so the `backlog` fallback
`/new` applies on GitHub and Forgejo does not apply to a work item.

**Do not apply `needs-enrichment`.** That tag exists to gate GitHub's
`/gh:implement`, and there is no pipeline dispatch on this forge (ADR-017), so it
would signal a readiness state nothing here acts on.

### Tags afterwards

If the item needs tags beyond creation, use **`azdo_set_tags`**, not a second
`--fields` call: that form appends and cannot clear, so it can only ever grow the
list. The tags here are plain ASCII — `parked`, `roadmap` — because Azure DevOps
rejects emoji in tag names (ADR-016).

### Report from a read-back

Re-read the created item and report what it says, not what the create returned.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
