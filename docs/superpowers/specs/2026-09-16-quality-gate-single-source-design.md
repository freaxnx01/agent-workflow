# One definition for the quality gate — design

**Issue:** [#354](https://github.com/freaxnx01/agent-workflow/issues/354)
(absorbs [#353](https://github.com/freaxnx01/agent-workflow/issues/353))
**Date:** 2026-09-16

## Problem

The quality gate is defined twice — once in the `justfile` for local runs, once in
CI — and the two copies have drifted in both directions. #353 found the lint half,
#354 the test half; they are one problem with one shape.

### Lint: same tool, different invocation

| | `justfile` `lint` | CI (`pre-commit`) |
|---|---|---|
| invocation | `shellcheck -x -e SC1091` | `shellcheck`, no args |
| shell files scanned | `scripts/` + `tests/` only | every file `identify` calls shell |
| actionlint | native binary | `actionlint-docker` |
| yamllint, markdownlint, typos, gitleaks, ruff, hadolint | not run | run |

Both halves of that table are a gap:

- **CI lacks `-x`.** A script that sources a `lib/` helper is clean under
  `just lint` and fails CI on SC1091. Observed on #350: the first push was locally
  clean and failed CI on three `source` lines. Without `-x`, a
  `# shellcheck source=` directive is inert, so the path in it is never verified.
- **`just lint` lacks coverage.** Twelve tracked shell files live outside
  `scripts/` and `tests/` — `gate-tests/run-selftest.sh`, `hooks/handoff-resume.sh`,
  five under `setup/`, five under `.github/actions/dotnet-quality/`. CI lints them;
  the local gate never has.
- **`just lint` runs one hook of eleven.** markdownlint and typos are CI-only, so
  a local run cannot predict them. Also observed on #350: MD012 and trailing
  whitespace had to be hand-approximated because neither tool is installed.
- **And the divergence already runs the *other* way.** `pre-commit run --all-files`
  **fails locally while CI is green**, found while validating this very design.
  `.markdownlint-cli2.yaml` sets `globs: ["**/*.md"]`, which overrides the file
  list pre-commit passes, so markdownlint-cli2 lints whatever is on disk
  regardless of what git tracks. `.superpowers/` is gitignored and untracked, so
  CI's fresh checkout never has it — but a machine that has run superpowers SDD
  does, and gets 26 MD0xx errors. Proven by hiding the directory and re-running
  the same hook, which then passes.

  The config's own comment at `.markdownlint-cli2.yaml:19-21` already documents
  this exact trap for `.worktrees/**`, and the `ignores:` list already carries
  `.claude/handoffs.md` and `docs/superpowers/**` for the same reason.
  `.superpowers/**` was simply missed. This has to be fixed **before** `just lint`
  delegates, or delegation hands every SDD-using machine a red gate that CI
  cannot reproduce — the same class of bug this issue exists to remove.

`scripts/verify-or-recover-pr.sh:35` already carries the workaround comment
(`disable=SC1091  # hook runs without -x`), so this has been hit before; #350 added
four more. The convention works, but it is discovered by failing CI rather than by
the local gate that exists to prevent exactly that.

### Test: defined once, run nowhere

`tests/run-*-tests.sh` is the Layer-1 suite the CI stack overlay requires in CI.

- **No CI job runs it.** On a PR only `lint` (pre-commit) and `gate-selftest` run.
  A PR that breaks `run-script-tests.sh` — 693 assertions — merges green.
- **The `justfile` recipe lists 7 of 9 runners.**
  `tests/run-parse-enrich-args-tests.sh` and `tests/run-link-skills-tests.sh` are in
  neither the recipe nor CI, so nothing runs them. They pass today; this is drift,
  not breakage — but it is drift nobody would notice.

## Approach

One definition per gate, with every caller delegating to it. Chosen over
re-synchronising two lists, which is what has already failed twice.

### Lint — `pre-commit` is the definition

1. The shellcheck hook gains `args: [-x, -e, SC1091]`, so CI gains the `-x`
   checking the `justfile` has today.
2. `just lint` becomes `pre-commit run --all-files` — the exact command CI runs.
3. A new `just lint-shell` keeps a fast inner-loop path
   (`pre-commit run shellcheck actionlint-docker --all-files`).

**Why `-e SC1091` stays.** `args: [-x]` alone is not sufficient, verified against
the hook's own container:

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt docker.io/koalaman/shellcheck:v0.11.0 -x <files>
```

Clean with today's inline suppressions in place; with them stripped it fails on
`tests/run-ai-funnel-tests.sh:72` and `tests/run-ai-stats-tests.sh:70`, which both
do `source "$SCRIPT"` — a variable `-x` cannot resolve. Their
`# shellcheck source=../scripts/lib/...` directives resolve relative to the working
directory, not the file, so from the repo root they point above it. The five inline
`disable=SC1091` comments therefore **stay**; `-e SC1091` reproduces today's
behaviour exactly.

### Test — one discovery script is the definition

1. New `tests/run-all.sh` discovers runners with
   `find tests -type f -name 'run-*-tests.sh'` and runs each, failing on the first
   non-zero exit and printing a summary.
2. `just test` calls it.
3. A new `test` job in `.github/workflows/lint.yml` calls it on `pull_request`.

Discovery rather than a list is the point: the two missing runners are fixed *by
construction*, and a future runner cannot be forgotten. This mirrors the
`find`-over-glob rule the stack overlay already states for shellcheck — `**/*.sh`
silently skips nested directories without `globstar`.

`find` must not match `run-all.sh` itself. It does not (`run-*-tests.sh`), but the
plan asserts it.

## Consequences

- **`just lint` stops meaning "Layer 0 for shell and workflows" and becomes the
  whole polyglot gate.** The recipe's comment at `justfile:10` becomes false and is
  updated. Runtime goes from ~2s to the full gate, including three Docker image
  pulls on a cold cache. `lint-shell` exists for the inner loop.
- **`just lint` gains a dependency on `pre-commit`**, which is not installed on the
  author's machine today (`pre-commit: command not found`). Docker is present, which
  the shellcheck, actionlint and hadolint hooks need. The recipe must fail with an
  actionable message rather than a bare `command not found`.
- **`just lint` will start reporting pre-existing findings** in the twelve
  previously-unscanned shell files and from the ten previously-unrun hooks. The
  first draft of this spec predicted zero, "since CI is green" — **that prediction
  was wrong**, and checking it is what found the `.superpowers/**` gap above. CI
  being green proves nothing about a local run whose file set is larger, because
  markdownlint's `globs:` reads the disk rather than the index. After Task 0 the
  count is zero, verified by running the gate rather than by inference.
- **A failing `test` job is visible but not blocking.** `main`'s protection pins
  `required_status_checks.contexts` to `["gate-selftest"]` only. Until `test` is
  added there, a red test job does not prevent merge. That is a repo-settings
  change, called out as an explicit step rather than made silently.

## Acceptance criteria

- [ ] A PR that breaks any `tests/run-*-tests.sh` fails CI
- [ ] Adding a new `tests/run-*-tests.sh` requires no edit to any list for it to run
      in both `just test` and CI
- [ ] `just test` and CI run the same set of runners, including
      `run-parse-enrich-args-tests.sh` and `run-link-skills-tests.sh`
- [ ] A script that sources a `lib/` helper is checked with `-x` in CI, so the
      `# shellcheck source=` path is verified rather than inert
- [ ] `just lint` runs the same command as CI, so a clean local run predicts a clean
      CI lint
- [ ] `pre-commit run --all-files` passes on a working copy that contains an
      untracked `.superpowers/` directory, so local and CI agree
- [ ] `just lint` fails with an actionable message when `pre-commit` is absent
- [ ] `just lint-shell` exists as the fast shell-and-workflow-only path
- [ ] `just lint` and `just test` are green on the resulting branch

## Out of scope

Written down, not acted on:

- Adding `test` to `main`'s `required_status_checks` — a settings change for the
  repo owner; the plan surfaces it as a manual step.
- `#355` (`ADD_TO_PROJECT_PAT` invalid, 100 consecutive failures). Unrelated, needs
  a human-minted token.
- The Node 20 deprecation warning from `actions/add-to-project@v1.0.2`. Tracked in
  #355.
- Any *further* finding the widened local lint surfaces beyond the
  `.superpowers/**` gap Task 0 fixes. If one appears it gets its own issue rather
  than growing this one.
