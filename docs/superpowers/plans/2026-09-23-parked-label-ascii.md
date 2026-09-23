# Rename `🧊 parked` to `parked` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the parked label a plain-ASCII `parked` on every forge, so it can exist on Azure DevOps at all.

**Architecture:** Three passes in strict order — code paths and their fixtures first, then command prompts and live docs, then the live label rename. The rename goes last because it is the only irreversible step, and it must be a rename-in-place, never a delete-and-create.

**Tech Stack:** Bash 5, `gh` CLI, `jq`, Layer-1 fixture tests, `shellcheck -x`, `markdownlint`.

**Spec:** `docs/superpowers/specs/2026-09-23-parked-label-ascii-design.md`

## Global Constraints

- **Never delete and re-create the label.** `gh label edit '🧊 parked' --name 'parked'` renames in place and preserves every issue association. Delete-and-create would silently unpark every parked issue — the precise outcome the label exists to prevent, and not recoverable without the events API.
- **Do not touch historical records.** `docs/superpowers/specs/`, `docs/superpowers/plans/`, `docs/ai-notes/` and `CHANGELOG.md` describe what was true when written. A July spec saying `🧊 parked` is correct history, not a stale string. Only this plan's own spec and plan are exempt, and they already say `parked`.
- **Fixtures change in the same commit as the code they feed.** A fixture still carrying the emoji would keep a test green over a code path that was missed.
- `PARK_LABEL` keeps its override seam in `check-attempt-cap.sh`; only the default changes.
- `shellcheck -x -e SC1091`, `markdownlint` and `tests/run-all.sh` stay clean.
- Writes to GitHub labels happen only in Task 3, and only after Tasks 1–2 are merged.

---

### Task 1: Move the functional code paths to `parked`

**Files:**
- Modify: `scripts/ensure-issue-labels.sh:89`
- Modify: `scripts/autopilot.sh:222,247`
- Modify: `scripts/check-attempt-cap.sh:22,53`
- Modify: `scripts/lib/ai-funnel.sh:192`
- Modify: `scripts/lib/autopilot-candidates.sh:11,34`
- Modify: the fixtures under `tests/fixtures/` that carry the label string
- Test: `tests/run-autopilot-eligible-tests.sh`, `tests/run-ai-funnel-tests.sh` (whichever exercise the label — find them, do not assume)

**Interfaces:**
- Consumes: nothing.
- Produces: `parked` as the label every code path matches. `PARK_LABEL` remains an env override, now defaulting to `parked`.

- [ ] **Step 1: Find every functional occurrence and its fixtures**

```bash
grep -rn '🧊' --include='*.sh' --include='*.yml' --include='*.json' scripts/ tests/ .github/
```

Record the list. Anything outside `scripts/`, `tests/` and `.github/` is prose or
history and belongs to Task 2 or to neither.

- [ ] **Step 2: Confirm the tests currently pass, so a later failure means something**

```bash
tests/run-all.sh
```

Expected: exit 0. If anything is already red, stop and say so — this plan cannot
tell a pre-existing failure from one it caused.

- [ ] **Step 3: Update the code paths**

Replace the label string with `parked` in each file found in Step 1:

- `scripts/ensure-issue-labels.sh` — `create parked BFD4F2 'Parked for a human — agent attempt cap reached'`. Note the quotes around the name are no longer needed, but keeping them is harmless; prefer minimal diff.
- `scripts/check-attempt-cap.sh` — `PARK_LABEL="${PARK_LABEL:-parked}"`, and the comment on line 22 documenting the default.
- `scripts/autopilot.sh`, `scripts/lib/ai-funnel.sh`, `scripts/lib/autopilot-candidates.sh` — the match strings and the comments naming them.

- [ ] **Step 4: Update the fixtures in the same change**

Any `tests/fixtures/*.json` carrying `🧊 parked` becomes `parked`. This must land in
the same commit as Step 3: a fixture still holding the old string would keep its
test green over a code path that was missed, which is the one way this task can
fail silently.

- [ ] **Step 5: Run the suite**

```bash
tests/run-all.sh
shellcheck -x -e SC1091 scripts/autopilot.sh scripts/ensure-issue-labels.sh scripts/check-attempt-cap.sh scripts/lib/ai-funnel.sh scripts/lib/autopilot-candidates.sh
```

Expected: both exit 0.

- [ ] **Step 6: Prove no functional path was missed**

```bash
grep -rn '🧊' scripts/ tests/ .github/
```

Expected: **no matches**. A hit here is a path that will stop matching parked
issues the moment the label is renamed in Task 3.

- [ ] **Step 7: Commit**

```bash
git add scripts/ tests/
git commit -m "fix(labels): match the parked label as plain ASCII

Azure DevOps rejects emoji in tag names (TF401407), so the parked label cannot
exist there at all and the convention did not port. It was the only emoji-bearing
label in the scheme, so one rename buys portability.

Fixtures move in this commit too: one still carrying the old string would keep its
test green over a code path that was missed.

PARK_LABEL keeps its override seam so a consumer that has not migrated yet can
export the old value.

Refs #397"
```

---

### Task 2: Move the command prompts and live docs

**Files:**
- Modify: the 12 files under `commands/` and `commands/gh/` that reference the label
- Modify: `TODO.md`, `docs/CONSUMER-SETUP.md`, and the command cheat sheet
- **Do not modify:** anything under `docs/superpowers/specs/`, `docs/superpowers/plans/`, `docs/ai-notes/`, or `CHANGELOG.md`

**Interfaces:**
- Consumes: Task 1's decision, already committed.
- Produces: prompts consistent with the code, so an agent reading a command does not apply a label the scripts no longer match.

- [ ] **Step 1: List the prose occurrences, excluding history**

```bash
grep -rln '🧊' --include='*.md' . \
  | grep -vE '^\./(docs/superpowers/(specs|plans)|docs/ai-notes)/' \
  | grep -v CHANGELOG.md
```

- [ ] **Step 2: Update them**

Replace `🧊 parked` with `parked` throughout the listed files. Where a sentence
reads awkwardly without the icon (e.g. "tag it `🧊 parked`"), rewrite the sentence
rather than leaving a dangling article.

- [ ] **Step 3: Document the consumer migration**

Add to `docs/CONSUMER-SETUP.md`, under the labels section:

````markdown
### Migrating an existing repo's parked label

The parked label was `🧊 parked` before 2026-09-23. Azure DevOps rejects emoji in
tag names, so it is now plain `parked`. Rename it **in place** — do not delete and
re-create, which would unpark every parked issue:

```bash
gh label edit '🧊 parked' --name 'parked' --repo <owner>/<repo>
```

Repos onboarded after that date get the new name from `ensure-issue-labels.sh` and
need nothing. If you cannot migrate yet, `export PARK_LABEL='🧊 parked'` keeps
`check-attempt-cap.sh` working against the old name.
````

- [ ] **Step 4: Verify history was left intact**

```bash
git diff --name-only HEAD | grep -E 'superpowers/(specs|plans)|ai-notes|CHANGELOG' && echo "HISTORY TOUCHED — revert those" || echo "history intact"
```

Expected: `history intact`. If any historical file appears, revert it — rewriting
those falsifies the record.

- [ ] **Step 5: Lint and commit**

```bash
markdownlint commands/*.md commands/gh/*.md TODO.md docs/CONSUMER-SETUP.md
git add commands/ TODO.md docs/CONSUMER-SETUP.md
git commit -m "docs(commands): say parked, not the emoji form

Brings the command prompts in line with the scripts, so an agent does not apply a
label the code no longer matches, and documents the in-place rename existing
consumers need.

Historical specs, plans, ai-notes and the changelog are deliberately untouched:
they record what was true when written.

Refs #397"
```

---

### Task 3: Rename the live label

**Files:** none — this task changes GitHub state, not the repo.

**Interfaces:**
- Consumes: Tasks 1 and 2, **merged to `main`**. Renaming before the code ships would leave every script matching a label that no longer exists.

> **Irreversible-ish.** A rename can be reversed by renaming back, but a
> delete-and-create cannot: it drops the label from every issue. Use `label edit`.

- [ ] **Step 1: Record what is parked right now**

```bash
direnv exec ~/repos/github/freaxnx01 gh issue list --repo freaxnx01/agent-workflow \
  --label '🧊 parked' --state all --limit 100 --json number,title
```

Save the numbers. This repo had **2** at the time of writing; confirm the current
count and keep it — Step 3 checks against it.

- [ ] **Step 2: Rename in place**

```bash
direnv exec ~/repos/github/freaxnx01 gh label edit '🧊 parked' --name 'parked' \
  --repo freaxnx01/agent-workflow
```

**Not** `gh label delete` followed by `gh label create`. The rename preserves
associations; delete-and-create silently unparks everything.

- [ ] **Step 3: Verify nothing was unparked**

```bash
direnv exec ~/repos/github/freaxnx01 gh issue list --repo freaxnx01/agent-workflow \
  --label parked --state all --limit 100 --json number,title
```

Expected: **the same issue numbers as Step 1**, same count. If any are missing, the
label was re-created rather than renamed — re-apply it to the issues from Step 1's
saved list immediately.

- [ ] **Step 4: Confirm the scripts see it**

```bash
direnv exec ~/repos/github/freaxnx01 bash -c 'scripts/lib/autopilot-candidates.sh' 2>&1 | head
```

Expected: runs clean and excludes the parked issues. This is the end-to-end check
that Task 1's matching and Task 3's rename agree.

- [ ] **Step 5: Note the consumer repos**

Enumerate the repos consuming agent-workflow and apply Step 2 to each, or record
in `TODO.md` which remain to be migrated. Do not leave this implicit: a consumer
whose label is still the emoji form will stop being detected as parked, and the
symptom is an issue quietly re-entering the dispatch queue.

---

## Verification

```bash
grep -rn '🧊' scripts/ tests/ commands/ .github/     # expect: no matches
grep -rn '🧊' docs/superpowers/ docs/ai-notes/       # expect: matches — history intact
tests/run-all.sh
shellcheck -x -e SC1091 scripts/*.sh scripts/lib/*.sh
markdownlint commands/*.md
```

Then confirm on GitHub that the label reads `parked` and still sits on the same
issues it did before Task 3.

**The greps prove strings, not behaviour.** The check that matters is Step 3 of
Task 3: the same issues parked before and after. A rename that silently unparked
them would pass every grep here.
