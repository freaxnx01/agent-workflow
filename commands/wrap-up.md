---
description: End the session — summarize loose ends and write them to TODO.md
---

Review what has happened in this session and write any unfinished work to `TODO.md`
in the repo root.

## Steps

1. **Identify loose ends** — same scan as `/loose-ends`: edits not committed, tests
   not run or failing, commands queued, follow-ups requested, open TODOs, agent PRs
   still in flight.

2. **Append to `TODO.md` — never overwrite it.** A repo's `TODO.md` is a long-lived
   ledger: it can carry hundreds of lines and dozens of open items from earlier
   sessions, and replacing it destroys tracked work. Read it first, then:

   - **Add one new section at the top**, directly below the `# TODO` heading, titled
     `## Session <YYYY-MM-DD> (<issue or topic>) — <one-line status>`. Newest first, so
     the current session is what a reader sees.
   - Each item is a checkbox: `- [ ] <what needs doing>`, with enough context to act on
     cold — issue or PR number, file path, and what was waiting on what.
   - **Update an existing item in place** when this session resolved it or made it
     stale: tick it, or correct the value it names. Never leave a new item standing
     next to an older one that contradicts it.
   - **Skip whatever a tracked issue already records in full.** A `TODO.md` entry earns
     its place only by carrying something the issue body and its comments do not.
   - Create the file, with a `# TODO` heading, only when it does not already exist.

3. **Commit and push `TODO.md`** — if anything was written, stage and commit it with
   message `chore: update TODO.md` and push to the current branch's remote. Skip if
   nothing was written. Follow the repo's own convention if its history shows a
   different subject for `TODO.md` commits.

4. **Print a short summary** — one line per loose end, then confirm the section that was
   appended and that it was pushed. If there's nothing outstanding, say so and leave
   `TODO.md` untouched.

Keep it terse. No preamble.

> **Related:** `/wrap-up` captures *all* session loose ends. To save and resume a
> *single* in-flight task across a `/clear`, use `/handoff` → `/pickup` instead.
