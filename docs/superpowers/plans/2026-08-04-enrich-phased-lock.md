# /enrich-phased Concurrency Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `/enrich`'s concurrency lock (`enrichment-ongoing` label + timestamped comment, issue #229 / PR #233) to `/enrich-phased`, adapted to its phase/`` `/clear` `` structure, using a 24-hour staleness window instead of `/enrich`'s 4-hour one.

**Architecture:** All lock logic lives inside Phase `spec` — the only point in the phased flow equivalent to `/enrich`'s Step 1.5/2.5. Detection *and* acquisition are added as new numbered steps within Phase `spec`, renumbering its existing steps, and **both** carry the same gate: this invocation started a genuinely new run (an issue number was passed as its argument), never a state-file resume. The state file is written by the acquisition step once the lock is confirmed held — not by *On invocation* — so every stop path leaves nothing resumable behind. Phase `plan` is left untouched. The final release folds into Phase `issue`'s existing label-clearing step. Mirrored identically across the GitHub (`gh`) and Forgejo (`tea`) sections.

**Tech Stack:** Markdown instruction file (`commands/enrich-phased.md`), `gh` CLI (GitHub), `tea` CLI (Forgejo), plain bash (`date -u`, `jq`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-04-enrich-phased-lock-design.md`
- No new scripts or application code — this is a `commands/enrich-phased.md` instruction change, a small robustness backport to `commands/enrich.md`, and one follow-up update to `docs/superpowers/specs/2026-08-04-enrich-lock-design.md`.
- Staleness threshold: **24 hours** (not `/enrich`'s 4h), computed from ISO 8601 UTC timestamps (`date -u +%Y-%m-%dT%H:%M:%SZ`).
- Lock label name/color/description and comment marker format are **identical** to `/enrich`'s (already registered by `scripts/ensure-issue-labels.sh` per #229): label `enrichment-ongoing`; comment `🔒 Enrichment lock acquired at <timestamp>` (fresh) or `🔒 Enrichment lock re-acquired at <timestamp> (previous lock stale, <Xh> old)` (takeover); release comment `🔓 Enrichment lock released at <timestamp> (lost race to the lock acquired at <winner timestamp>)`. Reusing the exact format is what makes `/enrich` and `/enrich-phased` detect each other's locks — do not invent a second label or a differently-worded comment.
- **Both** new Phase `spec` steps (detect *and* acquire) are gated on "this invocation started a new run". Gating only detection dead-ends resumes: a session interrupted mid-brainstorming still reads `phase=spec`, so the resume re-runs acquisition, posts a second lock comment, and the race re-check then loses to the run's *own* earlier lock — permanently, on every later resume.
- **The state file is written by the acquire step, not by *On invocation*.** Writing `issue=`/`phase=spec` before Phase `spec` runs makes every "stop without starting" path here useless: a resume skips detection by design and would walk straight into brainstorming on a locked issue.
- **Phase `plan` gets no lock changes at all.** Unlike `/enrich`, a failed push here is resumable; releasing the lock would leave the rest of the run unlocked, since a resume skips acquisition.
- Phase `plan` and Phase `issue` do not re-verify the lock; they trust it's still held from Phase `spec`'s acquisition (per the spec's Non-goals — accepted tradeoff, not a bug to fix here).
- This command has no automated test suite; verification is the manual dry-run scenarios in the spec's Testing section, reproduced at the end of this plan.

---

### Task 1: Add the lock to `/enrich-phased`'s GitHub section

**Files:**
- Modify: `commands/enrich-phased.md` (GitHub section — *On invocation*, Phase `spec`, Phase `issue`, as they exist under the `## GitHub` heading)

**Interfaces:**
- Consumes: the `enrichment-ongoing` label already registered by `scripts/ensure-issue-labels.sh` (#229) — this task also re-creates it inline (same as `/enrich`'s Step 2.5 does), since `/enrich-phased` can run standalone against repos that haven't run that script.
- Produces: nothing consumed by other tasks — Task 2 is the independent Forgejo mirror.

- [ ] **Step 1: Defer the state-file write in *On invocation***

Find this exact block:

```markdown
1. If an issue number was passed as an argument (strip any leading `#`), start a new
   run: write `issue=<N>` and `phase=spec`.
```

Replace it with:

```markdown
1. If an issue number was passed as an argument (strip any leading `#`), this is a
   **new run**: carry the number through this invocation and dispatch to Phase
   `spec`. **Don't write the state file yet** — Phase `spec`'s lock steps can end
   the run before it starts, and a file written now would let a later no-argument
   resume skip them and enrich an issue another session holds a fresh lock on.
   Phase `spec` step 4 writes `issue=<N>` and `phase=spec` once the lock is held.
```

- [ ] **Step 2: Replace Phase `spec`'s steps 2–4 with the detect/acquire-augmented version**

Find this exact block:

```markdown
2. Assess readiness (acceptance criteria + scope + no blocking unknowns). If it's
   already complete, say so, suggest `/gh:implement <issue>`, clear the state file,
   and stop.
3. Invoke **superpowers:brainstorming** with the issue as context. Follow it
   end-to-end — clarifying questions, approaches, design sections, the spec
   self-review, and the **user approval gate**. Save the spec to the repo's tracked
   specs dir (see *Choosing a tracked path*), commit it, and record `spec=<path>`.
4. **Phase boundary** (see *Between phases*): set `phase=plan`, hand off, stop.
```

Replace it with the numbered steps 2–6 as implemented in `commands/enrich-phased.md`:

- **Step 2 — detect, new runs only.** Skip entirely on a resume. If the issue
  carries `enrichment-ongoing`, find the most recent
  `🔒 Enrichment lock (re-)acquired at <timestamp>` comment among those already
  fetched in step 1 and age it against `date -u +%Y-%m-%dT%H:%M:%SZ`: no label →
  step 3; age < 24h → hard stop (no state file exists yet, leave it that way);
  age ≥ 24h or no matching comment → offer takeover, no → stop, yes → step 3.
  Remember which lock comments were present, for step 4's race re-check.
- **Step 3 — readiness assessment** (unchanged, except "clear the state file"
  becomes "delete the state file if one exists — a new run hasn't written it yet").
- **Step 4 — acquire, new runs only** (same gate as step 2; on a resume skip to
  step 5, the lock is already held). `gh label create enrichment-ongoing --color
  FBCA04 … 2>/dev/null || true`, then `gh issue comment` with the fresh or
  takeover wording, then `gh issue edit --add-label enrichment-ongoing`, then
  re-fetch comments and stand down (`🔓 … lost race …`, label left in place) if a
  competing lock comment appeared that wasn't present at step 2 and is earlier
  than ours. **Only once the lock is confirmed held**, write `issue=<N>` and
  `phase=spec` to the state file and continue to step 5.
- **Step 5 — brainstorming** (was step 3), plus: if the user declines the
  approval gate the run is over, not paused — release the lock with
  `gh issue edit <issue> --remove-label enrichment-ongoing` (no
  `2>/dev/null || true`; on failure tell the user the lock is still held and must
  be removed by hand) and delete `.claude/enrich-phased.state`.
- **Step 6 — phase boundary** (was step 4, unchanged).

- [ ] **Step 3: Leave Phase `plan` alone**

No edit. `/enrich`'s "release on push-verification failure" deliberately does
**not** carry over: `/enrich-phased` resumes after a fixed push, and a resume
skips acquisition, so releasing here would leave Phase `plan` and Phase `issue`
running unlocked. The 24h staleness window covers a genuinely abandoned run.

- [ ] **Step 4: Add the final release to Phase `issue`'s label-clearing step**

Find this exact block:

```markdown
2. Clear the readiness labels — `needs-enrichment` and `❓ to-be-defined` mean
   "not ready yet," and the issue now is. `/gh:implement` treats either as a
   hard stop regardless of body content, so leaving one on is a silent trap:

   ```bash
   gh issue edit <issue> --remove-label needs-enrichment 2>/dev/null || true
   gh issue edit <issue> --remove-label "❓ to-be-defined" 2>/dev/null || true
   ```

   (run each on its own line with `|| true` — a repo that doesn't define one of
   the two label conventions would otherwise error on the `--remove-label`)
```

Replace it with the same step plus a third line,
`gh issue edit <issue> --remove-label enrichment-ongoing`, **after** the two
readiness labels (so a failing lock release can't be what leaves the issue in
`/gh:implement`'s hard-stop state) and **without** `2>/dev/null || true` — this
run applied that label itself, so a non-zero exit is a real failure and must be
reported to the user, naming the manual removal.

- [ ] **Step 5: Verify the markdown structure**

Run:

```bash
sed -n '/^## GitHub$/,/^## Forgejo$/p' commands/enrich-phased.md | grep -nE '^[0-9]+\.'
```

Expected: Phase `spec`'s list now runs 1 through 6 with no gaps or duplicate
numbers; Phase `plan` and Phase `issue` still run 1 through 4 each.

- [ ] **Step 6: Commit**

```bash
git add commands/enrich-phased.md
git commit -m "feat(enrich-phased): add concurrency lock to GitHub section"
```

---

### Task 2: Add the lock to `/enrich-phased`'s Forgejo section

**Files:**
- Modify: `commands/enrich-phased.md` (Forgejo section — *On invocation*, Phase `spec`, Phase `issue`, as they exist under the `## Forgejo` heading)

**Interfaces:**
- Consumes: nothing from Task 1 — the Forgejo section is a self-contained mirror using `tea` instead of `gh`. Uses the same label name/color/description and comment format constants defined in Global Constraints above.
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Mirror Task 1's *On invocation* deferral**

Same replacement as Task 1 Step 1, against `.claude/fj-enrich-phased.state`.

- [ ] **Step 2: Mirror Task 1's Phase `spec` steps 2–6 using `tea`**

Identical structure and wording; the forge calls differ:

- Label create: `tea labels create --login git-home --name enrichment-ongoing --color "#fbca04" … 2>/dev/null || true`
- Comments: `tea api --login git-home -X POST "repos/$repo/issues/<issue>/comments" -f body="…"`
- Label add/remove: `tea` has no per-issue label subcommand, so read-modify-PUT.
  **Every such snippet guards the read** — if `tea api … | jq -r '[.labels[].name]'`
  fails or returns empty, the computed set is empty and the `PUT` wipes every
  label on the issue:

  ```bash
  current=$(tea api --login git-home "repos/$repo/issues/<issue>" | jq -r '[.labels[].name]')
  [[ -n "$current" && "$current" != "null" ]] || { echo "failed to read current labels, aborting" >&2; exit 1; }
  ```

  then compute `locked` (acquire) or `kept` (release) and `PUT`.
- Race tie-break: same second → lowest comment `id` wins.

- [ ] **Step 3: Leave Phase `plan` alone**

No edit, for the same reason as Task 1 Step 3.

- [ ] **Step 4: Add the final release to Phase `issue`'s label-clearing step**

Find this exact block:

```markdown
2. Clear the readiness labels — `needs-enrichment` and `❓ to-be-defined` mean "not
   ready yet," and the issue now is. `tea` has no per-issue label add/remove
   subcommand, so read-filter-PUT:

   ```bash
   current=$(tea api --login git-home "repos/$repo/issues/<issue>" | jq -r '[.labels[].name]')
   kept=$(echo "$current" | jq -c '[.[] | select(. != "needs-enrichment" and . != "❓ to-be-defined")]')
   tea api --login git-home -X PUT "repos/$repo/issues/<issue>/labels" -f labels="$kept" >/dev/null
   ```
```

Replace it with the same read-filter-PUT extended to also drop
`enrichment-ongoing`, plus the read guard. All three labels clear in one write,
so a failure can't release the lock while leaving a readiness label on; report a
failed write to the user.

- [ ] **Step 5: Verify the markdown structure**

Run:

```bash
sed -n '/^## Forgejo$/,/^## Unknown host$/p' commands/enrich-phased.md | grep -nE '^[0-9]+\.'
```

Expected: Phase `spec`'s list now runs 1 through 6 with no gaps or duplicate
numbers; Phase `plan` and Phase `issue` still run 1 through 4 each.

- [ ] **Step 6: Commit**

```bash
git add commands/enrich-phased.md
git commit -m "feat(enrich-phased): add concurrency lock to Forgejo section"
```

---

### Task 3: Backport the two robustness fixes to `/enrich`

**Files:**
- Modify: `commands/enrich.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing — keeps the two commands' shared lock handling from drifting.

- [ ] **Step 1: Stop swallowing `enrichment-ongoing` release failures**

In both the GitHub Step 2.5 "Releasing early" block and Step 6's label cleanup,
drop `2>/dev/null || true` from the `enrichment-ongoing` removal only (the
`needs-enrichment` / `❓ to-be-defined` removals keep it — a repo may genuinely
not define those). On failure, tell the user the lock is still held and must be
removed by hand.

- [ ] **Step 2: Guard the Forgejo read-modify-PUTs**

Add `[[ -n "$current" && "$current" != "null" ]] || { echo "failed to read
current labels, aborting" >&2; exit 1; }` after every
`current=$(tea api … | jq -r '[.labels[].name]')` line in `commands/enrich.md`
(Step 2.5 acquire, Step 2.5 early release, Step 6 release).

- [ ] **Step 3: Commit**

```bash
git add commands/enrich.md
git commit -m "fix(enrich): surface lock-release failures and guard the label PUT reads"
```

---

### Task 4: Close the loop on #229's spec Follow-up

**Files:**
- Modify: `docs/superpowers/specs/2026-08-04-enrich-lock-design.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing — documentation-only closure of a note left by the original spec.

- [ ] **Step 1: Update the Follow-ups section**

Strike through the "Apply the same lock mechanism to `/enrich-phased`" item, drop
its "Known gap until then" note, and point at
`docs/superpowers/specs/2026-08-04-enrich-phased-lock-design.md` (issue #237).

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-08-04-enrich-lock-design.md
git commit -m "docs(enrich-lock): mark the enrich-phased follow-up as done"
```

---

## Manual Verification (after Tasks 1 and 2)

Not a task on its own — run once both forge sections are done, against a
scratch issue on each forge, per the spec's Testing section:

1. Pre-apply `enrichment-ongoing` + a fresh lock comment on a test issue. Run
   `/enrich-phased <issue>` (new run). Expected: hard stop in Phase `spec`'s
   new step 2, before readiness assessment or brainstorming, and
   `.claude/enrich-phased.state` (or `.claude/fj-enrich-phased.state`) is
   never written.
2. Backdate the lock comment past 24h. Re-run `/enrich-phased <issue>`.
   Expected: stale/takeover prompt fires; "no" stops, "yes" proceeds.
3. Run `/enrich-phased <issue>` end-to-end across all three phases (with the
   `/clear` boundaries). Expected: the label and lock comment appear before
   brainstorming starts in Phase `spec`, persist through Phase `plan`
   untouched, and the label (not the comment) is gone after Phase `issue`
   completes.
4. Cross-command check: lock an issue via `/enrich` (its Step 2.5), then run
   `/enrich-phased` on the same issue. Expected: Phase `spec`'s new step 2
   correctly sees `/enrich`'s lock and hard-stops. Repeat in reverse (lock
   via `/enrich-phased`, then run `/enrich`) to confirm `/enrich`'s existing
   Step 1.5 sees it too.
5. Resume check: start a run, let it stop at the Phase `spec` → `plan`
   boundary (normal handoff), `/clear`, resume with no argument. Expected:
   Phase `plan` proceeds directly with no lock-detection output (the new
   step 2 in Phase `spec` never re-runs on a resume).
6. Mid-phase resume check: start a run on an unlocked issue, let step 4 post
   the lock comment, then interrupt during (or just after) step 5's
   brainstorming — before step 6's phase boundary — `/clear`, and resume with
   no argument. Expected: it goes straight to continuing/finishing step 5;
   neither step 2 nor step 4 re-runs, and **no second `🔒 Enrichment lock …`
   comment is posted** (a second one would make step 4's race re-check find
   the run's own earlier lock and dead-end every future resume).
