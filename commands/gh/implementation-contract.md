---
description: The implementation contract posted onto an issue before dispatch — code (TDD), docs-only, and buildless variants
---

The contract `/gh:assign` and `/gh:implement` post onto an issue before handing it
to a coding agent. Three variants; **pick exactly one** using the rule below, and say
which one you picked and why before posting it.

Invoked directly (`/gh:implementation-contract`), print all variants so they can be
inspected or pasted by hand.

## Which variant

Apply in order — first match wins:

1. **Explicit statement** in the AC or body that the change touches **no source
   at all** — "docs-only", "no test is added or changed", or "no file under
   `<source dir>` is modified" where `<source dir>` is the repo's whole source
   tree → **docs-only**.

   Two disqualifiers; either one drops through to the next rule:
   - The statement is **scoped to one project among several** — e.g. "no file
     under `source/Foo.Api/` is modified" in a repo that also ships
     `source/Foo.Client/`. That is a keep-out fence around part of the tree, not
     a claim that the change is documentation.
   - Another acceptance criterion **mandates tests** — "the full `dotnet test`
     suite passes", "new tests cover X". An issue cannot simultaneously be
     docs-only and require new tests.
2. **`documentation` label** on the issue → **docs-only**.
3. **AC file paths** are all documentation-shaped (`docs/**`, `*.md`, `README`,
   `CHANGELOG`) → **docs-only**.
4. **Repo has no test harness** → **buildless**. The change touches source, so
   docs-only is wrong, but there is no runner to write a failing test with.
   Confirm with the repo itself, not a guess — all three of:
   - No test runner is resolvable — no `package.json` `test` script, no test
     framework config (`jest.config.*`, `vitest.config.*`, `pytest.ini`,
     `*.csproj` test project, `go.mod` with `_test.go` files, …), no `tests/`
     or `spec/` tree with real test files.
   - The repo's `CLAUDE.md` / stack overlay names a **manual** gate instead —
     grep for `manual .*playtest`, `no build/test toolchain`, `buildless`, or a
     documented "deviation from base's TDD-first mandate".
   - The issue's own plan contains no test step.

   If the repo has a runner but this issue merely doesn't add tests, that is
   **not** this case — use code and let the agent write the test.

5. **Anything else, including ambiguity → code.** Defaulting to TDD is the safe
   direction: a spurious test costs less than a silently untested change.

Four traps worth naming:

- In a repo whose *product* is `.md` files (this one — `commands/**/*.md`), rule 3
  correctly yields docs-only, because no test harness can cover them. That is not
  a bug in the rule; don't "fix" it to require a `docs/` prefix.
- A change under `scripts/**` or `tests/**` **is** code even in a
  CI-automation repo, and takes the code variant.
- Rule 1's phrase list is a **whole-repo** claim, and a scoped keep-out reads
  identically at a glance. `BI-ArchiveUploader#308` (hide a login-screen
  indicator behind a debug flag) carried the AC "No file under
  `source/BI.ArchivingService.Api/` is modified" — a fence around the backend
  project in a change that edits `.razor` and `.js` under `source/UploadClient/`
  and mandates new bUnit tests. Taken literally, rule 1 would have posted the
  docs-only contract, which forbids touching source and rejects any PR that adds
  tests — i.e. it would have forbidden the entire issue. The disqualifiers on
  rule 1 exist to catch that; when in doubt, the test-mandating AC settles it.
- Rule 5 used to be rule 4, and it silently swallowed buildless repos:
  `game-geography-quiz#18` (a data-only edit to `geo-data.js` in a vanilla-JS
  browser game) fell through to code, whose contract demands "write a failing
  test first… paste the failing output". That repo has no runner at all and its
  stack overlay *forbids* adding one, so the contract's only satisfiable
  readings were "scaffold a test framework against an explicit guardrail" or
  "fabricate RED/GREEN output". Rule 4 exists to catch that before dispatch.

## Code variant

```bash
gh issue comment <N> --body "## TDD Required — Non-Negotiable

Implement using Test-Driven Development:
- **RED:** Write a failing test first. Run it. Confirm it fails for the right reason.
- **GREEN:** Write the minimal code to make it pass. No more.
- **REFACTOR:** Clean up while keeping tests green.

No production code without a failing test first.

Your PR description must include TDD evidence:
- RED: command run + relevant failing output
- GREEN: command run + passing output

## Turn budget discipline — non-negotiable

You are running with a finite turn budget and a wall-clock cap in an
unattended pipeline, and either can end the run without warning. Anything
that has not been **pushed** is lost — the runner is discarded, so a commit
that never left it counts for exactly as much as an unsaved edit.

- **Commit and push after every task** in the Implementation Plan, the
  moment that task's own tests pass — do not front-load all edits across
  every task and push once at the end. Push is the part that matters: a
  local commit dies with the runner.
- **Open the draft PR after the first task passes, not at the end.** Create it
  with \`gh pr create --draft\`, never ready-for-review: \`find-pipeline-pr.sh\`
  selects only drafts, so a ready PR gets no pipeline review at all (#322). Say in
  its description which tasks are done and which remain, and update that as
  you go. A truncated run then leaves a real, reviewable PR of finished
  work instead of nothing at all — and if the run is cut short, whatever
  you pushed is what survives.
- **Trust the plan's line numbers and diffs.** The Implementation Plan
  already names exact files, line ranges, and before/after code. Only
  re-read a file if a step's actual command output contradicts what the
  plan expected (e.g. the diff doesn't apply cleanly) — don't defensively
  re-read files you were already given exact context for."
```

## Docs-only variant

Same evidence discipline, no tests.

```bash
gh issue comment <N> --body "## Implementation contract — docs-only change

This issue is **documentation-only**. The standard TDD contract does **not** apply:
do not add, modify, or delete any test, and do not touch source directories. A PR
that adds tests for this change is wrong and will be rejected.

The equivalent evidence requirement still holds — verify with commands, not
assertions:

- **BEFORE:** run the verification command from the Acceptance Criteria and paste
  the output showing the stale/missing state.
- **AFTER:** run the same command and paste the output showing the AC is satisfied.

Your PR description must include:

- The before/after output of the verification command
- An explicit list of every file changed, and confirmation that the files marked
  **do NOT touch** in the issue are unmodified (\`git diff --name-only\` output is
  enough)

Do not \"improve\" adjacent documentation that the Acceptance Criteria does not name."
```

## Buildless variant

Source changes in a repo with no test runner. Same evidence discipline as
docs-only, but it does **not** claim the change is documentation and does
**not** forbid touching source — the whole point is that source is being
edited without a harness to test it.

Fill in the two `<...>` placeholders from the issue's own plan before posting.
If the plan has no verification commands, that is a gap in the plan — say so
and stop, rather than posting a contract with nothing to verify against.

```bash
gh issue comment <N> --body "## Implementation contract — buildless repo, no test framework

This repo has **no test runner, no bundler, no package manifest**, and you must
**not** add one — that is an explicit stack guardrail. The standard TDD contract
does **not** apply: do not create, modify, or delete any test file. A PR that
adds a test framework or a test file for this change is wrong and will be
rejected.

The equivalent evidence requirement still holds — verify with commands, not
assertions:

- **BEFORE:** run the plan's verification commands and paste the output showing
  the pre-change state (expect: <expected before-state>).
- **AFTER:** run the same commands and paste the output showing the AC is
  satisfied (expect: <expected after-state>).

Your PR description must include:

- The before/after output of **every** verification command
- \`git diff --name-only\` output confirming only the files the Acceptance
  Criteria names were changed

This repo's real test gate is a **manual** check a pipeline cannot perform.
Do **not** claim you ran it. List it in the PR description as the outstanding
human verification step, so the reviewer knows it is still owed.

If a stated acceptance criterion contradicts what you actually observe in the
repo, do **not** bend the implementation to satisfy the wrong number. Implement
what the plan's concrete deliverable specifies and document the discrepancy in
the PR description.

## Turn budget discipline — non-negotiable

You are running with a finite turn budget and a wall-clock cap in an unattended
pipeline, and either can end the run without warning. Anything that has not been
**pushed** is lost — the runner is discarded, so a commit that never left it
counts for exactly as much as an unsaved edit.

- **Commit and push as soon as a step's verification commands pass** — do not
  batch every task into one final push. A local commit dies with the runner.
- **Open the draft PR after the first task, not at the end** — with
  \`gh pr create --draft\`, never ready-for-review, since \`find-pipeline-pr.sh\`
  selects only drafts (#322) — and note in its
  description which tasks are done. A truncated run then leaves reviewable work
  rather than nothing.
- **Trust the plan's line numbers and diffs.** Only re-read a file if a step's
  actual command output contradicts what the plan expected.

Do not \"improve\" adjacent code that the Acceptance Criteria does not name."
```

Replace `<N>` with the actual issue number.

---

If a real dispatch shows the detection rule misfiring, fix the rule here and update this file for the future.
