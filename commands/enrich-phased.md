---
description: Phased enrich (spec → /clear → plan → /clear → issue body), isolated context per phase
argument-hint: <issue number>
---

Detect the forge, then run the matching section below.

```bash
source "$HOME/.claude/scripts/lib/detect-forge.sh"
detect_forge
```

## GitHub

Like `/enrich`, but runs each heavy phase in its **own fresh context**, with a
`/handoff` + `/clear` between phases so brainstorm context doesn't bleed into
plan-writing and plan context doesn't bleed into the issue update. Use this instead
of `/enrich` when the topic is large or the session is already long.

You **cannot** run `/clear` yourself — it's the user's keystroke. So this command is
a **re-entrant state machine**: it runs one phase, records progress, writes a resume
handoff, and stops; after the user `/clear`s and resumes, it picks up the next phase.

### State

Track progress in `.claude/enrich-phased.state` (create `.claude/` if needed), a few
`key=value` lines: `issue=`, `phase=`, `spec=`, `plan=`. This file is the source of
truth for which phase runs next.

On invocation:

1. If an issue number was passed as an argument (strip any leading `#`), this is a
   **new run**: carry the number through this invocation and dispatch to Phase
   `spec`. **Don't write the state file yet** — Phase `spec`'s lock steps can end
   the run before it starts, and a file written now would let a later no-argument
   resume skip them and enrich an issue another session holds a fresh lock on.
   Phase `spec` step 4 writes `issue=<N>` and `phase=spec` once the lock is held.
2. Else read `.claude/enrich-phased.state` and continue from its `phase`. If no
   argument and no state file, tell the user there's nothing to resume and stop.

Then dispatch to the matching phase below.

### Phase `spec`

1. `gh issue view <issue> --comments`. If the issue is closed, already has
   `ai-implement`, or is `🧊 parked`, stop and say so. **On a resume** (a state
   file already existed for this run — see *On invocation*), this run already
   holds the lock from a prior step 4, and stopping here abandons it without
   releasing. Release it first — no `2>/dev/null || true`, since this run
   applied the label itself and a non-zero exit is a real failure, not a
   missing repo convention:

   ```bash
   gh issue edit <issue> --remove-label enrichment-ongoing
   ```

   If it fails, tell the user the lock is still held and has to be removed
   by hand. On a new run there is nothing to release yet (step 4 hasn't run)
   — skip this entirely.
2. **Check for an existing enrichment lock — new runs only.** Skip this step
   entirely on a resume (no argument, continuing from the state file): that is the
   same run continuing, so the only lock it could find is its own. If the issue
   carries the `enrichment-ongoing` label, scan the comments already fetched in
   step 1 for the most recent `🔒 Enrichment lock (re-)acquired at <timestamp>`
   line and compute its age against `date -u +%Y-%m-%dT%H:%M:%SZ`:
   - No `enrichment-ongoing` label → continue to step 3.
   - Label present, a matching comment found, age < 24 hours → **stop**. Tell the
     user the issue is already being enriched (show the age) and end the command.
     No state file exists yet (see *On invocation*), so there is nothing to resume
     into — leave it that way.
   - Label present, age ≥ 24 hours, or no matching comment found (treat unknown age
     as stale) → tell the user the lock looks abandoned (show age and the 24h
     threshold) and ask whether to take over.
     - No → stop, same as above.
     - Yes → continue to step 3; step 4 will re-acquire the lock and note the
       takeover.

   Remember which lock comments you saw here — step 4's race re-check has to tell
   them apart from ones posted after this point.
3. Assess readiness (acceptance criteria + scope + no blocking unknowns). If it's
   already complete, say so, suggest `/gh:implement <issue>`, and stop. **On a
   resume**, a state file exists here (written by a prior step 4) and this run
   holds the lock — release it before deleting the file, same as step 1's
   resume path:

   ```bash
   gh issue edit <issue> --remove-label enrichment-ongoing
   ```

   If it fails, tell the user the lock is still held and has to be removed by
   hand. **On a new run**, no state file exists yet (step 4 hasn't run) and
   there is nothing to release — just confirm no file exists and stop.
4. **Acquire the enrichment lock — new runs only**, same gate as step 2: on a
   resume skip this step entirely and go straight to step 5, since the lock is
   already held from the original acquisition. Running it again would post a second
   lock comment and then lose the race re-check below to the run's own earlier
   lock, dead-ending every future resume. Acquire before brainstorming — the
   expensive shared resource two sessions could collide on. Make sure the label
   exists first:

   ```bash
   gh label create enrichment-ongoing --color FBCA04 \
     --description "Another /enrich session is actively enriching this issue — do not start a second one" \
     2>/dev/null || true
   ```

   Post the timestamp comment before applying the label — a label with no matching
   comment reads as "unknown age → stale" to step 2's check, defeating detection.
   Fresh acquisition (step 2 found no lock):

   ```bash
   gh issue comment <issue> --body "🔒 Enrichment lock acquired at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
   ```

   Takeover of a stale lock (step 2 found one and the user agreed to take over —
   substitute the actual age you showed the user for `<Xh>`):

   ```bash
   gh issue comment <issue> --body "🔒 Enrichment lock re-acquired at $(date -u +%Y-%m-%dT%H:%M:%SZ) (previous lock stale, <Xh> old)"
   ```

   Note the exact timestamp you posted, then apply the label:

   ```bash
   gh issue edit <issue> --add-label enrichment-ongoing
   ```

   **Verify this succeeded before continuing.** If it fails, the run does not
   hold the lock even though the timestamp comment claims it does — abort
   without brainstorming and tell the user the lock could not be acquired.
   The state file isn't written until after the race re-check below
   succeeds, so there's nothing to clean up here.

   **Then re-check for a competitor** — step 2 and this step are not atomic (the
   readiness check, and on the takeover path a user prompt, sit between them).
   Re-fetch comments:

   ```bash
   gh issue view <issue> --comments
   ```

   Look for a `🔒 Enrichment lock (re-)acquired` comment that is **not** the one you
   just posted and was **not** already present at step 2. If one exists and its
   timestamp is earlier than yours (same second → the one listed first wins), you
   lost the race. Stand down:

   ```bash
   gh issue comment <issue> --body "🔓 Enrichment lock released at $(date -u +%Y-%m-%dT%H:%M:%SZ) (lost race to the lock acquired at <winner timestamp>)"
   ```

   Leave the `enrichment-ongoing` label in place — the winning session depends on
   it. Tell the user another session won the race and end the command without
   brainstorming; still no state file, so nothing can resume past this.

   Otherwise the lock is yours. **Now write the state file** — `issue=<N>` and
   `phase=spec` — and continue to step 5. This is its first write: a run that
   stopped at step 2 or lost the race leaves no file behind, so it can never be
   resumed past the check that stopped it.
5. Invoke **superpowers:brainstorming** with the issue as context. Follow it
   end-to-end — clarifying questions, approaches, design sections, the spec
   self-review, and the **user approval gate**. Save the spec to the repo's tracked
   specs dir (see *Choosing a tracked path*), commit it, and record `spec=<path>`.

   **If the user declines the approval gate** (does not approve the spec), the run
   is over — not paused. Release the lock and delete `.claude/enrich-phased.state`
   before stopping:

   ```bash
   gh issue edit <issue> --remove-label enrichment-ongoing
   ```

   No `2>/dev/null || true` on this one: this run applied that label itself, so a
   non-zero exit is a real failure, not a missing repo convention. If it fails,
   tell the user the lock is still held and has to be removed by hand — otherwise
   it blocks the issue for the full 24 hours.
6. **Phase boundary** (see *Between phases*): set `phase=plan`, hand off, stop.

### Phase `plan`

1. Re-open the spec at `spec=` to re-establish context.
2. Invoke **superpowers:writing-plans** to produce the task-by-task implementation
   plan in the repo's tracked plans dir. Commit it and record `plan=<path>`.
   **Do not stop at writing-plans' own "Subagent-Driven or Inline Execution?"
   handoff prompt — don't even print it.** That's the skill's generic ending, not
   this phase's; `/enrich-phased` dispatches via the issue body + `ai-implement`
   label, not local execution. Suppress the question entirely: don't ask it,
   don't wait for an answer, don't execute the plan. Treat it as written the
   moment the skill exits and continue to step 3.
3. **Push** so both spec and plan are on the remote (the agent-workflow checks them
   out): `git push`. Verify it succeeded.
4. **Phase boundary:** set `phase=issue`, hand off, stop.

### Phase `issue`

1. Replace the issue body (`gh issue edit <issue> --body-file …`) with:
   - the original description (keep it for humans),
   - an `## Acceptance Criteria` section as a `- [ ]` checklist,
   - an `## Implementation Plan` section with the **full plan content inlined
     verbatim** (not a link) — read `plan=` and paste its contents in, so the
     implementing agent can work from the issue body alone with no extra file reads,
   - a `## Spec` section with just the relative path to `spec=` (linked as
     markdown) — human/reviewer reference only, not needed by the implementing agent.
2. Clear the readiness labels — `needs-enrichment` and `❓ to-be-defined` mean
   "not ready yet," and the issue now is. `/gh:implement` treats either as a
   hard stop regardless of body content, so leaving one on is a silent trap.
   Then release the enrichment lock acquired back in Phase `spec` — the run is
   done, nothing else will clear it:

   ```bash
   gh issue edit <issue> --remove-label needs-enrichment 2>/dev/null || true
   gh issue edit <issue> --remove-label "❓ to-be-defined" 2>/dev/null || true
   gh issue edit <issue> --remove-label enrichment-ongoing
   ```

   The readiness labels go first on purpose: the lock release can then never be
   what leaves the issue in `/gh:implement`'s hard-stop state. They run on their
   own lines with `|| true` because a repo that doesn't define one of those two
   conventions would otherwise error on the `--remove-label`. The lock release
   doesn't — this run applied that label itself, so a non-zero exit is a real
   failure: tell the user the lock is still held and has to be removed by hand,
   otherwise it blocks the issue for the full 24 hours.
3. Push if anything else is pending.
4. **Done:** delete `.claude/enrich-phased.state` and `.claude/handoff.md`. Print the
   issue URL, the spec and plan paths, and: *"Issue is ready — run
   `/gh:implement <issue>` to trigger the agent-workflow."*

### Between phases (handoff protocol)

At each phase boundary, before stopping:

1. Ensure the phase's artifact is committed (and pushed where the phase says so).
2. Update `.claude/enrich-phased.state` with the new `phase` and any new path.
3. Write `.claude/handoff.md` — a short, self-contained resume prompt that names the
   issue, the next phase, the spec/plan paths so far, and says: **"Resume by running
   `/enrich-phased` (no argument) — it will continue at phase `<next>` from
   `.claude/enrich-phased.state`."** The `SessionStart(clear)` hook auto-injects this
   file, so after `/clear` the user only needs to say `go` (or `/pickup`).
4. Copy that resume prompt to the clipboard (`clip.exe` / `pbcopy` / `wl-copy` /
   `xclip` — whichever exists).
5. Tell the user: phase done, artifact path, and **"run `/clear`, then `go` (or
   `/pickup`) to continue."** Note you cannot run `/clear` yourself. Then stop.

### Choosing a tracked path

The agent-workflow can only read files that are **committed and not git-ignored**.
Some repos `.gitignore` the superpowers docs dir. So before writing a spec/plan:

- Pick an existing **tracked** specs/plans dir if present (e.g.
  `docs/ai-notes/specs` + `docs/ai-notes/plans`, or `docs/superpowers/specs` +
  `…/plans` **only if not ignored**).
- Never write to a path that `git check-ignore -q <path>` reports as ignored — if the
  default target is ignored, fall back to `docs/ai-notes/{specs,plans}`.
- Confirm with `git status`/`git ls-files` that the committed file is actually tracked
  before the push phase relies on it.

### Tools

`gh` (issue read/edit), `git` (commit/push, `check-ignore`), **superpowers:brainstorming**,
**superpowers:writing-plans**, and the `/handoff`-style `.claude/handoff.md` +
`SessionStart(clear)` hook for cross-`/clear` resume.

---

If you run into blockers (ignored docs dir, push auth, brainstorming/writing-plans
unavailable, state file lost), find a solution and update this command for the future.

## Forgejo

Like `/enrich`, but runs each heavy phase in its **own fresh context**, with a
`/handoff` + `/clear` between phases so brainstorm context doesn't bleed into
plan-writing and plan context doesn't bleed into the issue update. Use this instead
of `/enrich` when the topic is large or the session is already long.

You **cannot** run `/clear` yourself — it's the user's keystroke. So this command is
a **re-entrant state machine**: it runs one phase, records progress, writes a resume
handoff, and stops; after the user `/clear`s and resumes, it picks up the next phase.

### Forgejo access

Target the homelab Forgejo (`git.home.freaxnx01.ch`) via **`tea`** (login
`git-home`). Resolve the repo at the start of each phase:

```bash
url=$(git remote get-url origin); url=${url%.git}
repo=$(echo "$url" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')
```

### State

Track progress in `.claude/fj-enrich-phased.state` (create `.claude/` if needed), a
few `key=value` lines: `issue=`, `phase=`, `spec=`, `plan=`. This file is the source
of truth for which phase runs next.

On invocation:

1. If an issue number was passed as an argument (strip any leading `#`), this is a
   **new run**: carry the number through this invocation and dispatch to Phase
   `spec`. **Don't write the state file yet** — Phase `spec`'s lock steps can end
   the run before it starts, and a file written now would let a later no-argument
   resume skip them and enrich an issue another session holds a fresh lock on.
   Phase `spec` step 4 writes `issue=<N>` and `phase=spec` once the lock is held.
2. Else read `.claude/fj-enrich-phased.state` and continue from its `phase`. If no
   argument and no state file, tell the user there's nothing to resume and stop.

Then dispatch to the matching phase below.

### Phase `spec`

1. `tea issues <issue> --login git-home` + `tea api --login git-home
   "repos/$repo/issues/<issue>/comments"`. If the issue is closed or `🧊 parked`,
   stop and say so. **On a resume** (a state file already existed for this run
   — see *On invocation*), this run already holds the lock from a prior
   step 4, and stopping here abandons it without releasing:

   ```bash
   current=$(tea api --login git-home "repos/$repo/issues/<issue>" | jq -r '[.labels[].name]')
   [[ -n "$current" && "$current" != "null" ]] || { echo "failed to read current labels, aborting" >&2; exit 1; }
   kept=$(echo "$current" | jq -c '[.[] | select(. != "enrichment-ongoing")]')
   tea api --login git-home -X PUT "repos/$repo/issues/<issue>/labels" -f labels="$kept" >/dev/null
   ```

   If either command fails, tell the user the lock is still held and has to
   be removed by hand. On a new run there is nothing to release yet (step 4
   hasn't run) — skip this entirely.
2. **Check for an existing enrichment lock — new runs only.** Skip this step
   entirely on a resume (no argument, continuing from the state file): that is the
   same run continuing, so the only lock it could find is its own. If the issue
   carries the `enrichment-ongoing` label, scan the comments already fetched in
   step 1 for the most recent `🔒 Enrichment lock (re-)acquired at <timestamp>`
   line and compute its age against `date -u +%Y-%m-%dT%H:%M:%SZ`:
   - No `enrichment-ongoing` label → continue to step 3.
   - Label present, a matching comment found, age < 24 hours → **stop**. Tell the
     user the issue is already being enriched (show the age) and end the command.
     No state file exists yet (see *On invocation*), so there is nothing to resume
     into — leave it that way.
   - Label present, age ≥ 24 hours, or no matching comment found (treat unknown age
     as stale) → tell the user the lock looks abandoned (show age and the 24h
     threshold) and ask whether to take over.
     - No → stop, same as above.
     - Yes → continue to step 3; step 4 will re-acquire the lock and note the
       takeover.

   Remember which lock comments you saw here — step 4's race re-check has to tell
   them apart from ones posted after this point.
3. Assess readiness (acceptance criteria + scope + no blocking unknowns). If it's
   already complete, say so, suggest `/work <issue>`, and stop. **On a resume**,
   a state file exists here (written by a prior step 4) and this run holds the
   lock — release it before deleting the file, same as step 1's resume path:

   ```bash
   current=$(tea api --login git-home "repos/$repo/issues/<issue>" | jq -r '[.labels[].name]')
   [[ -n "$current" && "$current" != "null" ]] || { echo "failed to read current labels, aborting" >&2; exit 1; }
   kept=$(echo "$current" | jq -c '[.[] | select(. != "enrichment-ongoing")]')
   tea api --login git-home -X PUT "repos/$repo/issues/<issue>/labels" -f labels="$kept" >/dev/null
   ```

   If either command fails, tell the user the lock is still held and has to
   be removed by hand. **On a new run**, no state file exists yet (step 4
   hasn't run) and there is nothing to release — just confirm no file exists
   and stop.
4. **Acquire the enrichment lock — new runs only**, same gate as step 2: on a
   resume skip this step entirely and go straight to step 5, since the lock is
   already held from the original acquisition. Running it again would post a second
   lock comment and then lose the race re-check below to the run's own earlier
   lock, dead-ending every future resume. Acquire before brainstorming — the
   expensive shared resource two sessions could collide on. Make sure the label
   exists first:

   ```bash
   tea labels create --login git-home --name enrichment-ongoing --color "#fbca04" \
     --description "Another /enrich session is actively enriching this issue — do not start a second one" \
     2>/dev/null || true
   ```

   Post the timestamp comment before applying the label — a label with no matching
   comment reads as "unknown age → stale" to step 2's check, defeating detection.
   Fresh acquisition (step 2 found no lock):

   ```bash
   tea api --login git-home -X POST "repos/$repo/issues/<issue>/comments" \
     -f body="🔒 Enrichment lock acquired at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
   ```

   Takeover of a stale lock (step 2 found one and the user agreed to take over —
   substitute the actual age you showed the user for `<Xh>`):

   ```bash
   tea api --login git-home -X POST "repos/$repo/issues/<issue>/comments" \
     -f body="🔒 Enrichment lock re-acquired at $(date -u +%Y-%m-%dT%H:%M:%SZ) (previous lock stale, <Xh> old)"
   ```

   Note the exact timestamp you posted, then apply the label. `tea` has no
   per-issue label add/remove subcommand, so read the current labels and PUT back
   the set with `enrichment-ongoing` added — guarding the read, because an empty
   `current` would PUT an empty set and wipe **every** label on the issue:

   ```bash
   current=$(tea api --login git-home "repos/$repo/issues/<issue>" | jq -r '[.labels[].name]')
   [[ -n "$current" && "$current" != "null" ]] || { echo "failed to read current labels, aborting" >&2; exit 1; }
   locked=$(echo "$current" | jq -c '. + ["enrichment-ongoing"] | unique')
   tea api --login git-home -X PUT "repos/$repo/issues/<issue>/labels" -f labels="$locked" >/dev/null
   ```

   **Verify the `PUT` succeeded before continuing.** If it fails, the run
   does not hold the lock even though the timestamp comment claims it does —
   abort without brainstorming and tell the user the lock could not be
   acquired. The state file isn't written until after the race re-check
   below succeeds, so there's nothing to clean up here.

   **Then re-check for a competitor** — step 2 and this step are not atomic (the
   readiness check, and on the takeover path a user prompt, sit between them).
   Re-fetch comments:

   ```bash
   tea api --login git-home "repos/$repo/issues/<issue>/comments"
   ```

   Look for a `🔒 Enrichment lock (re-)acquired` comment that is **not** the one you
   just posted and was **not** already present at step 2. If one exists and its
   timestamp is earlier than yours (same second → lowest comment `id` wins), you
   lost the race. Stand down:

   ```bash
   tea api --login git-home -X POST "repos/$repo/issues/<issue>/comments" \
     -f body="🔓 Enrichment lock released at $(date -u +%Y-%m-%dT%H:%M:%SZ) (lost race to the lock acquired at <winner timestamp>)"
   ```

   Leave the `enrichment-ongoing` label in place — the winning session depends on
   it. Tell the user another session won the race and end the command without
   brainstorming; still no state file, so nothing can resume past this.

   Otherwise the lock is yours. **Now write the state file** — `issue=<N>` and
   `phase=spec` — and continue to step 5. This is its first write: a run that
   stopped at step 2 or lost the race leaves no file behind, so it can never be
   resumed past the check that stopped it.
5. Invoke **superpowers:brainstorming** with the issue as context. Follow it
   end-to-end — clarifying questions, approaches, design sections, the spec
   self-review, and the **user approval gate**. Save the spec to the repo's tracked
   specs dir (see *Choosing a tracked path*), commit it, and record `spec=<path>`.

   **If the user declines the approval gate** (does not approve the spec), the run
   is over — not paused. Release the lock and delete
   `.claude/fj-enrich-phased.state` before stopping:

   ```bash
   current=$(tea api --login git-home "repos/$repo/issues/<issue>" | jq -r '[.labels[].name]')
   [[ -n "$current" && "$current" != "null" ]] || { echo "failed to read current labels, aborting" >&2; exit 1; }
   kept=$(echo "$current" | jq -c '[.[] | select(. != "enrichment-ongoing")]')
   tea api --login git-home -X PUT "repos/$repo/issues/<issue>/labels" -f labels="$kept" >/dev/null
   ```

   If either command fails, tell the user the lock is still held and has to be
   removed by hand — otherwise it blocks the issue for the full 24 hours.
6. **Phase boundary** (see *Between phases*): set `phase=plan`, hand off, stop.

### Phase `plan`

1. Re-open the spec at `spec=` to re-establish context.
2. Invoke **superpowers:writing-plans** to produce the task-by-task plan in the
   repo's tracked plans dir. Commit it and record `plan=<path>`.
   **Do not stop at writing-plans' own "Subagent-Driven or Inline Execution?"
   handoff prompt — don't even print it.** That's the skill's generic ending, not
   this phase's; `/enrich-phased` dispatches via the issue body + `ai-implement`
   label, not local execution. Suppress the question entirely: don't ask it,
   don't wait for an answer, don't execute the plan. Treat it as written the
   moment the skill exits and continue to step 3.
3. **Push** so both spec and plan are on the remote: `git push`. Verify it succeeded.
4. **Phase boundary:** set `phase=issue`, hand off, stop.

### Phase `issue`

1. Replace the issue body via API PATCH using the **typed** field `-F` so the file
   is read (`-f` stores the literal string; `tea issues edit` has no body flag):
   `tea api -X PATCH "repos/$repo/issues/<issue>" -F body=@bodyfile.md` — with:
   - the original description (keep it for humans),
   - an `## Acceptance Criteria` section as a `- [ ]` checklist,
   - a `## Spec & Implementation Plan` section linking the **relative paths** to
     `spec=` and `plan=`, plus: *"Read the plan before writing any code — it contains
     the full task breakdown, file structure, TDD steps, and exact code."*
2. Clear the readiness labels — `needs-enrichment` and `❓ to-be-defined` mean "not
   ready yet," and the issue now is — and release the enrichment lock acquired back
   in Phase `spec`, since the run is done and nothing else will clear it. All three
   go in one write, so a failure can't clear the lock while leaving a readiness
   label on. `tea` has no per-issue label add/remove subcommand, so
   read-filter-PUT, guarding the read (an empty `current` would PUT an empty set
   and wipe **every** label on the issue):

   ```bash
   current=$(tea api --login git-home "repos/$repo/issues/<issue>" | jq -r '[.labels[].name]')
   [[ -n "$current" && "$current" != "null" ]] || { echo "failed to read current labels, aborting" >&2; exit 1; }
   kept=$(echo "$current" | jq -c '[.[] | select(. != "needs-enrichment" and . != "❓ to-be-defined" and . != "enrichment-ongoing")]')
   tea api --login git-home -X PUT "repos/$repo/issues/<issue>/labels" -f labels="$kept" >/dev/null
   ```

   If this fails, say so — the lock is still held and has to be removed by hand,
   otherwise it blocks the issue for the full 24 hours.

3. Push if anything else is pending.
4. **Done:** delete `.claude/fj-enrich-phased.state` and `.claude/handoff.md`. Print
   the issue URL, the spec and plan paths, and: *"Issue is ready — run
   `/work <issue>` to implement it locally."*

> When the self-hosted **Forgejo Actions** agent-workflow exists (future tier), the
> final pointer becomes "apply `ai-implement` / run `/fj:implement`" instead.

### Between phases (handoff protocol)

At each phase boundary, before stopping:

1. Ensure the phase's artifact is committed (and pushed where the phase says so).
2. Update `.claude/fj-enrich-phased.state` with the new `phase` and any new path.
3. Write `.claude/handoff.md` — a short, self-contained resume prompt that names the
   issue, the next phase, the spec/plan paths so far, and says: **"Resume by running
   `/enrich-phased` (no argument) — it will continue at phase `<next>` from
   `.claude/fj-enrich-phased.state`."** The `SessionStart(clear)` hook auto-injects
   this file, so after `/clear` the user only needs to say `go` (or `/pickup`).
4. Copy that resume prompt to the clipboard (`clip.exe` / `pbcopy` / `wl-copy` /
   `xclip` — whichever exists).
5. Tell the user: phase done, artifact path, and **"run `/clear`, then `go` (or
   `/pickup`) to continue."** Note you cannot run `/clear` yourself. Then stop.

### Choosing a tracked path

The implementer can only read files that are **committed and not git-ignored**. Pick
an existing **tracked** specs/plans dir; never write to a path that `git check-ignore
-q <path>` reports as ignored — fall back to `docs/ai-notes/{specs,plans}`. Confirm
with `git ls-files` that the committed file is tracked before the push phase relies
on it.

### Tools

`tea` (issue read/edit via api PATCH), `git` (commit/push, `check-ignore`),
**superpowers:brainstorming**, **superpowers:writing-plans**, and the
`/handoff`-style `.claude/handoff.md` + `SessionStart(clear)` hook for cross-`/clear`
resume.

---

If you run into blockers (ignored docs dir, push auth, brainstorming/writing-plans
unavailable, state file lost, body PATCH rejected), find a solution and update this
command for the future.

## Azure DevOps

`detect_forge` said `azdo`, so the remote is an Azure DevOps one — and **this
command has no Azure DevOps section yet**. Say exactly that and **stop**.

Do **not** fall back to the GitHub or Forgejo section. Neither `gh` nor `tea` can
read ADO work items, so running either against this remote fails confusingly at
best; on a command that *writes*, it would aim the write at the wrong forge
entirely. `/issues` is the only command with ADO support today — see **ADR-011**
in agent-workflow's `docs/DECISIONS.md` for the object mapping, and its `TODO.md`
for the port status.

## Unknown host

Report the detected host and that it matched no authed GitHub or Forgejo login
and none of the Azure DevOps host forms; point at `gh auth login` /
`tea login add` / `az devops login`. Don't guess a forge.
