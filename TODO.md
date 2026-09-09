# TODO

## Azure DevOps forge support — finish the port (2026-09-09, PR #307, ADR-011)

PR #307 added ADO detection plus an `## Azure DevOps` section to `/issues` only.
Reasoning and caveats are in **ADR-011**; these are the follow-ups it names.

- [x] **Guard the other 11 commands** — done in PR #307. Each carries a
      `## Azure DevOps` section that names the forge, refuses the GitHub/Forgejo
      fallback and stops; all 12 `## Unknown host` sections now name
      `az devops login` too. They are unsupported but safe.
- [ ] **Port the 11 sections properly**, once the `/issues` model is confirmed
      against a live org. `/milestone` is the interesting one: iteration create
      is two steps (`iteration project create` then `iteration team add`, or the
      result is unassignable), iterations nest where GitHub milestones are flat,
      and `--depth` defaults to 1 on the listing commands. `/triage`'s "bugs
      first" ordering needs to key off work-item **type**, not a `bug` tag.
- [ ] **Verify against a live organization and delete the epistemic caveat** in
      `/issues`. Flags came from `--help`; JSON shapes, WIQL clauses and every
      `--query` path did not. The `--query` paths are the likeliest to be wrong
      and fail *silently* (empty result, not an error).
- [ ] **Hybrid case: ADO boards + GitHub code** — out of scope in ADR-011 by
      choice. `detect_forge` keys off the git remote, so such a repo detects as
      `github` and never reaches the ADO path. Supporting it means splitting
      "code host" from "work-item backend", reshaping dispatch in all 12 files.

## Re-enable GitHub Copilot Coding Agent once access is restored (disabled 2026-09-01, PR #282)

- [ ] Copilot access was revoked on this account, so `/gh:assign`, `/gh:review`,
      and `/route` were changed to route to Claude only (PR #282, commit
      `732d204`). Once access is restored, restore the pre-2026-09-01 versions of:
      - `commands/gh/assign.md` — the `copilot`/`claude` case branch in
        "Resolve the actor and assign", and the "Agent default" section.
      - `commands/gh/review.md` — the `@copilot` nudge logic and "Learned
        default — prefer `@copilot`" section in "Triggering the owning agent".
      - `commands/route.md` — the Copilot row and "Stack fit" criterion in the
        GitHub routing table, and the rule-of-thumb line.
      Each disabled section carries a one-line "see git history" pointer at
      the exact spot to revert.

## Handoff index follow-ups (discovered 2026-09-09 while adding `.claude/handoffs.md`, ADR-011)

- [ ] `hooks/handoff-resume.sh` still reads the legacy unslugged
      `$dir/.claude/handoff.md`, so the `SessionStart(clear)` context injection is
      blind to every branch-slugged `.claude/handoff-<branch>.md` that `/handoff`
      has written since. Options: resolve the current branch's slug in the hook, or
      inject the derived `.claude/handoffs.md` index instead (the hook has `jq` and
      the cwd, and the index is regenerated on every `/handoff`).
- [ ] Stale committed handoffs on `main`, surfaced by the first index run:
      `.claude/handoff-worktree-enrich.md` (2026-08-01, #193) and
      `.claude/handoff-issue-198-199-forge-agnostic-commands.md` (2026-07-31, both
      issues shipped), plus the pre-slug `.claude/handoff.md` (2026-07-27, points at
      PR #187). `/pickup` is supposed to delete a handoff once its phase completes;
      these three never were. Verify each is really done, then delete.
- [ ] No CI job runs the Layer-1 suite. `just test` drives four
      `tests/run-*-tests.sh` entry points locally, but the only workflows are
      `lint` (pre-commit) and `gate-selftest` — a broken fixture test would go
      green on a PR. (Also: `tests/run-link-skills-tests.sh` and
      `tests/run-parse-enrich-args-tests.sh` are in neither `just test` nor CI.)

## Pipeline flake: `ensure-toolchain.sh` apt install hang (discovered 2026-08-17, issue #255 dispatch)

- [ ] `agent-implement-test`'s "stub rate-limit (retry path)" matrix job hung on
      `installing missing tools via apt: ripgrep` in
      `scripts/ensure-toolchain.sh` for the full 10-minute job timeout, then got
      cancelled (`The operation was canceled`) — see
      [run 32068197101](https://github.com/freaxnx01/agent-workflow/actions/runs/32068197101/job/95505110588).
      Not a required check (`gate-selftest` is main's only required status
      check) so it didn't block merging PR #256, and it wasn't caused by
      anything in that PR's content — looks like apt lock contention or a slow
      runner mirror. Worth a closer look if it recurs: retry/timeout logic
      around the `apt-get install` call, or pin a faster mirror.

## PR #215 follow-ups (deferred, non-blocking, flagged in the PR itself)

- [ ] No fixture asserts `setup/link-commands.sh` actually installs
      `scripts/lib/detect-forge.sh` to `~/.claude/scripts/lib/` (in either copy or
      `--link` mode) — a regression there would go green.
- [ ] `README.md`'s delivery-path table doesn't document the
      `scripts/lib/` → `~/.claude/scripts/lib/` mapping the installer now performs.

## `/enrich` + `/enrich-phased` concurrency lock (2026-08-04/05 session)

- [x] Core lock mechanism shipped: `commands/enrich.md` Step 1.5/2.5/6,
      `enrichment-ongoing` label, race re-check-after-acquire. Issue #229, merged
      `bf01ae3`.
- [x] Cosmetic review nits filed as follow-up issue #236, cross-linked on PR #233.
- [x] `/enrich-phased` lock shipped (issue #237, merged `cce9ecb` in PR #244) —
      detect/acquire/release adapted to its phase/`/clear` structure, gated on
      new-run vs resume, staleness threshold aligned to **24h in both commands**
      (`/enrich`'s own threshold was raised from 4h — the lock comment doesn't
      record which command acquired it, so both must agree on one window).
      Took 3 automated pipeline rounds (PRs #240/#241/#243, all closed as
      superseded after real review findings — a state-file race, a self-collision
      bug on mid-phase resume, the threshold mismatch) plus a 4th round that
      timed out before opening a PR; the final threshold/resume-release/
      label-verify fixes were applied by hand and merged directly as PR #244.
- [ ] **Manual verification never run** — filed as issue #245 (7 dry-run
      scenarios across both specs, no automated coverage exists).
- [ ] Issue #236 (the two cosmetic nits from #233's review — missing
      `2>/dev/null || true` comment, gh/tea tie-break wording) is still open,
      still `needs-enrichment` — never enriched or dispatched.
- [ ] Cosmetic: `docs/superpowers/plans/2026-08-04-enrich-phased-lock.md` was
      rewritten mid-review to describe the diff in prose ("as implemented in
      commands/enrich-phased.md") rather than keep the original verbatim
      find/replace blocks — flagged as circular/hard-to-independently-verify in
      round 3's review, explicitly deferred as not worth another round. Still
      true after the final hand-applied fixes. Not filed as an issue — too
      minor.
- [ ] `main`'s branch protection vs. `CLAUDE.md`'s "1 PR review" convention —
      filed as issue #246.
- [ ] Pipeline review-agent mid-run timeout on round 4 — filed as issue #247.

## Worktrees (status as of 2026-08-18)

- [x] `.worktrees/div` (branch `worktree-div`) — removed. Its 1 local commit
      ("don't default to @copilot for agent-workflow PRs") was byte-identical
      to `1638a66` (merged via PR #208) — confirmed zero diff before removing
      the worktree and force-deleting the local branch.
- [x] `.worktrees/enrich` (branch `worktree-enrich`) — removed. Content
      (self-fix routing, #193) had already landed via PRs #232/#235/#239 and
      #238's PR #242; confirmed zero diff against `main` before removing the
      worktree and force-deleting the local branch (`git branch -D` — it
      wasn't merged to its own stale `origin/worktree-enrich` remote, only to
      `main`, which is what mattered).
- [x] `.worktrees/factory-map` (branch `docs/pre-preview-self-fix-enrich-81`) —
      removed. The branch was stale from 2026-07-31: its "unique" files vs.
      `main` turned out to be pre-forge-agnostic-consolidation `commands/gh/*`
      and `commands/fj/*` duplicates that `main` deliberately removed (see
      CHANGELOG's `## Removed` entry for #198/#199), and its one real doc
      (`docs/superpowers/plans/2026-07-31-pre-preview-self-fix.md`) was
      byte-identical to what merged via PR #218. No unmerged work found.
- [ ] `.worktrees/new` (branch `worktree-new`) — this session's own worktree,
      still in active use for issue #255 dispatch work. Not stale.
