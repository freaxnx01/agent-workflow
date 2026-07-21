---
name: processing-test-feedback
description: Use when triaging unstructured or mixed-language (English/German) tester notes, QA feedback, or bug-bash jottings — possibly with screenshots/videos attached — turning a batch of raw notes into per-entry decisions of GitHub/Forgejo issue vs TODO.md entry vs implement-now, with dedup against existing issues and resumable state across sessions.
---

# Processing Test Feedback

## Overview

Turn a batch of raw, unstructured tester notes (usually a mix of English and German,
one thought per line or bullet) into a **decision per entry**: does it become a tracker **Issue**,
a line in **TODO.md**, a tiny **immediate** change, or **nothing** (already covered)?

**Core principle:** every raw note ends as exactly one disposition — but only *after*
grounding in what the repo already knows (open issues, TODO sections, glossary, code) and
*after* you show the triage table and get approval. Never file, edit, or code before the
table is approved.

The strong-model failure mode this prevents: doing all the right moves inconsistently and
by luck — inventing ad-hoc topic labels, waffling ("issue *or* todo"), skipping dedup, and
acting before the human has seen the plan.

## When to use

- A batch of test/QA feedback notes to process (pasted into chat).
- Mixed EN/DE, terse, unstructured — "app crasht wenn…", "would be nice if…".
- Notes may carry **screenshots or videos** as repro evidence.
- You need to decide, per note, where it goes.
- Resuming a triage batch started in an earlier session.

**Not for:** a single well-formed bug report (just file it), or writing an issue body
(that's `/gh:enrich` / `/fj:enrich`).

## Procedure

### 1. Detect the tracker and gather repo signals (once, up front)

Do this before reading the notes — it builds both the **topic vocabulary** and the
**dedup set**. Never invent topics; anchor them to what already exists here.

- **Tracker:** GitHub (`.github/`, `origin` on github.com) → use `gh` + the `/gh:*` skills.
  Forgejo (`.forgejo/`, forgejo/gitea remote) → use the Forgejo CLI + `/fj:*` skills.
- **Open issues** (the dedup set + topic labels): `gh issue list --state open --limit 100`
  (or the Forgejo equivalent). Note the `area:*` labels — they are the canonical topics.
- **TODO.md** at repo root: read the `## <Topic>` section headings — these are topics too,
  and its unchecked items are part of the dedup set.
- **glossary.md / docs/**: named concepts (e.g. "Apply to all", "Common edit after override")
  are precise topic anchors — prefer them over paraphrase.
- Keep a short list of **code/feature areas** to verify claims against later.

### 2. Split into atomic entries, and capture attachments

One concern per entry, regardless of how the notes are formatted — bullets (`-`, `*`),
plain newline-separated lines, or blank-line-separated paragraphs all work. Treat each
line/bullet/paragraph as one note; if a note carries two concerns ("X is broken *and* it'd
be nice if Y"), split it into two entries. Number them.

If an entry has **screenshots or videos**, persist them now (see Attachments) — an
ephemeral pasted image is lost next session, which breaks the persistence guarantee.

### 3. Classify each entry

For each entry decide four things:

- **Topic** — map to an existing `area:*` label / TODO section / glossary term. Do not
  coin a new label if an existing one fits.
- **Kind** — **New feature** (capability that does not exist yet) vs **Improvement**
  (change to existing behaviour). A bug fix *is* an Improvement — tag it `(bug)` so the
  correctness signal isn't lost. Keep the axis binary; the bug tag rides alongside.
- **Verify against the current build** — before proposing any action, check the claim
  against current code: is it **already fixed / already guarded**, or a **duplicate** of
  an open issue or TODO line? A note describing behaviour that the code already prevents
  is not a bug — it's a stale build or a different repro. This step catches the biggest
  time-wasters (re-filing what exists).
- **Disposition** — apply the rubric below.

### 4. Present the triage table — then STOP

Show one table for the whole batch and **wait for approval**. Columns:

| # | Note (normalized, short EN) | Att. | Topic | Kind | Disposition | Rationale / link |

`Att.` = count/filenames of persisted attachments for that entry (blank if none).

Write the worklog file (see Persistence) at this point, status `awaiting-approval`.
Do **not** create issues, edit TODO.md, or write code yet.

### 5. Act on approval

Only after the human approves (they may edit dispositions first), act per entry via the
right channel, and mark each entry `done` in the worklog as you go:

- **Issue** → `/gh:new` (or `/fj:new`): label `needs-enrichment` + the matching `area:*`
  label. One issue per entry. Use a Conventional-Commits-style title (`fix(...)`,
  `feat(...)`). Embed each attachment in the body (`![](<committed asset path>)` for images,
  a link for videos); if the tracker needs a true upload, flag it for the human to drag in.
- **TODO.md** → append `- [ ]` under the matching `## <Topic>` section (create the section
  if none fits), in the existing prose style. Link any attachment by its committed path.
- **Immediate** → implement now, surgically (see the base clean-code / surgical-edit rules),
  then record what you changed. The attachment is the repro evidence — keep it in the worklog.
- **No action** → nothing to create; the rationale (issue link / "already fixed") is the
  deliverable. Attachments help verify the claim against the current build.

Carry each entry's attachments through to its disposition — never drop them on the floor.

## Disposition rubric — decide in this order, first match wins

Checking in order is what kills the waffling. Do not skip step 1.

1. **Already covered** → **No action.** An open issue matches, or the current code already
   fixes/guards it, or it's not reproducible. Link the issue number or say why. (Optionally
   add a "tester-confirmed" comment on the existing issue.)
2. **Trivial + cosmetic/textual + no behavioural or data risk + one obvious local edit**
   (typo, missing tooltip/`title`, label wording) → **Immediate.**
3. **Real change** — needs a spec or discussion, is multi-step, is user-visible behaviour,
   or is a correctness/data-integrity bug (even a small one — traceability matters) →
   **Issue.**
4. **Otherwise** — a small, local follow-up, reminder, polish item, or verification gate
   that doesn't warrant tracked discussion → **TODO.md.**

The Issue-vs-TODO line is **scope & audience**: real/user-visible/needs-discussion → Issue;
small/local/personal-reminder → TODO.

## Attachments (screenshots / videos)

A note may come with repro media. To survive across sessions, media must become a **file on
disk in a committed location** — not an ephemeral pasted image.

- **Assets dir:** `docs/ai-notes/feedback/assets/<worklog-slug>/`. Name each file
  `entry-<NN>-<short>.<ext>` (e.g. `entry-08-tooltip.png`, `entry-12-double-submit.mp4`).
- **Source is a file path** (a saved screenshot, a video file) → copy it into the assets dir.
- **Source is an image pasted inline in chat** → it is visible to you but not yet on disk, and
  you generally cannot serialize it to a file yourself. Ask the human to save it and give you
  the path (or drop the file into the assets dir), then copy/record it. Do not pretend a
  pasted-only image is persisted.
- Record every attachment's relative path in the worklog entry (see below), and carry it into
  the entry's disposition (issue body / TODO line / immediate-fix evidence).

## Persistence — resumable across sessions

A batch may span sessions. State lives in a committed worklog, not just the chat.

- **On start**, scan `docs/ai-notes/feedback/` for a worklog with entries not yet `done`.
  If one exists, offer to **resume** it (show remaining entries) instead of starting fresh.
- **Worklog path:** `docs/ai-notes/feedback/<YYYY-MM-DD>-<slug>.md` (get the date from
  `date +%F`; slug from the feedback theme).
- **Worklog contents:**
  - a header line with overall `status: awaiting-approval | approved | done`;
  - the triage table with the `Att.` column plus a trailing **Status** column per entry
    (`pending` → `approved` → `done` / `skipped`);
  - a `## Raw notes` appendix preserving the original pasted notes verbatim, so the batch
    is fully reconstructable in a fresh session;
  - attachments live under `assets/<worklog-slug>/` next to the worklog and are referenced
    by relative path — so a fresh session recovers both the notes and their media.
- Update the worklog at each transition (proposed, approved, each entry acted). A new
  session reads the worklog and continues from the first non-`done` entry.

## Common mistakes

- **Inventing topic labels** ("multi-doc UI") instead of using an existing `area:*` /
  glossary term. Anchor first, coin only as a last resort.
- **Waffling** ("issue or todo", "todo or fix now"). The ordered rubric gives exactly one
  answer — apply step 1 first.
- **Skipping dedup / build-verification.** These are the highest-value steps and a strong
  model will *sometimes* do them; the procedure makes them mandatory, every time.
- **Folding regional formatting into i18n.** Language (DE/EN text) and regional formatting
  (dates/numbers per `de-CH`) are decoupled — separate topics, separate dispositions.
- **Acting before approval** — creating issues or editing TODO.md before the table is shown.
- **Trusting CLAUDE.md over the code** when verifying a claim — read the actual source
  (e.g. the UI may be raw Bootstrap even where conventions assume MudBlazor).

## Red flags — stop

- About to run `gh issue create` / edit `TODO.md` / write code, but haven't shown an
  approved table → stop, present the table first.
- Wrote a topic label that doesn't appear in the issue labels, TODO sections, or glossary →
  re-check for an existing anchor.
- Filing an issue without having listed open issues this session → you skipped dedup.

---

If you hit a blocker, or discover a better routing heuristic, a tracker-detection edge case,
or a worklog-format improvement, fix it and update this skill so the next run inherits it.
