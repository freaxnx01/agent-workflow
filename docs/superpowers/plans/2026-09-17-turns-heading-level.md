# Implementation plan — size the turn budget from either task heading level

**Issue:** [#359](https://github.com/freaxnx01/agent-workflow/issues/359) ·
**Spec:** [`2026-09-17-turns-heading-level-design.md`](../specs/2026-09-17-turns-heading-level-design.md)

## Goal

`classify-turns.sh` sizes the budget the same whether a plan's tasks are `##` or
`###`, and says so out loud when a plan section yields no countable tasks.

> **Heading levels are load-bearing.** `classify-turns.sh` counts
> `^#{2,3} Task [0-9]+` after this change (`^### Task [0-9]+` before it). Keep
> this plan's own tasks at `###` and their steps at `####` — a plan written at
> `##` is exactly the bug being fixed, and until this lands it would size its own
> dispatch at 50 turns.

## Global constraints

- TDD: the failing test first, every time. `tests/run-script-tests.sh` **already**
  asserts the h3 tiers (6→160, 4→120, 2→80) and carries a regression test from
  #193 pinning h2-falls-through-to-default as correct. The h3 tiers must keep
  passing; that h2 assertion is deliberately superseded, but its exit-0 and
  `DEFAULT_MAX_TURNS` guarantees must be preserved against a genuinely task-free
  body. (An earlier draft of this plan claimed the section had zero assertions —
  that was a faulty extraction on my part, not the truth.)
- Do **not** touch the here-string or the `|| true` on the `grep -c`. The comment
  above them documents a SIGPIPE bug that lost the budget ~42% of the time on a
  57KB body (#280). Changing the pattern is the whole change.
- Do **not** change the tier thresholds (50/80/120/160) or `UNPLANNED_MAX_TURNS`.
- `main` is protected: `gate-selftest` **and** `test` are required, `strict: true`.
  Land via PR, never a direct push, and rebase before pushing.
- Bash prelude and quoting rules per `.ai/stacks/ci.md`.

### Task 1 — cover the current behaviour before changing it

**Files:** `tests/run-script-tests.sh`

**Interface:** none (tests only).

The section `classify-turns — explicit override labels + task-count heuristic`
exists but asserts nothing about task counting. Establish the h3 baseline first,
so the h2 change is provably an *addition* and not a regression.

#### Step 1.1 — Write the baseline assertions

Find the existing `section "classify-turns` block. `CLASSIFY_TURNS` may already be
defined there; if not, define it next to the other script paths. Add a helper and
the h3 cases:

```bash
# plan_body <heading-prefix> <task-count> — a synthetic issue body with N tasks
plan_body() {
  local prefix="$1" n="$2" i
  printf '## Implementation Plan\n\n'
  for (( i = 1; i <= n; i++ )); do
    printf '%s Task %d — something\n\nSome prose.\n\n' "$prefix" "$i"
  done
}

# turns_for <heading-prefix> <task-count>
turns_for() {
  ISSUE_LABELS='ai-implement' ISSUE_NUMBER=1 REPO=o/r \
    ISSUE_BODY="$(plan_body "$1" "$2")" bash "$CLASSIFY_TURNS" 2>/dev/null
}

# h3 baseline — the levels that already worked
assert_contains "$(turns_for '###' 6)" 'chosen: 160' "h3: 6 tasks → 160"
assert_contains "$(turns_for '###' 4)" 'chosen: 120' "h3: 4 tasks → 120"
assert_contains "$(turns_for '###' 2)" 'chosen: 80'  "h3: 2 tasks → 80"
assert_contains "$(turns_for '###' 1)" 'chosen: 50'  "h3: 1 task → default"
```

`ISSUE_LABELS` must be **non-empty** or the script calls the GitHub API and the
test fails with a repository-resolution error rather than an assertion.

`verify:` `bash tests/run-script-tests.sh` passes — these four describe today's
behaviour, so they are green before any change.

#### Step 1.2 — Write the failing h2 assertions

```bash
# h2 — writing-plans' natural output. Fails before the fix: counted as 0 tasks.
assert_contains "$(turns_for '##' 6)" 'chosen: 160' "h2: 6 tasks → 160"
assert_contains "$(turns_for '##' 4)" 'chosen: 120' "h2: 4 tasks → 120"
assert_contains "$(turns_for '##' 2)" 'chosen: 80'  "h2: 2 tasks → 80"
```

`verify:` `bash tests/run-script-tests.sh` now **fails** with exactly these three
named, each reporting `chosen: 50`. That is RED — paste it as the TDD evidence.

### Task 2 — relax the pattern

**Files:** `scripts/classify-turns.sh`

**Interface:** unchanged — same env in, same `turns=`/`reason=` out.

#### Step 2.1 — Change the one line

At the `task_count=` assignment, change the pattern only:

```bash
    # Accept `## Task N` as well as `### Task N`. writing-plans emits h2 and the
    # pipeline counted h3 only, so a fully enriched plan could land with
    # task_count=0 and silently take DEFAULT_MAX_TURNS — #354 died at 51 turns
    # against a 50 cap with a 6-task plan that should have earned 160 (#359).
    task_count="$(grep -cE '^#{2,3} Task [0-9]+' <<< "$ISSUE_BODY" || true)"
```

Leave the here-string, the `|| true`, and the comment above them untouched.

`verify:` `bash tests/run-script-tests.sh` passes, all seven tier assertions from
Task 1 included. That is GREEN — paste it.

#### Step 2.2 — Pin the mixed-level behaviour

A body using both levels for the same task double-counts. Accepted per the spec;
pin it so it is known rather than discovered:

```bash
# Mixed levels double-count. Not a shape a generated plan takes, and over-sizing
# costs a little compute where under-sizing loses the whole run — so this records
# the behaviour rather than guarding it.
mixed="$(printf '## Implementation Plan\n\n## Task 1 — x\n\n### Task 1 — x\n\n')"
out="$(ISSUE_LABELS='ai-implement' ISSUE_NUMBER=1 REPO=o/r ISSUE_BODY="$mixed" \
       bash "$CLASSIFY_TURNS" 2>/dev/null)"
assert_contains "$out" 'chosen: 80' "mixed h2+h3 counts twice (documented, not guarded)"
```

`verify:` passes.

### Task 3 — make a zero-task plan audible

**Files:** `scripts/classify-turns.sh`, `tests/run-script-tests.sh`

**Interface:** unchanged outputs; adds stderr + an annotation.

#### Step 3.1 — Write the failing test

```bash
# A plan section with no countable tasks is almost always a heading-level bug.
# It still takes the default budget, but it must not do so silently.
nostasks="$(printf '## Implementation Plan\n\nProse only, no numbered tasks.\n')"
out="$(ISSUE_LABELS='ai-implement' ISSUE_NUMBER=1 REPO=o/r ISSUE_BODY="$nostasks" \
       bash "$CLASSIFY_TURNS" 2>&1)"
assert_contains "$out" 'chosen: 50'       "zero-task plan still takes the default"
assert_contains "$out" 'no countable'     "zero-task plan warns"
assert_contains "$out" '::warning::'      "zero-task plan emits an Actions annotation"

# ...and a plan that does size must NOT warn.
out="$(ISSUE_LABELS='ai-implement' ISSUE_NUMBER=1 REPO=o/r \
       ISSUE_BODY="$(plan_body '###' 4)" bash "$CLASSIFY_TURNS" 2>&1)"
assert_not_contains "$out" '::warning::'  "a sized plan warns about nothing"
```

`verify:` the first three fail (no warning exists yet); the fourth passes.

#### Step 3.2 — Emit the warning

In the `else` arm of the tier chain — the `task_count` 0-or-1 branch — warn only
when the count is truly zero. One task is a legitimately small plan; zero under a
present plan heading is the bug.

```bash
    else
      chosen="$DEFAULT_MAX_TURNS"; reason="heuristic: ${task_count} plan task(s), default budget enough"
      if (( task_count == 0 )); then
        # An Implementation Plan with no countable tasks is nearly always a
        # heading-level mismatch (#359), not a genuinely task-free plan. Say so:
        # silence here is what let #354 burn a run at the default budget.
        printf 'warn: an Implementation Plan section is present but has no countable `## Task N` / `### Task N` headings; using the default budget of %s\n' \
          "$DEFAULT_MAX_TURNS" >&2
        printf '::warning::Implementation Plan has no countable task headings; budget defaulted to %s turns\n' \
          "$DEFAULT_MAX_TURNS"
      fi
    fi
```

`verify:` `bash tests/run-script-tests.sh` passes in full. Then confirm the real
#354 body would now size correctly, using the committed plan as a stand-in:

```bash
ISSUE_LABELS='ai-implement' ISSUE_NUMBER=1 REPO=o/r \
  ISSUE_BODY="$(printf '## Implementation Plan\n\n'; sed 's/^### Task/## Task/' \
    docs/superpowers/plans/2026-09-16-quality-gate-single-source.md)" \
  bash scripts/classify-turns.sh
# expect: chosen: 160 (heuristic: 6 plan tasks) — h2 now sizes like h3
```

### Task 4 — changelog

**Files:** `CHANGELOG.md`

Add under the **existing** `### Fixed` subsection of `## [Unreleased]` — do not
add a second `### Fixed`, which trips MD024 (`siblings_only: true`). Note that
`classify-turns.sh` now counts both heading levels, what it cost (#354: 51/50
turns, $1.24, no PR, last attempt consumed), and that a zero-task plan now warns.

`verify:` `just lint` is green, MD024 included.

## Verification before the PR

```bash
just test                     # 10 runners, 0 failed
just lint                     # exit 0 — the full gate, == CI
bash tests/run-script-tests.sh  # every new assertion green
```

Then branch, commit, push, open a PR. `gate-selftest` and `test` are both
required checks now, so both must pass before merge.
