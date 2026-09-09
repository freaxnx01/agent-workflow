---
description: Enrich an issue with a spec and implementation plan, then update the issue body so it's ready to implement
argument-hint: <issue number> [--quick]
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## Argument parsing

`$ARGUMENTS` may carry `--quick` alongside the issue number. Parse it in this block:

```bash
source "$HOME/.claude/scripts/lib/parse-enrich-args.sh"
parsed=$(parse_enrich_args "$ARGUMENTS") || { echo "Issue number is required. Usage: /enrich <issue-number> [--quick]" >&2; exit 1; }
ISSUE=$(echo "$parsed" | sed -n 's/^ISSUE=//p')
QUICK=$(echo "$parsed" | sed -n 's/^QUICK=//p')
```

Since each fenced bash block runs as a separate shell invocation, the variables `$ISSUE` and `$QUICK` set above **will not persist** to the blocks below. After parsing, substitute the resolved issue number (a digit, not a variable) directly into each command below. For example, if you parsed `256 --quick`, you would write `gh issue view 256` not `gh issue view $ISSUE`.

## Quick mode

When `/enrich` runs with the `--quick` flag, brainstorming suppresses all clarifying questions and the user approval gate — treat the spec as approved the moment brainstorming's own self-review passes. **Exception: escalate on [one-way doors](#one-way-door) (irreversible operations, anything touching credentials, anything that spends money, anything changing a public interface others depend on) — stop and ask the user instead of deciding alone.** The run produces two new sections in the issue body:

**Assumptions format** — one entry per unaided decision, with rejected alternative and evidence:

```markdown
- **A1** [high] Implemented as data additions to the existing SEAS array.
  Rejected: a new quiz mode. `index.html:941-949` shows the seas mode is already
  a generic "named water body → pin on map" mechanism.
```

Confidence is `[high]`/`[med]`/`[low]` — how likely the human is to disagree, not how sure the agent is that it works. `[low]` where the repo gave no signal. `file:line` required for any claim about existing behaviour (regardless of confidence marker).

**Consequences section** contains effects that were *not* decisions — shifted distributions, pacing, adjacent behaviour. Decisions go in Assumptions; consequences are what nobody chose but everybody inherits. Example:

```markdown
## Consequences

- Pacing: each entry adds ~50ms to page load in browser-parsing mode.
- Side effect: adding a sea also marks it as "recently modified" for recommendation sorting.
```

## GitHub

Enrich GitHub issue #$ISSUE (strip any leading `#`) so it is ready for the
agent-workflow. The pipeline reads only the issue **body** — everything the agent
needs must end up there.

### Step 1 — Read the issue

```bash
gh issue view $ISSUE --comments
```

If the issue is closed, already has `ai-implement` label, or is `🧊 parked`, stop and say so.

### Step 1.5 — Check for an existing enrichment lock

If the issue carries the `enrichment-ongoing` label, another session may already be
enriching it. Scan the comments already fetched in Step 1 for the most recent line
matching:

```text
🔒 Enrichment lock (re-)acquired at <timestamp>
```

Compute its age against the current UTC time:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
```

- No `enrichment-ongoing` label → continue to Step 2.
- Label present, a matching comment found, age < 24 hours → **stop**. Tell the user
  the issue is already being enriched (show the age) and end the command — do not
  run Step 2 or start brainstorming.
- Label present, age ≥ 24 hours, **or** no matching comment found (treat unknown age
  as stale) → tell the user the lock looks abandoned (show age and the 24h
  threshold) and ask whether to take over.
  - No → stop.
  - Yes → continue to Step 2; Step 2.5 will re-acquire the lock and note the
    takeover.

Remember which lock comments you saw here — Step 2.5's race re-check needs to tell
them apart from ones posted after this point.

### Step 2 — Assess readiness

Judge whether the issue already has all three:

- **Acceptance criteria** — concrete, testable conditions
- **Scope / spec** — what to build, enough to start without guessing
- **No blocking unknowns** — no open design questions or TBDs the agent can't resolve from the codebase

If the issue is already complete, tell the user and suggest running `/work <issue-number>` directly (where `<issue-number>` is the parsed issue number). Stop here.

### Step 2.5 — Acquire the enrichment lock

Before starting brainstorming — the expensive shared resource two sessions could
collide on — claim the lock so a second session can detect this one. Make sure the
label exists first:

```bash
gh label create enrichment-ongoing --color FBCA04 \
  --description "Another /enrich session is actively enriching this issue — do not start a second one" \
  2>/dev/null || true
```

**Post the timestamp comment before applying the label.** The label is what Step 1.5
keys on and the comment is what gives it an age, so a label without a matching
comment reads as "unknown age → stale" and invites a takeover — exactly the
detection this is meant to provide. Fresh acquisition (Step 1.5 found no lock):

```bash
gh issue comment $ISSUE --body "🔒 Enrichment lock acquired at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

Takeover of a stale lock (Step 1.5 found one and the user agreed to take over —
substitute the actual age you showed the user for `<Xh>`):

```bash
gh issue comment $ISSUE --body "🔒 Enrichment lock re-acquired at $(date -u +%Y-%m-%dT%H:%M:%SZ) (previous lock stale, <Xh> old)"
```

Note the exact timestamp you posted — the re-check below compares against it. Then
apply the label:

```bash
gh issue edit $ISSUE --add-label enrichment-ongoing
```

**Then re-check for a competitor.** Step 1.5 and this step are not atomic — Step 2's
readiness assessment (and, on the takeover path, a user prompt) sits between them,
so a second session can have passed Step 1.5 and acquired in that gap. Both sessions
would otherwise brainstorm the same issue. Re-fetch the comments:

```bash
gh issue view $ISSUE --comments
```

Look for a `🔒 Enrichment lock (re-)acquired` comment that is **not** the one you
just posted and was **not** already present in Step 1.5. If one exists and its
timestamp is **earlier** than yours (same second → the one listed first wins), you
lost the race. Stand down:

```bash
gh issue comment $ISSUE --body "🔓 Enrichment lock released at $(date -u +%Y-%m-%dT%H:%M:%SZ) (lost race to the lock acquired at <winner timestamp>)"
```

Leave the `enrichment-ongoing` label in place — it's a single boolean the winning
session now depends on, so removing it would unlock an issue that is actively being
enriched. Tell the user another session won the race, and end the command without
brainstorming.

Otherwise the lock is yours — continue to Step 3.

**Releasing early.** From here the lock is held until Step 6 clears it. If the
command stops before reaching Step 6 for any reason the user drives — declining
brainstorming's approval gate in Step 3, or the push verification failing in
Step 5 — release the lock before ending:

```bash
gh issue edit $ISSUE --remove-label enrichment-ongoing
```

No `2>/dev/null || true` on this one: this run applied that label itself, so a
non-zero exit is a real failure, not a missing repo convention. If it fails, tell
the user the lock is still held and has to be removed by hand — otherwise it
blocks the issue for the full 24 hours.

### Step 3 — Brainstorm spec

Invoke **superpowers:brainstorming** with the issue as context. The goal is a
validated spec saved to `<specs-dir>/YYYY-MM-DD-<topic>-design.md` and committed.
Follow the brainstorming skill end-to-end (clarifying questions, approaches,
design sections, spec self-review, user approval gate).

**If `$QUICK` is `yes`:** run brainstorming under the rules in
[Quick mode](#quick-mode) above. Suppress the clarifying questions and the user
approval gate — treat the spec as approved the moment brainstorming's own
self-review passes. Carry the assumptions and consequences forward to Step 6.

### Step 4 — Write implementation plan

After brainstorming exits, invoke **superpowers:writing-plans** to produce the
full task-by-task plan at `<plans-dir>/YYYY-MM-DD-<topic>.md` and commit it.

**Do not stop at writing-plans' own handoff prompt — don't even print it.**
That skill ends by asking "Subagent-Driven or Inline Execution?"; that is
writing-plans' generic ending, not the end of `/enrich`. `/enrich`'s own
execution model is neither of those — the plan goes into the issue body and
gets dispatched via the `ai-implement` label (Step 6), not run locally. So
suppress that question entirely: don't ask it, don't wait for an answer, don't
execute the plan. Treat the plan as written the moment writing-plans exits,
and continue straight to Step 5 — pushing the files and writing the plan into
the issue body is still required, always.

#### Picking `<specs-dir>` / `<plans-dir>` — check gitignore first

Both superpowers skills default to `docs/superpowers/{specs,plans}/`. **Many repos
gitignore `docs/superpowers/`**, so those defaults commit nothing and the paths you
then write into the issue body resolve to nothing for the implementing agent — a
silent failure. Resolve the directories before writing either file:

```bash
for d in docs/ai-notes/specs docs/superpowers/specs; do
  git check-ignore -q "$d/probe.md" && echo "$d IGNORED" || echo "$d ok"
done
```

Prefer whichever sibling convention the repo already uses — look for existing dated
`*-design.md` and plan files and follow them.

Tell the brainstorming and writing-plans skills the resolved path explicitly —
both honour "user preferences for spec/plan location override this default".

### Step 5 — Push to remote

Ensure both the spec and plan files are committed and pushed before touching the
issue body — the body will reference these files by path and the agent must be
able to check them out:

```bash
git push
```

**The spec and plan must reach the branch the implementing agent starts from —
normally `main`.** A plain `git push` from a local-only scratch branch (e.g. a
long-lived `.worktrees/<name>` checkout) publishes nothing the agent can see, and
the body's paths dangle.

**Check whether `main` is protected before deciding how to get them there.** Many
repos require a PR and passing checks, and pushing straight at `main` bypasses that
— git reports it after the fact:

```text
remote: Bypassed rule violations for refs/heads/main:
remote: - Required status check "build-and-test" is expected.
```

That is a rule violation whether or not the content is harmless, and a repo's own
`CLAUDE.md` usually forbids it explicitly. Ask git, don't assume:

```bash
gh api "repos/{owner}/{repo}/branches/main/protection" >/dev/null 2>&1 \
  && echo "protected — open a PR" || echo "unprotected — direct push is fine"
```

**Protected → open a PR** and merge it before Step 6, so the paths in the issue body
resolve:

```bash
git fetch origin && git rebase origin/main
git push -u origin <local-branch>
gh pr create --base main --title "docs(<scope>): add spec and plan for #<issue>" --body "…"
# wait for checks, then merge
gh pr merge <pr> --rebase
```

**Unprotected → push at main directly**, which is what most personal repos want:

```bash
git fetch origin && git rebase origin/main   # main often moved while you were writing
git push origin <local-branch>:main
```

Either way, prove the files landed before proceeding:

```bash
git fetch origin && git ls-tree -r --name-only origin/main -- docs | grep <today>
```

If a PR is required and you cannot merge it yet, say so and stop before Step 6 —
an issue body pointing at paths that are not on `main` is worse than no issue body,
because it reads as complete. Release the lock (see *Releasing early*) so the issue
is not left blocked.

### Step 6 — Update the issue body

The implementing agent should be able to work from the issue body alone — no
extra file reads to orient itself. Replace the issue body with:

1. The original description (keep it — context for humans)
2. An `## Acceptance Criteria` section with the approved AC as a `- [ ]` checklist
3. When `$QUICK` is `yes`, an `## Assumptions` section and a `## Consequences`
   section, before the implementation plan.
4. An `## Implementation Plan` section containing the **full plan content
   inlined verbatim** (not a link) — the task breakdown, file structure, TDD
   steps, and exact code to produce, exactly as written to the plan file in
   Step 4
5. A `## Spec` section with just the relative path to the spec file (linked as
   markdown) — for human/reviewer reference only; the implementing agent
   should not need it

**Never compose the new body from an unverified read.** This step prepends the
*original* description read back in Step 1, so re-fetch it explicitly right before
composing — `gh issue view $ISSUE --json body -q .body > file` can fail on a
transient network error (`dial tcp ...: i/o timeout`) while still creating an
**empty** file. Redirection exits `0`, so nothing looks wrong, and the composed body
silently loses the original description, screenshots, and notes. Editing then
destroys them: the previous body is only recoverable from the issue's edit history.

Fetch with a retry, then assert non-empty before composing:

```bash
for i in 1 2 3; do
  gh issue view $ISSUE --json body -q .body > orig-body.md 2>err.txt \
    && [ -s orig-body.md ] && break
  echo "attempt $i failed: $(cat err.txt)"
done
[ -s orig-body.md ] || { echo "could not read issue body — aborting"; exit 1; }
```

Assert on the composed body before writing it: it starts with the original's first
line, retains every `user-attachments` image reference the original had, and
contains the `## Acceptance Criteria` heading (plus `## Implementation Plan` /
`## Spec` as applicable). Prefer `--body-file` over `--body` — a 40 KB inlined plan
does not belong on a command line.

```bash
gh issue edit $ISSUE --body-file <composed-body-file>
```

#### When the plan does not fit — GitHub caps a body at 65,536 characters

A thorough plan for a multi-task feature can exceed this on its own, before the
description and the AC are added. `gh` rejects the edit outright, so this is a hard
stop rather than a truncation you can ignore. **Check the size before composing:**

```bash
python3 -c "import io,sys;print(len(io.open(sys.argv[1],encoding='utf-8').read()))" <plan-file>
```

If the assembled body would exceed the cap, do **not** silently truncate, and do
**not** fall back to linking the whole plan — the point of Step 6 is an issue body
the implementing agent can work from alone. Instead, elide the *fewest, least
reconstructible* parts:

1. Keep, always: the goal, architecture, Global Constraints, and for every task its
   **Files**, **Interfaces**, and every step heading. This is the plan's structure
   and cannot be inferred.
2. Keep, always: **every code block under a "Write the failing test" step.** The
   plan is TDD-first, so the failing test is the specification of the task. Note
   that a naive largest-first heuristic removes exactly these, because test classes
   are usually the longest blocks in a TDD plan — this rule is what stops that.
3. Elide first, largest-first: long *mechanical* production listings — pure
   delegation, adapter boilerplate, a decorator forwarding a wide interface. These
   are reconstructible from the interface they implement.
4. Replace each elided block with a visible pointer, never a silent cut:

   ````markdown
   ```
   [ full listing in the committed plan file — see the note at the top ]
   ```
   ````

5. Put a note at the **top** of the `## Implementation Plan` section saying the body
   was elided, how large the plan is, what was kept verbatim, and linking the
   committed plan file as the source of truth.

The structural assertion above still applies to the elided body — check it before
writing, not after.

**Also clear the readiness labels** — `needs-enrichment` and `❓ to-be-defined`
mean "not ready yet," and the issue now is. Leaving either on is a silent trap:
`/gh:implement` treats them as a hard stop regardless of what the body says.

```bash
gh issue edit $ISSUE --remove-label needs-enrichment 2>/dev/null || true
gh issue edit $ISSUE --remove-label "❓ to-be-defined" 2>/dev/null || true
gh issue edit $ISSUE --remove-label enrichment-ongoing
```

The third line releases the Step 2.5 lock — enrichment is done, so the issue is
free for another session. The lock *comment* stays as an audit trail; only the
label is removed. The readiness labels go first on purpose: the lock release can
then never be what leaves the issue in `/gh:implement`'s hard-stop state.

`--remove-label` on a label the issue doesn't carry is a no-op, but on a label
that doesn't exist **anywhere in the repo** it errors — many repos only define
some of these conventions. So the first two run on their own lines with
`|| true`. The lock release doesn't: this run applied `enrichment-ongoing`
itself, so a non-zero exit is a real failure — tell the user the lock is still
held and has to be removed by hand, otherwise it blocks the issue for the full
24 hours.

### Step 7 — Confirm

Print:

- Issue URL
- Paths to spec and plan files
- Whether the plan had to be elided to fit the 65,536-character body cap — how many
  blocks of how many, and confirmation that no test code was cut
- "Issue is ready — run `/gh:implement $ISSUE` to trigger the agent-workflow."

---

If you run into blockers (brainstorming skill not available, push fails, issue edit
rejected), find a solution and update this skill for the future.

## Forgejo

Enrich Forgejo issue #$ISSUE (strip any leading `#`) so it is ready to
implement. Everything the implementer needs must end up in the issue **body** (+ the
committed spec/plan it links to).

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`):

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
```

### Step 1 — Read the issue

```bash
tea issues $ISSUE --login git-home
tea api --login git-home "repos/$repo/issues/$ISSUE/comments"
```

If the issue is closed or `🧊 parked`, stop and say so.

### Step 1.5 — Check for an existing enrichment lock

If the issue carries the `enrichment-ongoing` label, another session may already be
enriching it. Scan the comments already fetched in Step 1 for the most recent line
matching:

```text
🔒 Enrichment lock (re-)acquired at <timestamp>
```

Compute its age against the current UTC time:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
```

- No `enrichment-ongoing` label → continue to Step 2.
- Label present, a matching comment found, age < 24 hours → **stop**. Tell the user
  the issue is already being enriched (show the age) and end the command — do not
  run Step 2 or start brainstorming.
- Label present, age ≥ 24 hours, **or** no matching comment found (treat unknown age
  as stale) → tell the user the lock looks abandoned (show age and the 24h
  threshold) and ask whether to take over.
  - No → stop.
  - Yes → continue to Step 2; Step 2.5 will re-acquire the lock and note the
    takeover.

Remember which lock comments you saw here — Step 2.5's race re-check needs to tell
them apart from ones posted after this point.

### Step 2 — Assess readiness

Judge whether the issue already has all three:

- **Acceptance criteria** — concrete, testable conditions
- **Scope / spec** — what to build, enough to start without guessing
- **No blocking unknowns** — no open design questions or TBDs the implementer can't
  resolve from the codebase

If it's already complete, tell me and suggest running `/work <issue-number>` directly (where `<issue-number>` is the parsed issue number).
Stop here.

### Step 2.5 — Acquire the enrichment lock

Before starting brainstorming — the expensive shared resource two sessions could
collide on — claim the lock so a second session can detect this one. Make sure the
label exists first:

```bash
tea labels create --login git-home --name enrichment-ongoing --color "#fbca04" \
  --description "Another /enrich session is actively enriching this issue — do not start a second one" \
  2>/dev/null || true
```

**Post the timestamp comment before applying the label.** The label is what Step 1.5
keys on and the comment is what gives it an age, so a label without a matching
comment reads as "unknown age → stale" and invites a takeover — exactly the
detection this is meant to provide. Fresh acquisition (Step 1.5 found no lock):

```bash
tea api --login git-home -X POST "repos/$repo/issues/$ISSUE/comments" \
  -f body="🔒 Enrichment lock acquired at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

Takeover of a stale lock (Step 1.5 found one and the user agreed to take over —
substitute the actual age you showed the user for `<Xh>`):

```bash
tea api --login git-home -X POST "repos/$repo/issues/$ISSUE/comments" \
  -f body="🔒 Enrichment lock re-acquired at $(date -u +%Y-%m-%dT%H:%M:%SZ) (previous lock stale, <Xh> old)"
```

Note the exact timestamp you posted — the re-check below compares against it. Then
apply the label. `tea` has no per-issue label add/remove subcommand, so read the
current labels and PUT back the set with `enrichment-ongoing` added (the same
pattern Step 6 uses to remove labels) — guarding the read, because if it fails or
comes back empty, `locked` ends up empty and the `PUT` wipes **every** label on
the issue:

```bash
current=$(tea api --login git-home "repos/$repo/issues/$ISSUE" | jq -r '[.labels[].name]')
[[ -n "$current" && "$current" != "null" ]] || { echo "failed to read current labels, aborting" >&2; exit 1; }
locked=$(echo "$current" | jq -c '. + ["enrichment-ongoing"] | unique')
tea api --login git-home -X PUT "repos/$repo/issues/$ISSUE/labels" -f labels="$locked" >/dev/null
```

**Then re-check for a competitor.** Step 1.5 and this step are not atomic — Step 2's
readiness assessment (and, on the takeover path, a user prompt) sits between them,
so a second session can have passed Step 1.5 and acquired in that gap. Both sessions
would otherwise brainstorm the same issue. Re-fetch the comments:

```bash
tea api --login git-home "repos/$repo/issues/$ISSUE/comments"
```

Look for a `🔒 Enrichment lock (re-)acquired` comment that is **not** the one you
just posted and was **not** already present in Step 1.5. If one exists and its
timestamp is **earlier** than yours (same second → lowest comment `id` wins), you
lost the race. Stand down:

```bash
tea api --login git-home -X POST "repos/$repo/issues/$ISSUE/comments" \
  -f body="🔓 Enrichment lock released at $(date -u +%Y-%m-%dT%H:%M:%SZ) (lost race to the lock acquired at <winner timestamp>)"
```

Leave the `enrichment-ongoing` label in place — it's a single boolean the winning
session now depends on, so removing it would unlock an issue that is actively being
enriched. Tell me another session won the race, and end the command without
brainstorming.

Otherwise the lock is yours — continue to Step 3.

**Releasing early.** From here the lock is held until Step 6 clears it. If the
command stops before reaching Step 6 for any reason I drive — declining
brainstorming's approval gate in Step 3, or the push verification failing in
Step 5 — release the lock before ending:

```bash
current=$(tea api --login git-home "repos/$repo/issues/$ISSUE" | jq -r '[.labels[].name]')
[[ -n "$current" && "$current" != "null" ]] || { echo "failed to read current labels, aborting" >&2; exit 1; }
kept=$(echo "$current" | jq -c '[.[] | select(. != "enrichment-ongoing")]')
tea api --login git-home -X PUT "repos/$repo/issues/$ISSUE/labels" -f labels="$kept" >/dev/null
```

If either command fails, tell me the lock is still held and has to be removed by
hand — otherwise it blocks the issue for the full 24 hours.

### Step 3 — Brainstorm spec

Invoke **superpowers:brainstorming** with the issue as context. The goal is a
validated spec saved to a **tracked** specs dir (see *Choosing a tracked path*) and
committed. Follow the brainstorming skill end-to-end (clarifying questions,
approaches, design sections, spec self-review, user approval gate).

**If `$QUICK` is `yes`:** run brainstorming under the rules in
[Quick mode](#quick-mode) above. Suppress the clarifying questions and the user
approval gate — treat the spec as approved the moment brainstorming's own
self-review passes. Carry the assumptions and consequences forward to Step 6.

### Step 4 — Write implementation plan

After brainstorming exits, invoke **superpowers:writing-plans** to produce the full
task-by-task plan in a tracked plans dir and commit it.

**Do not stop at writing-plans' own handoff prompt — don't even print it.**
That skill ends by asking "Subagent-Driven or Inline Execution?"; that is
writing-plans' generic ending, not the end of `/enrich`. `/enrich`'s own
execution model is neither of those — the plan goes into the issue body and
gets dispatched via the `ai-implement` label (Step 6), not run locally. So
suppress that question entirely: don't ask it, don't wait for an answer, don't
execute the plan. Treat the plan as written the moment writing-plans exits,
and continue straight to Step 5 — pushing the files and writing the plan into
the issue body is still required, always.

### Step 5 — Push to remote

Commit and push both the spec and plan before touching the issue body — the body
references these files by path:

```bash
git push
```

Verify the push succeeded before proceeding.

### Step 6 — Update the issue body

**Never compose the new body from an unverified read.** `bodyfile.md` prepends the
*original* description read back in Step 1, so re-fetch it explicitly right before
composing — a transient network error can leave the fetch command exit non-zero
while a shell redirect still creates an **empty** file, silently losing the
original description, screenshots, and notes once the PATCH goes through. Recovery
afterward is only possible from the issue's edit history.

Fetch with a retry, then assert non-empty before composing:

```bash
for i in 1 2 3; do
  tea api --login git-home "repos/$repo/issues/$ISSUE" | jq -r '.body' > orig-body.md \
    && [ -s orig-body.md ] && break
  echo "attempt $i failed"
done
[ -s orig-body.md ] || { echo "could not read issue body — aborting"; exit 1; }
```

Assert on the composed `bodyfile.md` before writing it: it starts with the
original's first line, retains every image/attachment reference the original had,
and contains the `## Acceptance Criteria` heading (plus `## Spec & Implementation
Plan` as applicable).

Replace the issue body via API PATCH — use the **typed** field `-F` so it reads the
file (`-f` would store the literal string `@bodyfile.md`; `tea issues edit` has no
body flag):

```bash
tea api -X PATCH "repos/$repo/issues/$ISSUE" -F body=@bodyfile.md
```

The new body has:

1. The original description (keep it — context for humans)
2. An `## Acceptance Criteria` section with the approved AC as a `- [ ]` checklist
3. When `$QUICK` is `yes`, an `## Assumptions` section and a `## Consequences`
   section, before the plan references.
4. A `## Spec & Implementation Plan` section with relative paths to the spec and plan
   files (linked as markdown) plus: *"Read the plan before writing any code — it
   contains the full task breakdown, file structure, TDD steps, and exact code to
   produce."*

**Also clear the readiness labels** — `needs-enrichment` and `❓ to-be-defined` mean
"not ready yet," and the issue now is. `tea` has no per-issue label add/remove
subcommand (`tea labels` only manages repo-level label *definitions*), so read the
issue's current labels and PUT back the set with those names — plus the
`enrichment-ongoing` lock — filtered out:

```bash
current=$(tea api --login git-home "repos/$repo/issues/$ISSUE" | jq -r '[.labels[].name]')
[[ -n "$current" && "$current" != "null" ]] || { echo "failed to read current labels, aborting" >&2; exit 1; }
kept=$(echo "$current" | jq -c '[.[] | select(. != "needs-enrichment" and . != "❓ to-be-defined" and . != "enrichment-ongoing")]')
tea api --login git-home -X PUT "repos/$repo/issues/$ISSUE/labels" -f labels="$kept" >/dev/null
```

The guard on the read matters here too: an empty `current` would PUT an empty set
and wipe **every** label on the issue, `ai-implement` included.

`enrichment-ongoing` goes with them — enrichment is done, so the Step 2.5 lock is
released here. All three clear in one write, so a failure can't release the lock
while leaving a readiness label on. The lock comment posted in Step 2.5 is left
in place as an audit trail; only the label is removed. If the write fails, say so
— the lock is still held and has to be removed by hand.

(This is best-effort against Forgejo's labels API, which has had both name- and
ID-keyed variants across versions — if the `PUT` errors, check `tea api
--login git-home "repos/$repo/issues/$ISSUE/labels"` for the shape this
instance expects and fix this step for the future.)

### Step 7 — Confirm

Print the issue URL, the spec and plan paths, and: *"Issue is ready — run
`/work $ISSUE` to implement it locally."*

> When the self-hosted **Forgejo Actions** agent-workflow exists (future tier), this
> final pointer becomes "apply the `ai-implement` label / run `/fj:implement`" to
> trigger the runner instead — update this step then.

### Choosing a tracked path

A spec/plan is only useful if it's **committed and not git-ignored**. Pick an
existing tracked specs/plans dir; never write to a path that `git check-ignore -q
<path>` reports as ignored — fall back to `docs/ai-notes/{specs,plans}`. Confirm with
`git ls-files` that the committed file is tracked before the push step relies on it.

---

If you run into blockers (brainstorming/writing-plans unavailable, push auth fails,
the issue-body PATCH is rejected, ignored docs dir), find a solution and update this
command for the future.

## One-way door

In quick-mode, a [one-way door](../docs/glossary.md#one-way-door) is a design decision the agent refuses to make alone — irreversible operations (deleting data, running migrations), anything touching credentials or secrets, anything that spends money (rate limits, API calls with costs), or anything changing a public interface others depend on. When quick-mode hits a one-way door, it stops and asks the user to decide, even if the flag is `--quick`. Record the unanswered decision as a Blocked item in the Assumptions block (prefixed with ⛔ or similar) so the human review phase can resolve it before implementation.

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
