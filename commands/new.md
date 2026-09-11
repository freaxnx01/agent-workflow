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
dropping the label). If there's no `gh`/repo context, say so and stop.

```bash
gh issue view <number> --json number,title,url,labels,milestone
```

### Milestone selection (GitHub)

**Four cases, in order — the first that matches wins.** Resolve the repo once:
`repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)`.

**1 — My notes name a milestone.** Pass it as `-m "<name>"`. If it doesn't exist
yet, **ask** me before creating it (and ask for a due date); never create one
silently. If I give no due date, omit `-f due_on=…` entirely — never pass an empty
value. `gh milestone` doesn't exist, so create it with `gh api`:

```bash
gh api "repos/$repo/milestones" -f title="<name>" -f due_on="<YYYY-MM-DD>T00:00:00Z"
```

**Don't normalize the time to midday.** This command used to send `T12:00:00Z`
"so a viewer's timezone can't roll it back a day" — that does not work. GitHub
treats `due_on` as date-only and **normalizes it to `T00:00:00Z` whatever you
send**, on create *and* on PATCH. Verified 2026-09-10 against `freaxnx01/bridge`:
posted `2026-09-30T12:00:00Z`, read back `2026-09-30T00:00:00Z`; a follow-up
PATCH with midday read back midnight again. The timezone concern is real — a
viewer west of UTC does see the previous day — but it is a GitHub display
property the API gives no way to work around, so send midnight (what gets stored
regardless) and don't re-derive the midday trick believing it buys something.

If my notes name no milestone, read the open ones — **sorted locally**, see *The
sort rule* below — and take case 2, 3, or 4 by how many came back:

```bash
gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq 'sort_by(.due_on // "9999") | .[] | [.title, (.due_on // "-")] | @tsv'
```

**2 — Zero open milestones.** Offer to create the month's general bucket,
`general-<month>-<year>` (e.g. `general-september-2026`), due the **30th of that
month clamped to the month length**, so February lands on the 28th/29th:

```bash
month=$(LC_ALL=C date +%B | tr 'A-Z' 'a-z')   # locale-pinned — see below
year=$(date +%Y)
last_day=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)
due_day=$(( last_day < 30 ? last_day : 30 ))

gh api "repos/$repo/milestones" \
  -f title="general-$month-$year" \
  -f due_on="$year-$(date +%m)-${due_day}T00:00:00Z"
```

- **Confirm before creating** — show me the name and the due date and wait for a
  yes. This keeps case 1's "never create one silently" rule intact rather than
  carving an exception into it.
- **Declining must not abort issue creation.** The issue is the deliverable, the
  milestone is secondary: on a no, file the issue with no milestone and say so.
- **`LC_ALL=C` is load-bearing.** Bare `date +%B` is locale-dependent and returns
  `September` (capitalized) even on an English-ish setup, and a translated month
  name elsewhere — either one creates `general-September-2026` once and forks the
  naming permanently.
- **A `422` with `already_exists` means the title is taken by a *closed*
  milestone** — "zero open milestones" is still true. `/milestone`'s rule applies
  verbatim: report the existing milestone and stop. No variant name, no reopen path.
  File the issue with no milestone rather than blocking on it.

**3 — Exactly one open milestone.** Assign it silently with `-m "<name>"`. The
read-back must show it: a silent assignment is always *reported*, never implicit.

**4 — Two or more open milestones.** Ask. Offer the titles in sorted order plus
`none`, and the **first entry is the proposal** (pre-selected). Rules:

- **Silence is never an assignment.** No answer means no milestone.
- **`none` is always offered**, and is a legitimate answer — `roadmap` and
  `🧊 parked` issues are *defined* by having no milestone.
- This pre-selection does **not** contradict `/milestone triage`'s "No default
  milestone, no inferring from labels or title". That rule forbids assigning
  *without an explicit answer*, which this still requires. Don't "fix" the
  apparent contradiction by removing the pre-selection.
- A picker caps at four options, so above three open milestones it can't hold them
  all plus `none` — fall back to a numbered plain-text list that names the first
  entry as the proposal.

**The sort rule.** `sort_by(.due_on // "9999")` — soonest due first, **undated
last**. Do **not** use the API's own `sort=due_on&direction=asc`: it returns
undated milestones **first**, which would propose an undated milestone over a
dated one (verified 2026-09-09 against a repo holding one of each). The `"9999"`
sentinel is the same idiom the Forgejo sections below already use.

**`/new` never guesses roadmap/parked intent from my notes.** At creation time an
issue carries only `needs-enrichment` — nothing adds those labels. The invariant
is enforced on the way *into* those states instead: `/roadmap defer` and
`/parked repark` strip the milestone.

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
  -m "<milestone>"            # only when my notes named one
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
aborts, silence is never an assignment, `none` always offered, no roadmap/parked
guessing) are identical and are not restated here; read them there.

**1 — My notes name a milestone.** Pass it as `-m "<name>"`. If it doesn't exist
yet, **ask** before creating it (and ask for a due date); never create one
silently. If I give no due date, omit `--deadline` entirely — never pass an empty
value.

Otherwise read the open milestones. This is the existing `/milestone list` idiom,
and its `"9999"` sentinel is already the sort rule — soonest due first, **undated
last**:

```bash
tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
for m in sorted(json.load(sys.stdin), key=lambda x: x.get("due_on") or "9999"):
    print(m["title"], m.get("due_on") or "-", sep="\t")'
```

**2 — Zero open milestones.** Offer to create `general-<month>-<year>`, due the
**30th clamped to the month length**. Forgejo has **no `already_exists` guard**
(unlike GitHub's `422`), so check for a closed one of that name first — same rule
as `/milestone new`: on a match, report it and stop, no variant name.

```bash
month=$(LC_ALL=C date +%B | tr 'A-Z' 'a-z')   # locale-pinned, see the GitHub section
year=$(date +%Y)
last_day=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)
due_day=$(( last_day < 30 ? last_day : 30 ))

tea milestones create --login git-home \
  --title "general-$month-$year" \
  --deadline "$year-$(date +%m)-$due_day"
```

`--deadline` takes a bare `YYYY-MM-DD` — `tea` parses loose date strings itself, so
there is no time component to pass here. Both sides now come out the same: the
GitHub section sends midnight because GitHub stores midnight regardless (see
there), so this is no longer the asymmetry it was once documented as. What
Forgejo itself stores for a `--deadline` is **unverified** — nobody has read one
back — so don't assume it matches GitHub until someone checks.

**3 — Exactly one open milestone.** Assign it silently, and let the read-back
report it.

**4 — Two or more open milestones.** Ask, first entry pre-selected, plus `none`.

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
