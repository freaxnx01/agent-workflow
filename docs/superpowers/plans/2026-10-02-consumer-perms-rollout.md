# Consumer Permissions Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the operator a dry-run-by-default tool that adds the scopes a consumer's `agent.yml` is missing (`perms:MISSING`, #434) to its caller `permissions:` block and opens **one PR per repo** — so the 37 `game-*` consumers lacking `actions: write` can be fixed in one reviewed rollout (#441).

**Architecture:** A third mode, `--fix-perms`, in `scripts/migrate-consumers.sh`. A pure awk rewriter `rewrite_perms` (seam `FIX_PERMS_STDIN=1`, like `rewrite_pin`/`REWRITE_STDIN`) inserts or raises scopes in the block GitHub applies to the job calling `agent-implement.yml` — that job's own block, else top-level (#434 semantics) — and refuses (exit 3) shapes it cannot edit safely. `fix_perms_repo` turns the existing `perms_verdict` into a per-repo action; the existing PUT/branch block is extracted into `put_stub` and shared with migrate mode.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), awk, the `gh` mock (`GH_MOCK_STDOUT_MAP`, `GH_MOCK_FAIL_MAP`, `GH_MOCK_LOG`), `shellcheck`. No `yq`/Python.

**Spec:** `docs/superpowers/specs/2026-10-02-consumer-perms-rollout-design.md`

## Global Constraints

- `set -euo pipefail` + `IFS=$'\n\t'`; quote every expansion; `[[ ... ]]`; `printf` over `echo`; no `eval`.
- **⛔ Do not modify any other repository.** Deliver and test the tool only. Running `--fix-perms --apply` against the 37 real consumers is an operator step after merge (documented in Task 3), never part of this run. No real `gh` call in any test — everything through `tests/mocks/gh`.
- **Never hard-code `actions: write`** in the tool. The scopes come from `check-caller-permissions.sh`; a future scope must roll out the same way.
- **Migrate mode's behaviour must not change.** Task 2 only *extracts* its PUT/branch block into `put_stub`; the existing `migrate-consumers` sections must stay green unmodified.
- Do not edit `scripts/check-caller-permissions.sh` — the rewriter mirrors its block-selection rule, it does not change it.
- Conventional Commits; scope `consumer`; every subject ends in `(#441)`.

**Line numbers are as of `origin/main` 6c6ac39.** Anchor on quoted text.

---

### Task 1: The rewriter, test first

**Files:**
- Modify: `tests/run-script-tests.sh` — insert after `rm -rf "$mig_tmp"` (end of `section "migrate-consumers — inventory flags stubs that under-grant (#434)"`, ~:2008), before `# Bad invocation is a usage error`
- Modify: `scripts/migrate-consumers.sh` — header `# Seams (tests):` and `# Exit codes:`; new functions before `if [[ "${REWRITE_STDIN:-}" == "1" ]]; then` (~:124)

**Interfaces:**
- Produces: `rewrite_perms <grants> <calls>` — stub on stdin; `<grants>` comma-separated `scope=level`; `<calls>` the reusable workflow's file name (`agent-implement.yml`). Prints the rewritten stub, exit 0; on an uneditable shape prints the reason, exit 3. Seam: `FIX_PERMS_STDIN=1 GRANTS=… bash scripts/migrate-consumers.sh` (exit 2 without `GRANTS`, exit 3 + `error: cannot edit: …` on stderr). Task 2 consumes `rewrite_perms` and the `FP_STALE`/`FP_FIXED` test fixtures.

- [ ] **Step 1: Write the failing tests**

Insert at the anchor above:

```bash
section "migrate-consumers — --fix-perms rewriter adds missing scopes (#441)"

fix_perms() {  # <grants> ; stub on stdin. Sets OUT and RC; stderr into ERR.
  local errf; errf="$(mktemp)"
  RC=0
  OUT="$(FIX_PERMS_STDIN=1 GRANTS="$1" bash "$MIGRATE" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

# game-sky-fury's agent.yml before game-sky-fury#7, aligned comments and all:
# the shape 37 consumers are in.
FP_STALE=$'name: Claude\non:\n  issues:\n    types: [labeled]\n\npermissions:            # a reusable workflow can\'t be granted more than its\n  contents: write       # caller; the repo\'s default GITHUB_TOKEN is read-only,\n  pull-requests: write  # so omitting this fails the run at startup_failure.\n  issues: write\n\njobs:\n  claude:\n    if: github.event.label.name == \'ai-implement\'\n    uses: freaxnx01/agent-workflow/.github/workflows/agent-implement.yml@v2\n    with:\n      pipeline-ref: v2'
FP_FIXED=$'name: Claude\non:\n  issues:\n    types: [labeled]\n\npermissions:            # a reusable workflow can\'t be granted more than its\n  contents: write       # caller; the repo\'s default GITHUB_TOKEN is read-only,\n  pull-requests: write  # so omitting this fails the run at startup_failure.\n  issues: write\n  actions: write\n\njobs:\n  claude:\n    if: github.event.label.name == \'ai-implement\'\n    uses: freaxnx01/agent-workflow/.github/workflows/agent-implement.yml@v2\n    with:\n      pipeline-ref: v2'

fix_perms 'actions=write' < <(printf '%s' "$FP_STALE")
assert_equals "$RC" "0" "top-level block: rewriter exits 0"
assert_equals "$OUT" "$FP_FIXED" "  → appends actions: write after the last entry, comments and order intact"

fix_perms 'actions=write' < <(printf '%s' "$FP_FIXED")
assert_equals "$OUT" "$FP_FIXED" "an already-fixed stub is a no-op (idempotent)"

# The calling job's own block REPLACES the top-level one (#434 semantics), so
# that is the block to extend — the top-level one must stay as it was.
FP_JOB=$'permissions:\n  contents: read\njobs:\n  claude:\n    permissions:\n      contents: write\n      # retry needs this job\'s block, not the top one\n      issues: write\n    uses: freaxnx01/agent-workflow/.github/workflows/agent-implement.yml@v2\n'
fix_perms 'actions=write' < <(printf '%s' "$FP_JOB")
assert_contains "$OUT" $'      issues: write\n      actions: write\n    uses:' "job-level block on the calling job is the one extended"
assert_contains "$OUT" $'permissions:\n  contents: read\njobs:' "  → the top-level block is untouched"

# An unrelated job's block is not the caller's: the calling job inherits top-level.
FP_OTHER=$'permissions:\n  contents: write\njobs:\n  lint:\n    permissions:\n      contents: read\n    runs-on: x\n  claude:\n    uses: freaxnx01/agent-workflow/.github/workflows/agent-implement.yml@v2\n'
fix_perms 'actions=write' < <(printf '%s' "$FP_OTHER")
assert_contains "$OUT" $'permissions:\n  contents: write\n  actions: write\njobs:' "an unrelated job's block is ignored; top-level is extended"
assert_contains "$OUT" $'      contents: read\n    runs-on: x' "  → the unrelated job's block is untouched"

# A scope granted too low is raised in place, trailing comment kept.
fix_perms 'contents=write' < <(printf 'permissions:\n  contents: read   # keep me\njobs:\n  c:\n    uses: o/r/.github/workflows/agent-implement.yml@v2\n')
assert_contains "$OUT" '  contents: write   # keep me' "read → write is raised in place, comment kept"

# Shapes it cannot edit safely: refuse loudly, never guess.
for shape in 'permissions: { contents: write }' 'permissions: read-all' 'name: no-block'; do
  fix_perms 'actions=write' < <(printf '%s\njobs:\n  c:\n    uses: o/r/.github/workflows/agent-implement.yml@v2\n' "$shape")
  assert_equals "$RC" "3" "refuses '$shape' with exit 3"
  assert_contains "$ERR" 'cannot edit' "  → and says why on stderr"
done

fix_perms 'actions=write' < <(printf 'permissions:\n  contents: write\njobs:\n  c:\n    uses: o/r/.github/workflows/other.yml@v2\n')
assert_equals "$RC" "3" "refuses a stub with no job calling agent-implement.yml"

set +e
FIX_PERMS_STDIN=1 bash "$MIGRATE" </dev/null >/dev/null 2>&1
rc=$?
set -e
assert_equals "$rc" "2" "FIX_PERMS_STDIN without GRANTS exits 2"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | sed -n '/fix-perms rewriter/,/── /p'`
Expected: FAIL — `top-level block: rewriter exits 0` reports `expected '0' got '2'` (the seam does not exist, so the script falls through to "pass --owner or at least one --repo"). `FIX_PERMS_STDIN without GRANTS exits 2` passes vacuously at this point; it becomes meaningful in Step 3.

- [ ] **Step 3: Implement the rewriter and its seam**

In the header, under `# Seams (tests):`, after the `REWRITE_STDIN` entry:

```bash
#   FIX_PERMS_STDIN When '1', read a stub on stdin and write it back with the
#                   GRANTS added (comma-separated `scope=level`, e.g.
#                   `actions=write`). Exits 3, reason on stderr, on a shape it
#                   cannot edit safely. No network.
```

Under `# Exit codes:`, after `#   2  bad arguments`:

```bash
#   3  FIX_PERMS_STDIN only: the stub's shape cannot be edited safely
```

Before `if [[ "${REWRITE_STDIN:-}" == "1" ]]; then`:

```bash
# rewrite_perms <grants> <calls> — stub on stdin; prints it with each
# `scope=level` in <grants> (comma-separated) granted. <calls> is the reusable
# workflow's file name. The block edited is the one GitHub uses for the calling
# job (#434): the job's own `permissions:` if it has one, else the top-level
# block. A missing scope is appended after the block's last entry at the
# entries' indent; a lower grant is raised in place, trailing comment kept.
# Anything else in the file is printed byte-for-byte.
# On a shape it cannot edit safely (flow style, read-all/write-all, no block,
# no calling job) prints the reason and exits 3 — never a guess.
rewrite_perms() {
  awk -v grants="$1" -v calls="/$2@" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function strip(s) { sub(/[[:space:]]+#.*$/, "", s); sub(/^ +/, "", s); return s }
    function rank(l) { return l == "write" ? 2 : (l == "read" ? 1 : 0) }
    function refuse(why) { print why; bad = 1; exit 3 }
    { L[++n] = $0 }
    END {
      if (bad) exit 3
      for (i = 1; i <= n; i++) {
        if (L[i] ~ /^[[:space:]]*(#|$)/) continue
        ind = indent(L[i]); t = strip(L[i])
        if (ind == 0) { injobs = (t == "jobs:"); job = "" }
        if (ind == 0 && t ~ /^permissions:/) top = i
        if (injobs && ind == 2 && t ~ /^[A-Za-z0-9_-]+:$/) job = substr(t, 1, length(t) - 1)
        if (injobs && ind == 4 && job != "" && t ~ /^permissions:/) own[job] = i
        if (injobs && ind == 4 && job != "" && t ~ /^uses:/ && index(t, calls)) caller = job
      }
      if (caller == "") refuse("no job calls " substr(calls, 2, length(calls) - 2))
      hdr = (caller in own) ? own[caller] : top
      if (!hdr) refuse("no permissions: block for job " caller " to extend")
      val = strip(L[hdr]); sub(/^permissions:[[:space:]]*/, "", val)
      if (val ~ /^\{/) refuse("flow-style permissions: " val)
      if (val != "") refuse("permissions: " val " (expanding it would change every other scope)")

      hind = indent(L[hdr]); last = hdr; eind = -1
      for (i = hdr + 1; i <= n; i++) {
        if (L[i] ~ /^[[:space:]]*(#|$)/) continue
        ind = indent(L[i])
        if (ind <= hind) break
        if (eind < 0) eind = ind
        if (ind != eind) continue
        key = strip(L[i]); sub(/:.*/, "", key); at[key] = i; last = i
      }
      if (eind < 0) eind = hind + 2
      pad = ""; for (k = 0; k < eind; k++) pad = pad " "

      m = split(grants, g, ",")
      for (k = 1; k <= m; k++) {
        split(g[k], kv, "="); key = kv[1]; lvl = kv[2]
        if (key == "") continue
        if (key in at) {
          i = at[key]; cur = strip(L[i]); sub(/^[^:]*:[[:space:]]*/, "", cur)
          if (rank(cur) >= rank(lvl)) continue
          match(L[i], /:[[:space:]]*[^[:space:]#]+/)
          head = substr(L[i], 1, RSTART - 1); seg = substr(L[i], RSTART, RLENGTH); tail = substr(L[i], RSTART + RLENGTH)
          match(seg, /^:[[:space:]]*/)
          L[i] = head substr(seg, 1, RLENGTH) lvl tail
        } else {
          add = add pad key ": " lvl "\n"
        }
      }
      for (i = 1; i <= n; i++) { print L[i]; if (i == last && add != "") printf "%s", add }
    }'
}

if [[ "${FIX_PERMS_STDIN:-}" == "1" ]]; then
  [[ -n "${GRANTS:-}" ]] || usage_error "GRANTS must be set for FIX_PERMS_STDIN"
  rc=0
  out="$(rewrite_perms "$GRANTS" "$(basename "$REUSABLE")")" || rc=$?
  if (( rc != 0 )); then printf 'error: cannot edit: %s\n' "$out" >&2; exit 3; fi
  printf '%s\n' "$out"
  exit 0
fi
```

- [ ] **Step 4: Run them to verify they pass**

Run: `bash tests/run-script-tests.sh 2>&1 | sed -n '/fix-perms rewriter/,/── /p'`
Expected: every line in the section is `✓` (16 assertions).

Run: `bash tests/run-script-tests.sh`
Expected: final line reports 0 failed (the pre-existing `migrate-consumers` sections stay green).

Run: `shellcheck scripts/migrate-consumers.sh tests/run-script-tests.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add scripts/migrate-consumers.sh tests/run-script-tests.sh
git commit -m "feat(consumer): add a caller-permissions rewriter to migrate-consumers (#441)"
```

---

### Task 2: `--fix-perms` — one PR per repo, dry run by default

**Files:**
- Modify: `tests/run-script-tests.sh` — append directly after Task 1's section (it reuses `FP_STALE`/`FP_FIXED`)
- Modify: `scripts/migrate-consumers.sh` — header, defaults (`BRANCH=`, ~:64), arg loop (~:133-141), post-parse block, `put_stub` extraction (~:196-207), the repo loop, the summary

**Interfaces:**
- Consumes: `rewrite_perms` (Task 1), `perms_verdict` and `check-caller-permissions.sh` (#434).
- Produces: `--fix-perms` CLI mode; per-repo lines `perms ok` / `perms:ERROR  not edited` / `cannot edit: <reason>` / `PR already open <url>` / `would fix → <scopes>  perms:MISSING <scopes>` / `fixed → PR <url>` / `WRITE FAILED` / `PR FAILED (branch <b> written)`; exit 1 if any repo failed. Task 3 documents it.

- [ ] **Step 1: Write the failing tests**

Append after Task 1's section:

```bash
section "migrate-consumers — --fix-perms rollout, one PR per repo (#441)"

fp_tmp="$(mktemp -d)"
printf 'deadbeef\n' > "$fp_tmp/sha"
printf '%s' "$FP_STALE" | base64 -w0 > "$fp_tmp/stale.b64"
printf '%s' "$FP_FIXED" | base64 -w0 > "$fp_tmp/ok.b64"
printf 'permissions: read-all\njobs:\n  c:\n    uses: o/r/.github/workflows/agent-implement.yml@v2\n' \
  | base64 -w0 > "$fp_tmp/odd.b64"
printf 'https://github.com/o/open/pull/9\n' > "$fp_tmp/open-pr"
# ORDER MATTERS: the mock returns the first match, and only the sha call
# carries `.sha`. `o/open` is the stale stub with a fix PR already open.
printf '.sha\t%s\nrepos/o/stale/contents\t%s\nrepos/o/open/contents\t%s\nrepos/o/ok/contents\t%s\nrepos/o/odd/contents\t%s\npr list --repo o/open\t%s\n' \
  "$fp_tmp/sha" "$fp_tmp/stale.b64" "$fp_tmp/stale.b64" "$fp_tmp/ok.b64" "$fp_tmp/odd.b64" "$fp_tmp/open-pr" > "$fp_tmp/map"

fp_run() {  # <consumers> [args...] ; sets OUT, RC; gh calls land in $fp_tmp/log
  local consumers="$1"; shift
  : > "$fp_tmp/log"
  RC=0
  OUT="$(PATH="$MOCKS:$PATH" GH_MOCK_LOG="$fp_tmp/log" GH_MOCK_STDOUT_MAP="$fp_tmp/map" \
         CONSUMERS="$consumers" bash "$MIGRATE" --fix-perms "$@" 2>&1)" || RC=$?
}

fp_run $'o/stale\no/ok'
assert_contains "$OUT" 'o/stale  v2  would fix → actions  perms:MISSING actions' "dry run names the scopes it would add"
assert_contains "$OUT" 'o/ok  v2  perms ok' "  → a perms:ok repo is skipped"
assert_not_contains "$(cat "$fp_tmp/log")" '-X PUT' "  → and nothing is written without --apply"
assert_equals "$RC" "0" "  → dry run exits 0"

fp_run $'o/stale\no/ok' --apply
log="$(cat "$fp_tmp/log")"
assert_contains "$log" '-X PUT repos/o/stale/contents/.github/workflows/agent.yml' "--apply writes the stale stub"
assert_contains "$log" 'branch=fix/agent-workflow-caller-permissions' "  → on a fix branch, never the default branch"
assert_contains "$log" 'pr create --repo o/stale --head fix/agent-workflow-caller-permissions' "  → and opens one PR for it"
assert_not_contains "$log" 'repos/o/ok/contents/.github/workflows/agent.yml -f' "  → the perms:ok repo is not written"
written="$(grep -o 'content=[A-Za-z0-9+/=]*' "$fp_tmp/log" | head -1 | sed 's/^content=//' | base64 -d)"
assert_equals "$written" "$FP_FIXED" "  → the written stub is exactly the rewriter's output"
assert_contains "$OUT" 'o/stale  v2  fixed → PR' "  → and says so"

fp_run 'o/open' --apply
assert_contains "$OUT" 'o/open  v2  PR already open https://github.com/o/open/pull/9' "an open fix PR is not duplicated on a re-run"
assert_not_contains "$(cat "$fp_tmp/log")" '-X PUT' "  → nothing is written for it"

fp_run 'o/odd' --apply
assert_contains "$OUT" 'o/odd  v2  cannot edit:' "an uneditable shape is reported"
assert_not_contains "$(cat "$fp_tmp/log")" '-X PUT' "  → and never written"
assert_equals "$RC" "1" "  → and the run exits 1"

RC=0
OUT="$(PATH="$MOCKS:$PATH" GH_MOCK_LOG="$fp_tmp/log" GH_MOCK_STDOUT_MAP="$fp_tmp/map" \
       REUSABLE="$fp_tmp/missing.yml" CONSUMERS='o/stale' bash "$MIGRATE" --fix-perms --apply 2>/dev/null)" || RC=$?
assert_contains "$OUT" 'o/stale  v2  perms:ERROR  not edited' "perms:ERROR is reported, never edited"
assert_equals "$RC" "1" "  → and the run exits 1"

printf 'pr create\n' > "$fp_tmp/fail"
RC=0
OUT="$(PATH="$MOCKS:$PATH" GH_MOCK_LOG="$fp_tmp/log" GH_MOCK_STDOUT_MAP="$fp_tmp/map" GH_MOCK_FAIL_MAP="$fp_tmp/fail" \
       CONSUMERS='o/stale' bash "$MIGRATE" --fix-perms --apply 2>&1)" || RC=$?
assert_contains "$OUT" 'o/stale  v2  PR FAILED' "a failed pr create is not reported as fixed"
assert_equals "$RC" "1" "  → and the run exits 1"
rm -rf "$fp_tmp"

set +e
bash "$MIGRATE" --repo o/x --fix-perms --to v3 >/dev/null 2>&1
rc=$?
set -e
assert_equals "$rc" "2" "--fix-perms with --to is a usage error"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | sed -n '/fix-perms rollout/,/── /p'`
Expected: FAIL — `dry run names the scopes it would add` fails (`--fix-perms` is an unknown argument → exit 2, `error: unknown argument`). `--fix-perms with --to is a usage error` passes vacuously for the same reason; it becomes meaningful in Step 3.

- [ ] **Step 3: Implement the mode**

3a. Header. After the `#   migrate (--to <ref>) …` line:

```bash
#   fix-perms            Add the scopes a perms:MISSING stub lacks to its
#     (--fix-perms)      caller `permissions:` block, one PR per repo (#441).
#                        Dry-run unless --apply; always via a PR.
```

After the `#   --path <path> …` argument:

```bash
#   --fix-perms          fix-perms mode (see above). Not combinable with --to:
#                        a pin bump and a permissions fix are separate PRs.
#                        Branch defaults to 'fix/agent-workflow-caller-permissions'.
```

Under `# Exit codes:`, between `0` and `2`:

```bash
#   1  --fix-perms only: at least one repo could not be fixed (perms:ERROR,
#      uneditable shape, write or PR failure) — the operator must look
```

After the exit-code list (after Task 1's `3` line):

```bash
#
# Rolling out a permissions fix (#441) — an operator step, never run by CI:
#   bash scripts/migrate-consumers.sh --owner freaxnx01 --fix-perms           # dry run
#   bash scripts/migrate-consumers.sh --owner freaxnx01 --fix-perms --apply
#   bash scripts/migrate-consumers.sh --owner freaxnx01                       # expect perms:ok
```

3b. Defaults — replace `BRANCH='chore/migrate-agent-workflow'` with:

```bash
BRANCH=''
FIX_PERMS=false
```

3c. Arg loop — add before `-h|--help`, and make `--help` print the whole (now longer) header instead of a fixed 50 lines:

```bash
    --fix-perms) FIX_PERMS=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
```

3d. Directly after the arg loop's `done`, before `command -v gh >/dev/null`:

```bash
if [[ "$FIX_PERMS" == "true" ]]; then
  [[ -z "$TARGET_REF" ]] || usage_error "--fix-perms and --to are separate rollouts; run one at a time"
  USE_PR=true
  BRANCH="${BRANCH:-fix/agent-workflow-caller-permissions}"
fi
BRANCH="${BRANCH:-chore/migrate-agent-workflow}"
```

3e. Before `changed=0; skipped=0; failed=0`, add `missing_grants`, `put_stub` and `fix_perms_repo`:

```bash
# missing_grants — stub on stdin; prints the checker's gaps as the
# `scope=level,...` list rewrite_perms takes.
missing_grants() {
  bash "$SCRIPT_DIR/check-caller-permissions.sh" - "$REUSABLE" \
    | sed -E 's/^([^:]+): needs ([a-z]+),.*/\1=\2/' | paste -sd, - || true
}

# put_stub <repo> <sha> <content> <message> — write the stub; with --pr, on
# $BRANCH (created from the default branch's head if it does not exist yet).
put_stub() {
  local repo="$1" sha="$2" content="$3" msg="$4" base_sha
  local -a args=(-X PUT "repos/${repo}/contents/${STUB_PATH}"
        -f "message=${msg}"
        -f "content=$(printf '%s' "$content" | base64 -w0)"
        -f "sha=${sha}")
  if [[ "$USE_PR" == "true" ]]; then
    base_sha="$(gh api "repos/${repo}" --jq '.default_branch' \
                | xargs -I{} gh api "repos/${repo}/git/ref/heads/{}" --jq '.object.sha')"
    gh api -X POST "repos/${repo}/git/refs" -f "ref=refs/heads/${BRANCH}" \
           -f "sha=${base_sha}" >/dev/null 2>&1 || true
    args+=(-f "branch=${BRANCH}")
  fi
  gh api "${args[@]}" >/dev/null 2>&1
}

# fix_perms_repo <repo> <cur> <perms> <sha> <content> — the --fix-perms verdict
# and, with --apply, the PR for one repo. Updates the changed/skipped/failed
# counters.
fix_perms_repo() {
  local repo="$1" cur="$2" perms="$3" sha="$4" content="$5"
  local grants scopes new rc=0 open msg title url
  case "$perms" in
    perms:ok)    printf '%s  %s  perms ok\n' "$repo" "$cur"; skipped=$((skipped+1)); return ;;
    perms:ERROR) printf '%s  %s  perms:ERROR  not edited\n' "$repo" "$cur"; failed=$((failed+1)); return ;;
  esac
  scopes="${perms#perms:MISSING }"
  grants="$(printf '%s' "$content" | missing_grants)"
  new="$(printf '%s' "$content" | rewrite_perms "$grants" "$(basename "$REUSABLE")")" || rc=$?
  if (( rc != 0 )); then
    printf '%s  %s  cannot edit: %s\n' "$repo" "$cur" "$new"; failed=$((failed+1)); return
  fi
  # Belt and braces: the rewrite must satisfy the very checker that flagged it.
  if [[ "$(printf '%s\n' "$new" | perms_verdict)" != "perms:ok" ]]; then
    printf '%s  %s  cannot edit: rewrite did not close the gap\n' "$repo" "$cur"; failed=$((failed+1)); return
  fi
  open="$(gh pr list --repo "$repo" --head "$BRANCH" --state open --json url \
            --jq '.[0].url // empty' 2>/dev/null || printf '')"
  if [[ -n "$open" ]]; then
    printf '%s  %s  PR already open %s\n' "$repo" "$cur" "$open"; skipped=$((skipped+1)); return
  fi
  if [[ "$APPLY" != "true" ]]; then
    printf '%s  %s  would fix → %s  %s\n' "$repo" "$cur" "$scopes" "$perms"; changed=$((changed+1)); return
  fi
  title="fix(ci): grant ${grants//=/: } to the agent-workflow caller"
  title="${title//,/, }"
  msg="${title}"$'\n\n'"agent-implement.yml requests it, and a reusable workflow can't be granted more than its caller: every ai-implement dispatch ended in startup_failure with no logs. See https://github.com/freaxnx01/agent-workflow/issues/434."
  if ! put_stub "$repo" "$sha" "$new"$'\n' "$msg"; then
    printf '%s  %s  WRITE FAILED\n' "$repo" "$cur"; failed=$((failed+1)); return
  fi
  if ! url="$(gh pr create --repo "$repo" --head "$BRANCH" --title "$title" --body "$msg" 2>/dev/null)"; then
    printf '%s  %s  PR FAILED (branch %s written)\n' "$repo" "$cur" "$BRANCH"; failed=$((failed+1)); return
  fi
  printf '%s  %s  fixed → PR %s\n' "$repo" "$cur" "$url"; changed=$((changed+1))
}
```

3f. In migrate mode, replace the inline block from `  args=(-X PUT "repos/${repo}/contents/${STUB_PATH}"` through `  if gh api "${args[@]}" >/dev/null 2>&1; then` with the single line (the `msg=` line above it and the `gh pr create … || true` block below stay exactly as they are):

```bash
  if put_stub "$repo" "$sha" "$new" "$msg"; then
```

3g. In the repo loop, right after `  perms="$(printf '%s' "$content" | perms_verdict)"`:

```bash

  if [[ "$FIX_PERMS" == "true" ]]; then
    fix_perms_repo "$repo" "$cur" "$perms" "$sha" "$content"; continue
  fi
```

3h. After the final summary `printf`:

```bash
if [[ "$FIX_PERMS" == "true" ]] && (( failed > 0 )); then exit 1; fi
```

- [ ] **Step 4: Run them to verify they pass**

Run: `bash tests/run-script-tests.sh 2>&1 | sed -n '/fix-perms rollout/,/── /p'`
Expected: every line `✓` (20 assertions).

Run: `bash tests/run-script-tests.sh`
Expected: 0 failed — in particular both pre-existing `migrate-consumers` sections are unchanged and green (proves the `put_stub` extraction is behaviour-neutral).

Run: `shellcheck scripts/migrate-consumers.sh tests/run-script-tests.sh`
Expected: no output.

Run: `bash scripts/migrate-consumers.sh --help | grep -- '--fix-perms'`
Expected: the `--fix-perms` lines print (the help is no longer cut at line 50).

- [ ] **Step 5: Commit**

```bash
git add scripts/migrate-consumers.sh tests/run-script-tests.sh
git commit -m "feat(consumer): roll out missing caller permissions as one PR per repo (#441)"
```

---

### Task 3: Document the rollout

**Files:**
- Modify: `tests/run-script-tests.sh` — append after Task 2's section
- Modify: `docs/CONSUMER-SETUP.md` — after the `> **\`perms:MISSING <scope>\`** means …` blockquote (~:543-548), before `**Roll out a new line.**`

- [ ] **Step 1: Write the failing test**

```bash
assert_contains "$(cat "$ROOT/docs/CONSUMER-SETUP.md")" \
  'migrate-consumers.sh --owner <owner> --fix-perms --apply' \
  "CONSUMER-SETUP.md documents the --fix-perms rollout (#441)"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run-script-tests.sh 2>&1 | grep 'documents the --fix-perms'`
Expected: `✗ CONSUMER-SETUP.md documents the --fix-perms rollout (#441)`.

- [ ] **Step 3: Add the docs**

Insert after the `perms:MISSING` blockquote:

````markdown
**Fix a `perms:MISSING` fleet.** `--fix-perms` adds exactly the missing scopes
to each stub's caller `permissions:` block — the calling job's own block if it
has one, else the top-level one — and opens **one PR per repo** on
`fix/agent-workflow-caller-permissions`. Dry run first:

```bash
bash scripts/migrate-consumers.sh --owner <owner> --fix-perms            # dry run
bash scripts/migrate-consumers.sh --owner <owner> --fix-perms --apply    # one PR per repo
bash scripts/migrate-consumers.sh --owner <owner>                        # after merging: expect perms:ok
```

`perms:ok` repos are skipped. `perms:ERROR`, and shapes it will not edit
(flow-style `{ … }`, `read-all`/`write-all`, no block at all), are reported for
a hand edit and make the run exit 1. A repo whose fix PR is already open is
skipped, so a re-run is safe.
````

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/run-script-tests.sh 2>&1 | grep 'documents the --fix-perms'`
Expected: `✓ CONSUMER-SETUP.md documents the --fix-perms rollout (#441)`.

- [ ] **Step 5: Commit**

```bash
git add docs/CONSUMER-SETUP.md tests/run-script-tests.sh
git commit -m "docs(consumer): document the --fix-perms rollout (#441)"
```

---

### Task 4: Full verification

- [ ] **Step 1:** Run: `bash tests/run-all.sh` — Expected: `runners: 27   failed: 0` (prototype of all three tasks on 6c6ac39: `828/828` in `run-script-tests.sh`, all 27 runners green).
- [ ] **Step 2:** Run: `just lint-shell` (or `shellcheck scripts/migrate-consumers.sh tests/run-script-tests.sh` if `pre-commit` is unavailable) — Expected: clean.
- [ ] **Step 3:** ⛔ Do **not** run `--fix-perms` against any real repo, not even as a dry run, from the implementation run. The operator does that after merge (Task 3's commands).
