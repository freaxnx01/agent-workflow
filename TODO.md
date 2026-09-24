# TODO

## Session 2026-09-18 (quality gate + turn budget) — 3 issues shipped, 3 open, #355 blocked on you

Shipped: #353+#354 (one quality-gate definition, PR #360) and #359 (turn budget
sized from either heading level, PR #363). Details are in those issues; only what
they do **not** record is below.

- [ ] **#355 `ADD_TO_PROJECT_PAT` — blocked on a token only you can mint.**
      Still failing (`Bad credentials`, 100+ consecutive runs, latest 2026-09-17
      11:26). Passbolt was audited this session and **has no usable token** —
      this is the part #355 does not record:
      - `51026ce1` "GitHub PAT freaxnx01" — right account, but `read:project`
        only (read-only). Insufficient.
      - `6684328d` "anim-bossinfo-ch CLI+CI" — has `project` **write**, but is
        account `anim-bossinfo-ch`; project 5 is `users/freaxnx01/projects/5`.
      - `c458813c` "agent-action-sandbox GH Runner PAT" — freaxnx01,
        fine-grained, capability **untested** (scope probing was blocked, and it
        is the wrong credential to couple this workflow to anyway).
      - `c25fe9c0`, `af3c3701` — not a token / expired.

      All five had **empty descriptions**, which is why scope had to be probed
      at all — record scopes in the description for whatever replaces them.
      Decision taken: mint a **fine-grained** PAT, owner `freaxnx01`, repo
      `freaxnx01/agent-workflow`, **Account permissions → Projects: read &
      write** (the action's README misfiles this under *Organization*
      permissions — wrong for a user-owned project), plus repo `issues` and
      `pull requests` read-only. Longest available expiry: the outage is a
      30-day lapse (secret set 2026-06-04, failing from ~2026-07-12).
      Then `gh secret set ADD_TO_PROJECT_PAT --repo freaxnx01/agent-workflow`
      and tell me — verification is re-running the failed run and confirming an
      issue **lands in project 5**, not just that the secret was written.

- [ ] **#364 / #365 need enrichment** — both `needs-enrichment`, bodies complete.
      Not recorded in either: they **compound**. An agent PR gets
      `action_required` checks (#364) *and* its review job can be cancelled by
      a competing label-event run (#365), so a correct implementation can look
      like a dead end via two independent routes at once — which is exactly what
      #359's dispatch did before it was finished by hand.

- [ ] **`just lint` now needs `pre-commit` locally.** Installed this session at
      `~/.local/share/pre-commit-venv`, symlinked to `~/.local/bin/pre-commit`
      (system Python is externally-managed; no `pipx`). On a fresh machine the
      recipe exits 127 with an install hint. Two traps it exposed, both cheap to
      re-learn the hard way: `pre-commit run --all-files` only checks files git
      **tracks**, so lint a new file *after* `git add` or the green is a false
      pass; and `markdownlint-cli2` is the exception, because its
      `globs: ["**/*.md"]` reads the disk instead (that is why `.superpowers/**`
      had to be added to its `ignores:`).

- [ ] **Plan task headings must be `### Task N`.** `classify-turns.sh` counted h3
      only, and `writing-plans` emits h2 — an enriched 6-task plan silently got
      the 50-turn default. #359 fixed the script to accept both, so this is no
      longer load-bearing, but verifying a plan's budget before dispatch is still
      worth doing:
      `ISSUE_LABELS='ai-implement' ISSUE_NUMBER=1 REPO=o/r ISSUE_BODY="$(printf '## Implementation Plan\n\n'; cat <plan>)" bash scripts/classify-turns.sh`

## Azure DevOps forge support — finish the port (2026-09-09, PR #307, ADR-012)

PR #307 added ADO detection plus an `## Azure DevOps` section to `/issues` only.
Reasoning and caveats are in **ADR-012**; these are the follow-ups it names.

- [x] **Guard the other 12 commands** — done in PR #307. Each carries a
      `## Azure DevOps` section that names the forge, refuses the GitHub/Forgejo
      fallback and stops; all 12 `## Unknown host` sections now name
      `az devops login` too. They are unsupported but safe.
- [ ] **Port the 12 sections properly** — `done`, `enrich`, `enrich-phased`,
      `milestone`, `new`, `parked`, `prs`, `queue`, `roadmap`, `route`, `triage`,
      `work`. Now unblocked: the `/issues` model was confirmed
      against a live org. `/milestone` is the interesting one: iteration create
      is two steps (`iteration project create` then `iteration team add`, or the
      result is unassignable), iterations nest where GitHub milestones are flat,
      and `--depth` defaults to 1 on the listing commands. `/triage`'s "bugs
      first" ordering needs to key off work-item **type**, not a `bug` tag.
- [ ] **Verify against a live organization and delete the epistemic caveat** in
      `/issues`. Flags came from `--help`; JSON shapes, WIQL clauses and every
      `--query` path did not. The `--query` paths are the likeliest to be wrong
      and fail *silently* (empty result, not an error). Step-by-step checklist:
      see the next section.
- [ ] **Hybrid case: ADO boards + GitHub code** — out of scope in ADR-012 by
      choice. `detect_forge` keys off the git remote, so such a repo detects as
      `github` and never reaches the ADO path. Supporting it means splitting
      "code host" from "work-item backend", reshaping dispatch in all 12 files.

## Azure DevOps — manual test plan (needs a live org; nothing here can be faked)

> **RUN 2026-09-22/23 — every section has now met a live organization.**
> Read pass against `bossinfo`; write pass (§7–§9) against a purpose-made
> `agent-workflow-sandbox` project (Basic template) in the personal org
> `AndreasImboden0022`, which is **left in place** so a fix can be verified.
> Full results, per checkbox, in
> [`docs/ai-notes/2026-09-22-ado-manual-test-run.md`](docs/ai-notes/2026-09-22-ado-manual-test-run.md).
>
> | Section | Outcome |
> |---|---|
> | §1 detection | pass, except `ssh://host:PORT/v3/…` → **#387** |
> | §2 auth failure | pass — errors in 0s, no hang |
> | §3 metadata | **pass, and proven** across two genuinely different templates |
> | §4 WIQL | **fails** — `az boards query` returns 0 bytes → **#386** |
> | §5 `--query` paths | 2 of 4 wrong (both classification-node listings) → **#386** |
> | §6 area guard | works, but a miss **errors** (`TF51011`) rather than returning empty → **#386** |
> | §7 WIP derivation | **pass** |
> | §8 tags | **cannot pass as written** — emoji tags are rejected by the server |
> | §9 iterations | **pass** — the `--depth` trap is real |
> | §10 guards | pass, verified by inspection |
>
> The remaining unchecked boxes below are left as the original specification;
> the table above and the note are the authoritative result.

Everything below is what `--help` and the fixture tests **cannot** reach. The unit
tests cover remote-URL parsing only; they build throwaway repos and never call
`az`. So treat every JSON shape, WIQL clause and `--query` path in `/issues`'
`## Azure DevOps` section as unverified until a run below confirms it.

**Golden rule for the whole pass: run each call with plain `--output json` FIRST
and look at the real shape, then add the `--query`.** A wrong JMESPath returns an
empty list, not an error — so testing `--query` first can "pass" by printing
nothing while proving nothing.

### Setup

- [ ] An ADO org with a project and a git repo in Azure Repos; clone it so
      `origin` is a real `dev.azure.com` remote.
- [ ] `az` + `az extension add --name azure-devops`.
- [ ] PAT exported as `AZURE_DEVOPS_EXT_PAT` from an allowed `.envrc`; reach it
      with `direnv exec <dir> …` (the agent shell fires no direnv hook).
- [ ] Ideally **two** projects on different process templates (Agile + Basic or
      Scrum) — the design's core claim is that state *categories* are
      template-independent where state *names* are not, and one project cannot
      test that claim.

### 1. Detection and context

- [ ] `detect_forge` on the real clone returns `azdo dev.azure.com`.
- [ ] `resolve_azdo_context` yields the right `AZDO_ORG` / `AZDO_PROJECT` /
      `AZDO_REPO`.
- [ ] Repeat against an **ssh** remote (`git@ssh.dev.azure.com:v3/...`).
- [ ] Repeat with a **project name containing a space**. The unit tests cover
      `%20` synthetically; this is the first time a real remote produces it, and
      it is the entire reason the helper returns variables instead of one line.
- [ ] If a legacy `<org>.visualstudio.com` remote is reachable, confirm whether
      `org_url="https://dev.azure.com/$AZDO_ORG"` works or the documented
      `https://$AZDO_ORG.visualstudio.com` fallback is actually needed.

### 2. Auth failure path

- [ ] With **no** PAT and no `az devops login`, confirm the command *reports* the
      missing auth and stops. The section claims it must not fall through to a
      bare `az` call whose prompt would hang — verify it truly does not hang.

### 3. Work-item metadata (this is what removes the template guessing)

- [ ] `az devops invoke --area wit --resource workitemtypes --route-parameters
      project=<p> --api-version 7.1 --output json` returns successfully — confirm
      the **resource name and api-version are right**, since both were guessed.
- [ ] The response really has `.value[].states[]` with `.name` and `.category`.
- [ ] `Completed` and `Removed` appear as categories, and the derived closed-state
      list matches that project's template.
- [ ] Run it on the **second** project (different template) and confirm the
      category names are identical while the state names differ. If this fails,
      the whole "read it from metadata" decision in ADR-012 needs revisiting.

### 4. The WIQL query

- [ ] `az boards query --wiql` accepts the multi-field `SELECT` as written.
- [ ] `[System.AreaPath] UNDER 'Project\repo'` — the single backslash survives
      bash → `az` → REST → the WIQL parser. Verified locally only as far as bash.
- [ ] `NOT CONTAINS` is one operator and parses as written.
- [ ] The `@project` macro resolves against `--project`.
- [ ] `ORDER BY [System.CreatedDate] DESC` is honoured.
- [ ] Record the **result JSON shape** — where the fields actually live (e.g.
      `.fields."System.Title"`) — and fix the section if it differs.

### 5. Every `--query` path (the silent failures)

For each: run without `--query` first, record the shape, then confirm the path.

- [ ] `az repos pr list … --query '[].pullRequestId'` — is the response a
      top-level array, or object-wrapped?
- [ ] `az repos pr work-item list --id <pr> --query '[].id'`
- [ ] `az boards area project list --query '[].name'`
- [ ] `az boards iteration project list --query '[].{name:name,path:path}'`

### 6. Area Path guard

- [ ] In a project that **does** mirror repo names into its area tree: rows come
      back.
- [ ] In a project that **does not**: confirm the command says *"no Area Path
      matching `<repo>`"* and **asks**, rather than printing a confident empty
      list.
- [ ] Confirm it never widens to project-wide on its own — the failure this guard
      exists for is showing other repos' work as this repo's.

### 7. WIP derivation

- [ ] Link a work item to an **active** PR → it disappears from `/issues`.
- [ ] Complete or abandon that PR → the work item comes back (only `active`
      counts as WIP).
- [ ] With no active PRs at all, confirm the empty result reads as "nothing is
      WIP" and not as a failure.

### 8. Tags

- [!] **CANNOT PASS** — tag a work item `parked`. Azure DevOps **rejects emoji
      in tag names** (`TF401407`), with or without the space, while non-ASCII such
      as `übung` is fine. The tag cannot be created, so the question is void rather
      than answered. ADO must use a bare `parked`; the convention is **not**
      portable across forges. Separately, WIQL `CONTAINS` on tags turns out to be
      **whole-tag**, not substring (`unparked`, `parkedx`, `parked-later` are all
      untouched by a `parked` filter) — so the section's stated "cost" of bare-word
      matching does not exist either. Both feed **#386**.
- [ ] Tag another `roadmap` → it drops out.
- [ ] Write tags via `--fields "System.Tags=a;b"` (semicolon-delimited) and
      confirm both land — `work-item create` has no `--tags` flag.

### 9. Iteration scope (the milestone argument)

- [ ] `/issues <iteration-name>` scopes correctly, and `/issues pick` lists them.
- [ ] Create a **nested** iteration and confirm the default `--depth 1` listing
      hides it while `--depth 3` shows it — the documented trap.
- [ ] Matching on the leaf name while filtering on the full path behaves.

### 10. The guards on the other 12 commands

- [ ] On an ADO remote, run `/milestone`, `/new`, `/prs`, `/triage`, `/work` and
      confirm each **names the forge and stops** — no `gh` call, and in
      particular no write aimed at the wrong forge.

### Closing the loop

- [ ] Fold every correction back into `commands/issues.md`, then **delete its
      "Epistemic status" paragraph** — that paragraph is the marker that this
      pass has not happened, so removing it is the definition of done.
- [ ] Only then port the other 12 sections (see the previous section).

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

- [x] `hooks/handoff-resume.sh` read the legacy unslugged `.claude/handoff.md`, so
      the `SessionStart(clear)` injection was blind to every branch-slugged handoff
      `/handoff` had written since. Fixed 2026-09-10: it resolves the branch slug
      (detached HEAD included), prefers that branch's file, keeps the legacy name as
      a fallback, and points at `.claude/handoffs.md` when one exists. Covered by
      `tests/run-handoff-resume-tests.sh` — the hook had no tests at all before.
- [x] Stale committed handoffs on `main`, surfaced by the first index run — all
      three verified done and deleted 2026-09-10: `handoff-worktree-enrich.md`
      (#193 closed 2026-08-04), `handoff-issue-198-199-forge-agnostic-commands.md`
      (its plan shipped — `scripts/lib/detect-forge.sh` and the command merge are
      in; issues #198/#199 stay **open** for the separate skills-layer refactor),
      and the pre-slug `.claude/handoff.md` (PR #187 merged, and its three parked
      follow-ups all resolved since). The real lesson is upstream: `/pickup` is
      supposed to delete a handoff when its phase completes, and three in a row
      were left behind.
- [x] No CI job runs the Layer-1 suite. **Done 2026-09-16/17** via #354 (which
      absorbed #353) and PR #360. `lint.yml` gained a `test` job; both it and
      `just test` now call `tests/run-all.sh`, which *discovers* every
      `run-*-tests.sh` with `find` instead of listing them — so the two
      orphaned runners (`run-link-skills-tests.sh`,
      `run-parse-enrich-args-tests.sh`) are picked up by construction. 10
      runners, was 7. `test` is now a **required** status check on `main`.
      Wiring it up immediately found a real bug: six `missing REPO → exit 2`
      assertions passed locally and failed in CI, because a runner always sets
      `GITHUB_REPOSITORY` and the scripts fall back to it — the suite is now
      hermetic against ambient `GITHUB_*` vars.

## Pipeline flake: `ensure-toolchain.sh` apt install hang (discovered 2026-08-17, issue #255 dispatch)

- [ ] `agent-implement-test`'s "stub rate-limit (retry path)" matrix job hung on
      `installing missing tools via apt: ripgrep` in
      `scripts/ensure-toolchain.sh` for the full 10-minute job timeout, then got
      cancelled (`The operation was canceled`) — see
      [run 32068197101](https://github.com/freaxnx01/agent-workflow/actions/runs/32068197101/job/95505110588).
      Not a required check (as of 2026-09-17 main requires `gate-selftest`
      **and** `test`; `agent-implement-test` is neither) so it didn't block
      merging PR #256, and it wasn't caused by
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

## Worktree/branch cleanup (2026-09-22) — one unlanded doc left parked

Swept the repo: 11 local branches, 11 remote branches and 3 worktrees removed
(all verified content-landed first), and `delete_branch_on_merge` turned **on**
so merged heads stop accumulating on `origin`.

- [ ] **`worktree-div` holds work that has never landed.** The branch is back —
      the 2026-08-18 entry below records removing it after confirming its single
      commit was a duplicate, but `origin/worktree-div` was never deleted, so a
      later fetch recreated the local branch on top of *different* commits. It
      now carries `3e3e4a7 docs(planning): add issue prioritization algorithm
      handover`, whose `docs/ai-notes/issue-prioritization-algorithm.md` (168
      lines) is **not on `main` under that or any other name** — checked by
      content and by a rename grep. Its other two commits landed via PR #115.
      Decide: PR the doc, or delete branch + remote as genuinely abandoned.
      Kept deliberately in this sweep; it is the only survivor with unlanded work.
- [ ] **The recurrence is the real lesson** — deleting a local branch while
      leaving its remote means the next `git fetch` resurrects it. Cleanup has to
      take both sides, which is what the 2026-09-22 sweep did and 2026-08-18 did
      not.

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
