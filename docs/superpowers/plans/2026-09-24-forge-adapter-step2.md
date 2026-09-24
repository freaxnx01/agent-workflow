# Forge adapter — step 2 of 4 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the implement job's four write operations behind adapter verbs, with **no behaviour change on GitHub**.

**Architecture:** `scripts/lib/forge.sh` gains four write verbs beside the read one. Unlike step 1, the call sites *do* change — these scripts call `gh` directly with no injection seam to fill — so each migration is a like-for-like substitution with the fallback removed, not added.

**Tech Stack:** Bash 5, `gh` mocked in `tests/mocks/`, `shellcheck -x`, `actionlint`.

**Spec:** `docs/superpowers/specs/2026-09-24-agent-implement-forge-adapter-design.md`

> **Scope.** Step 2 of four. Steps 3 (`forge-azdo.sh`) and 4 (the ADO entry point) follow separately.

## Global Constraints

- **Step 2 ships no new capability.** Its value is that nothing observable changes on GitHub. A behaviour difference is a bug.
- **These are writes.** A mistake here comments on, labels, or opens PRs against real issues. Every verb is exercised against the `gh` mock before any script is migrated.
- Verbs keep each caller's current contract: same stdout, same exit codes, same idempotence. `ensure-issue-labels.sh` in particular must stay idempotent — an existing label is preserved unchanged, colour included.
- `scripts/lib/forge.sh` stays sourced-not-executed; functions only.
- **Do not touch `check-merge-envelope.sh`** — verb 6, out of scope by design.
- Layer-1 tests only: no network, `gh` mocked, under 5 seconds.
- `shellcheck -x -e SC1091`, `actionlint`, `markdownlint` stay clean.

## The four verbs

| Verb | Replaces | Used by |
|---|---|---|
| `forge_issue_comment <n> <body-file>` | `gh issue comment` | `post-run-report`, `check-attempt-cap` |
| `forge_issue_label_add <n> <csv>` | `gh issue edit --add-label` | `post-run-report`, `ensure-issue-labels`, `check-attempt-cap` |
| `forge_issue_label_remove <n> <name>` | `gh issue edit --remove-label` | `post-run-report` |
| `forge_label_ensure <name> <color> <desc>` | `gh label create` | `ensure-issue-labels`, `check-attempt-cap` |

`verify-or-recover-pr.sh`'s `gh pr create --draft` is **deliberately left for step 3**: it is the only verb whose ADO form needs a work-item link (`--work-items`), so it is better designed alongside `forge-azdo.sh` than guessed at now.

---

### Task 1: The four write verbs

**Files:**
- Modify: `scripts/lib/forge.sh`
- Modify: `tests/run-forge-adapter-tests.sh`

**Interfaces:**
- Consumes: `detect_forge`, and `REPO` from the environment.
- Produces: the four verbs above. Each returns `0` on success, `1` on a forge error, `2` on an unsupported forge — matching `forge_export_issue`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-forge-adapter-tests.sh`. Assert on the **argv the mock records**, since a write verb's contract is the call it makes:

```bash
section "write verbs — the call reaches the forge intact"

w_dir="$(mktemp -d)"
w_log="$w_dir/gh.log"
REPO_W="$(make_repo 'https://github.com/o/r.git')"

run_write() {
  : > "$w_log"
  # shellcheck disable=SC2030,SC2031
  (
    cd "$REPO_W"
    export PATH="$MOCKS:$PATH" GH_MOCK_LOG="$w_log" GH_MOCK_AUTH_HOSTS="github.com" REPO=o/r
    # shellcheck disable=SC1090
    source "$ROOT/scripts/lib/detect-forge.sh"
    # shellcheck disable=SC1090
    source "$LIB"
    "$@"
  ) >/dev/null 2>&1
  cat "$w_log"
}

printf 'hello\n' > "$w_dir/body.md"
assert_eq "comment passes a body FILE, never an argv body" \
  "issue comment 42 --repo o/r --body-file $w_dir/body.md" \
  "$(run_write forge_issue_comment 42 "$w_dir/body.md")"

assert_eq "label add" "issue edit 42 --repo o/r --add-label a,b" \
  "$(run_write forge_issue_label_add 42 'a,b')"

assert_eq "label remove" "issue edit 42 --repo o/r --remove-label a" \
  "$(run_write forge_issue_label_remove 42 'a')"

assert_eq "label ensure" "label create x --repo o/r --color FF0000 --description d" \
  "$(run_write forge_label_ensure x FF0000 d)"

rm -rf "$w_dir" "$REPO_W"
```

The comment verb takes a **file**, not a string. A run report is multi-line and can exceed a comfortable argv length; `post-run-report.sh` already uses `--body-file` for exactly that reason, and the verb must not regress it.

- [ ] **Step 2: Run to verify they fail**

Run: `tests/run-forge-adapter-tests.sh`

Expected: four failures — the verbs do not exist.

- [ ] **Step 3: Implement**

Append to `scripts/lib/forge.sh`:

```bash
# --- write verbs -------------------------------------------------------------
#
# Each mirrors one gh call the implement job already makes. They exist so the
# call sites stop naming a forge, not to add behaviour: same arguments, same
# exit codes, same idempotence as the gh form they replace.

# forge_issue_comment <issue-number> <body-file>
# Takes a FILE, not a string: a run report is multi-line and long enough that
# passing it as an argument is a real risk.
forge_issue_comment() {
  local n="${1:?forge_issue_comment requires an issue number}"
  local f="${2:?forge_issue_comment requires a body file}"
  : "${REPO:?REPO must be set}"
  case "$(detect_forge | awk '{print $1}')" in
    github) gh issue comment "$n" --repo "$REPO" --body-file "$f" ;;
    *) printf 'forge.sh: no comment adapter for this forge yet (#253)\n' >&2; return 2 ;;
  esac
}

# forge_issue_label_add <issue-number> <comma-separated-names>
forge_issue_label_add() {
  local n="${1:?forge_issue_label_add requires an issue number}"
  local labels="${2:?forge_issue_label_add requires labels}"
  : "${REPO:?REPO must be set}"
  case "$(detect_forge | awk '{print $1}')" in
    github) gh issue edit "$n" --repo "$REPO" --add-label "$labels" ;;
    *) printf 'forge.sh: no label adapter for this forge yet (#253)\n' >&2; return 2 ;;
  esac
}

# forge_issue_label_remove <issue-number> <name>
forge_issue_label_remove() {
  local n="${1:?forge_issue_label_remove requires an issue number}"
  local label="${2:?forge_issue_label_remove requires a label}"
  : "${REPO:?REPO must be set}"
  case "$(detect_forge | awk '{print $1}')" in
    github) gh issue edit "$n" --repo "$REPO" --remove-label "$label" ;;
    *) printf 'forge.sh: no label adapter for this forge yet (#253)\n' >&2; return 2 ;;
  esac
}

# forge_label_ensure <name> <color> <description>
# Idempotent by contract: an existing label is left exactly as it is, colour
# included. ensure-issue-labels.sh depends on that and says so.
forge_label_ensure() {
  local name="${1:?forge_label_ensure requires a name}"
  local color="${2:?forge_label_ensure requires a color}"
  local desc="${3:?forge_label_ensure requires a description}"
  : "${REPO:?REPO must be set}"
  case "$(detect_forge | awk '{print $1}')" in
    github) gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" ;;
    *) printf 'forge.sh: no label adapter for this forge yet (#253)\n' >&2; return 2 ;;
  esac
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `tests/run-forge-adapter-tests.sh` — all cases green, step 1's included.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/lib/forge.sh tests/run-forge-adapter-tests.sh
tests/run-all.sh
git add scripts/lib/forge.sh tests/run-forge-adapter-tests.sh
git commit -m "feat(forge): add the four write verbs

Mirrors the gh calls the implement job already makes, so the call sites can stop
naming a forge. No behaviour change: same arguments, same exit codes, same
idempotence.

The comment verb takes a body FILE rather than a string, because a run report is
multi-line and long enough that passing it as an argument is a real risk --
post-run-report.sh already uses --body-file for that reason.

gh pr create is deliberately not here. It is the one verb whose ADO form needs a
work-item link, so it is better designed alongside forge-azdo.sh in step 3 than
guessed at now.

Refs #253"
```

---

### Task 2: Migrate the three label/comment callers

**Files:**
- Modify: `scripts/post-run-report.sh`
- Modify: `scripts/ensure-issue-labels.sh`
- Modify: `scripts/check-attempt-cap.sh`

**Interfaces:**
- Consumes: the four verbs from Task 1.
- Produces: nothing new — each script keeps its exact contract.

- [ ] **Step 1: Record current behaviour**

```bash
tests/run-all.sh 2>&1 | tail -3
```

Note the runner count and totals. Step 4 compares against them.

- [ ] **Step 2: Migrate, one script at a time**

In each, source the adapter beside its existing lib sources and replace the `gh`
calls with verbs — nothing else:

```bash
# shellcheck source=scripts/lib/forge.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/forge.sh"
```

| Was | Becomes |
|---|---|
| `gh issue comment "$N" --repo "$REPO" --body-file "$f"` | `forge_issue_comment "$N" "$f"` |
| `gh issue edit "$N" --repo "$REPO" --add-label "$csv"` | `forge_issue_label_add "$N" "$csv"` |
| `gh issue edit "$N" --repo "$REPO" --remove-label "$l"` | `forge_issue_label_remove "$N" "$l"` |
| `gh label create "$n" --repo "$REPO" --color "$c" --description "$d"` | `forge_label_ensure "$n" "$c" "$d"` |

**`check-attempt-cap.sh` passes `--body` as a string, not `--body-file`.** The
verb takes a file, so that call needs a `mktemp` + `trap ... EXIT` around it —
which is this repo's own convention for temp files anyway. That is the one place
where the migration is not a pure substitution, and it is still externally a
no-op: the same body reaches the same endpoint.

**Preserve every existing error-suppression exactly.** Several of these calls end
in `2>/dev/null || true` because a missing label is a no-op rather than a failure;
dropping that turns a tolerated condition into a job failure.

- [ ] **Step 3: Migrate `check-attempt-cap.sh` last and re-read its guard**

It both reads (via `ISSUE_COMMENTS_JSON`, already seamed) and writes. Only the
write half changes. Its parking path applies a label **and** posts a comment, and
the order matters: the comment explains the label, so a failure between them
should leave the issue unlabelled rather than silently parked. Keep whatever
ordering it has today.

- [ ] **Step 4: Prove the no-op**

Run: `tests/run-all.sh`

Expected: the same runner count and the same totals as Step 1. These three scripts
have existing fixture tests that assert on the `gh` argv the mock records — those
are exactly the assertions that catch a changed call, so **they must pass
unchanged, not be updated**. If one needs editing to go green, the migration
changed behaviour.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck -x -e SC1091 scripts/post-run-report.sh scripts/ensure-issue-labels.sh scripts/check-attempt-cap.sh
git add scripts/post-run-report.sh scripts/ensure-issue-labels.sh scripts/check-attempt-cap.sh
git commit -m "refactor(scripts): route issue writes through the forge adapter

post-run-report, ensure-issue-labels and check-attempt-cap now call the write
verbs instead of gh directly. Each keeps its exact contract -- same arguments,
same exit codes, same error suppression, same idempotence.

The existing fixture tests assert on the argv the gh mock records, so they are
the check that the calls did not change. They pass unchanged.

verify-or-recover-pr is not migrated here: gh pr create is the one verb whose ADO
form needs a work-item link, and it belongs with step 3.

Refs #253"
```

---

## Verification

```bash
tests/run-all.sh
shellcheck -x -e SC1091 scripts/lib/forge.sh scripts/post-run-report.sh scripts/ensure-issue-labels.sh scripts/check-attempt-cap.sh
grep -c 'gh issue\|gh label' scripts/post-run-report.sh scripts/ensure-issue-labels.sh   # expect 0
```

**The existing fixture tests passing unchanged is the acceptance criterion.** They
assert on recorded argv, so they are what proves the migration was like-for-like.
A green suite after editing an assertion proves nothing.
