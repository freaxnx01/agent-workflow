# Autopilot Loads GH_TOKEN Through direnv — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The autopilot systemd unit gets `GH_TOKEN` by wrapping the driver in `direnv exec`, never from a PAT copy in `autopilot.env`. The driver refuses to start (exit 5, named error) when `GH_TOKEN` is missing or empty.

**Architecture:** One guard function in `scripts/autopilot.sh`, called in `main` after the run lock and the kill switch. One `ExecStart` rewrite plus comment changes in `setup/agent-autopilot.service`. Docs in `docs/AUTOPILOT.md` and `commands/autopilot.md`. Static Layer-1 checks pin the unit file and the docs.

**Tech Stack:** Bash 5 (`set -euo pipefail`), systemd user units, direnv, `gh` (mocked), Layer-1 tests in `tests/run-autopilot-driver-tests.sh`.

**Spec:** [`docs/superpowers/specs/2026-10-19-autopilot-gh-token-direnv-design.md`](../specs/2026-10-19-autopilot-gh-token-direnv-design.md)

## Global Constraints

- New exit code is exactly `5`, meaning "GH_TOKEN is not set". Codes `0`–`4` keep their meaning.
- Error text, verbatim: `error: GH_TOKEN is not set — start the driver under direnv: direnv exec <dir with the .envrc> scripts/autopilot.sh (see docs/AUTOPILOT.md, "Credentials")`.
- The check is `[[ -n "${GH_TOKEN:-}" ]]` only. Never consult `gh auth status`, `~/.config/gh/hosts.yml`, `GITHUB_TOKEN` or any other credential source. A fallback is the failure mode the operator rule forbids.
- Order in `main`: `parse_args` → `require_tools` → run lock → kill switch → **GH_TOKEN check** → config load. "already running" and "disabled" stay exit 0 without a token.
- `ExecStart` contains no `$` character and no `bash -c`. systemd expands `$VAR` in `ExecStart` before any shell sees it.
- `autopilot.env` still supplies `CLAUDE_CODE_OAUTH_TOKEN`. Nothing in this plan changes how that is supplied.
- Every script keeps `set -euo pipefail` + `IFS=$'\n\t'`; `shellcheck -x -e SC1091` stays clean.
- Never modify a test to make it green. Exporting a dummy `GH_TOKEN` at the top of the driver test file is a fixture change, required because the driver's contract now requires the variable. No existing assertion changes.

## Review Focus

- The guard must sit **after** the kill-switch check: `touch autopilot.disabled` must stop the lane even when credentials are broken. Pinned in Task 1 Step 1 ("no token + disabled → exit 0").
- No credential fallback anywhere in the diff (grep the diff for `hosts.yml`, `auth status`, `GITHUB_TOKEN`).
- `ExecStart` has no `$`. Pinned in Task 2 Step 1.

## Files overlapping other plans in this batch

- `scripts/autopilot.sh`: also changed by **#550** (passes the per-repo `[low]` policy to the nested enrich, in `process_issue` and its header). Different functions, but a textual merge conflict in the header `Env:` / exit-code block is possible.
- `tests/run-autopilot-driver-tests.sh`: also changed by **#550** (new sections appended).
- `docs/AUTOPILOT.md`: also changed by **#549** (the "And per issue" line, ~line 71) and **#550** (config section and reading-the-log notes).
- Recommended order: dispatch #509 first, then #550 after #509 merges. #549's only shared file is `docs/AUTOPILOT.md`, in a different section, so it can run in parallel with #509.

---

### Task 1: The driver refuses to run without GH_TOKEN

**Files:**
- Modify: `scripts/autopilot.sh` (header `Env:` lines 22-28 and `Exit codes:` lines 30-39; new function after `require_tools`, ~line 107; `main`, lines 309-318)
- Test: `tests/run-autopilot-driver-tests.sh` (top-of-file env block ~line 47-50; new section after `section "the disable flag"` block, ~line 87)

**Interfaces:**
- Produces: `require_gh_token` (a function in `scripts/autopilot.sh`): returns normally when `GH_TOKEN` is non-empty, otherwise calls `die "<message>" 5`.

- [ ] **Step 1: Write the failing tests**

In `tests/run-autopilot-driver-tests.sh`, in the env block after `export AUTOPILOT_DISABLE_FLAG="$TMPDIR_T/disabled"` (line 50), add:

```bash
# The driver refuses to run without GH_TOKEN (#509). A dummy is enough: gh is
# mocked, and the guard checks presence, never validity.
export GH_TOKEN=test-token-not-real
```

Then, directly after the `section "the disable flag"` block (after its `rm -f "$AUTOPILOT_DISABLE_FLAG"`), add:

```bash
section "GH_TOKEN comes from direnv, never a fallback (#509)"

: > "$GH_MOCK_LOG"
rc=0; out="$(env -u GH_TOKEN "$DRIVER" --config "$TMPDIR_T/ap.conf" 2>&1)" || rc=$?
assert_eq "no GH_TOKEN exits 5" "5" "$rc"
case "$out" in
  *"GH_TOKEN is not set"*"direnv exec"*) pass "the error names GH_TOKEN and direnv" ;;
  *) fail "the error names GH_TOKEN and direnv" "output was: $out" ;;
esac
assert_eq "no GH_TOKEN makes no gh calls at all" "" "$(cat "$GH_MOCK_LOG")"

rc=0; GH_TOKEN='' "$DRIVER" --config "$TMPDIR_T/ap.conf" >/dev/null 2>&1 || rc=$?
assert_eq "an empty GH_TOKEN (passbolt unreachable) exits 5" "5" "$rc"

rc=0; env -u GH_TOKEN "$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "a dry run without GH_TOKEN exits 5 too" "5" "$rc"

: > "$AUTOPILOT_DISABLE_FLAG"
rc=0; out="$(env -u GH_TOKEN "$DRIVER" --config "$TMPDIR_T/ap.conf" 2>&1)" || rc=$?
assert_eq "the kill switch still works without GH_TOKEN (exit 0)" "0" "$rc"
case "$out" in
  *disabled*) pass "the kill switch is logged even without GH_TOKEN" ;;
  *) fail "the kill switch is logged even without GH_TOKEN" "output was: $out" ;;
esac
rm -f "$AUTOPILOT_DISABLE_FLAG"

# A stored gh login must not stand in for the direnv PAT: with GH_TOKEN unset
# the driver refuses even though `gh` (the mock) would answer every call.
rc=0; env -u GH_TOKEN GH_MOCK_AUTH_HOSTS=github.com "$DRIVER" --config "$TMPDIR_T/ap.conf" >/dev/null 2>&1 || rc=$?
assert_eq "an ambient gh login is not a fallback for GH_TOKEN" "5" "$rc"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-autopilot-driver-tests.sh 2>&1 | grep -E '✗|passed:'`
Expected: FAIL on `no GH_TOKEN exits 5`, `the error names GH_TOKEN and direnv`, `no GH_TOKEN makes no gh calls at all`, `an empty GH_TOKEN … exits 5`, `a dry run without GH_TOKEN exits 5 too`, `an ambient gh login is not a fallback for GH_TOKEN`. The two kill-switch assertions already pass.

- [ ] **Step 3: Implement**

In `scripts/autopilot.sh`, add to the header `Env:` block (after the `MODEL` line, line 28):

```bash
#   GH_TOKEN                required. The direnv-exported PAT — run the driver
#                           under `direnv exec <dir with the .envrc>`; it is
#                           never read from a file or a stored gh login (#509)
```

and to the `Exit codes:` block, after the `4  config invalid or unreadable` line:

```bash
#   5  GH_TOKEN is not set (or empty) — launched without direnv, the .envrc is
#      not allowed, or Passbolt was unreachable (#509)
```

Add this function directly after `require_tools` (after line 107):

```bash
# GitHub auth for the lane is the direnv-exported PAT and nothing else (#509).
# Checks the variable only: a stored `gh` login must not stand in for it, which
# is the silent fallback that once hid an expired PAT for days. Presence only —
# the first gh call finds out whether the token is valid.
require_gh_token() {
  [[ -n "${GH_TOKEN:-}" ]] && return 0
  die 'GH_TOKEN is not set — start the driver under direnv: direnv exec <dir with the .envrc> scripts/autopilot.sh (see docs/AUTOPILOT.md, "Credentials")' 5
}
```

In `main`, between the kill-switch block and the config load:

```bash
  if [[ -e "$DISABLE_FLAG" ]]; then
    log "disabled: $DISABLE_FLAG present"
    exit 0
  fi

  require_gh_token

  if [[ -n "$CONFIG_FILE" ]]; then
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run-autopilot-driver-tests.sh 2>&1 | tail -4`
Expected: `failed: 0`.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/autopilot.sh tests/run-autopilot-driver-tests.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/autopilot.sh tests/run-autopilot-driver-tests.sh
git commit -m "fix(autopilot): refuse to run without the direnv GH_TOKEN (#509)"
```

---

### Task 2: The unit wraps the driver in `direnv exec`

**Files:**
- Modify: `setup/agent-autopilot.service` (install comment lines 6-11; `[Service]` lines 24-32)
- Test: `tests/run-autopilot-driver-tests.sh` (new section before the final summary block)

- [ ] **Step 1: Write the failing tests**

In `tests/run-autopilot-driver-tests.sh`, directly before the final `printf '\n%s──────────%s\n'` summary block, add:

```bash
section "the unit loads GH_TOKEN through direnv (#509)"

UNIT="$ROOT/setup/agent-autopilot.service"
exec_start="$(grep -E '^ExecStart=' "$UNIT")"
case "$exec_start" in
  *"direnv exec "*"scripts/autopilot.sh"*) pass "ExecStart runs the driver under direnv exec" ;;
  *) fail "ExecStart runs the driver under direnv exec" "was: $exec_start" ;;
esac
case "$exec_start" in
  *'$'*) fail "ExecStart has no \$ (systemd would expand it)" "was: $exec_start" ;;
  *) pass "ExecStart has no \$ (systemd would expand it)" ;;
esac
case "$exec_start" in
  *"bash -c"*) fail "ExecStart needs no shell" "was: $exec_start" ;;
  *) pass "ExecStart needs no shell" ;;
esac
if grep -qE '^#.*GH_TOKEN=' "$UNIT"; then
  fail "the unit no longer tells you to copy GH_TOKEN into autopilot.env" "$(grep -nE 'GH_TOKEN=' "$UNIT")"
else
  pass "the unit no longer tells you to copy GH_TOKEN into autopilot.env"
fi
if grep -q 'direnv allow' "$UNIT"; then
  pass "the unit documents the direnv allow prerequisite"
else
  fail "the unit documents the direnv allow prerequisite"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-autopilot-driver-tests.sh 2>&1 | grep -E '✗|passed:'`
Expected: FAIL on `ExecStart runs the driver under direnv exec`, `the unit no longer tells you to copy GH_TOKEN…`, `the unit documents the direnv allow prerequisite`.

- [ ] **Step 3: Implement**

In `setup/agent-autopilot.service`, replace the install comment

```ini
#   $EDITOR ~/.config/systemd/user/agent-autopilot.service   # fix the two paths
```

with

```ini
#   $EDITOR ~/.config/systemd/user/agent-autopilot.service   # fix the paths
#   direnv allow ~/repos/github/freaxnx01/public              # once, as this user
```

and replace everything from `# A --user unit inherits NOTHING` through the `ExecStart=` line with:

```ini
# A --user unit inherits NOTHING from an interactive shell.
#
# CLAUDE_CODE_OAUTH_TOKEN comes from this file. Keep it 0600:
#   CLAUDE_CODE_OAUTH_TOKEN=…
# GH_TOKEN does NOT go in here (#509). GitHub auth is only the PAT that direnv
# exports from Passbolt; a second copy drifts, outlives a rotation and hides an
# expiry. ExecStart below runs the driver under `direnv exec`, which loads it.
EnvironmentFile=%h/.config/agent-workflow/autopilot.env

# Absolute path to this clone of agent-workflow. Edit after copying.
WorkingDirectory=%h/repos/github/freaxnx01/public/agent-workflow

# Three paths to edit after copying: direnv itself (`command -v direnv`), the
# directory whose .envrc exports GH_TOKEN, and the driver in this clone. That
# .envrc must be `direnv allow`ed by this user, or GH_TOKEN stays unset and the
# driver exits 5 on its first line.
#
# No `bash -c '…'` and no `$` here: systemd expands $VAR in ExecStart itself,
# before any shell sees it.
ExecStart=/usr/bin/direnv exec %h/repos/github/freaxnx01/public %h/repos/github/freaxnx01/public/agent-workflow/scripts/autopilot.sh
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run-autopilot-driver-tests.sh 2>&1 | tail -4`
Expected: `failed: 0`.

- [ ] **Step 5: Verify the unit parses (if systemd is available)**

Run: `command -v systemd-analyze >/dev/null && systemd-analyze --user verify setup/agent-autopilot.service 2>&1 | grep -v 'agent-autopilot.timer' || true`
Expected: no error about `ExecStart` (a warning that the paths do not exist on a host without the clone is acceptable).

- [ ] **Step 6: Commit**

```bash
git add setup/agent-autopilot.service tests/run-autopilot-driver-tests.sh
git commit -m "fix(autopilot): load GH_TOKEN through direnv exec in the unit (#509)"
```

---

### Task 3: Operator docs

**Files:**
- Modify: `docs/AUTOPILOT.md` (Setup steps 2-4, lines 78-84; exit-code table lines 137-143; "When something is wedged", after line 168)
- Modify: `commands/autopilot.md` (`## Exit codes` list)
- Test: `tests/run-autopilot-driver-tests.sh` (extend the Task 2 section)

- [ ] **Step 1: Write the failing tests**

Append to the `section "the unit loads GH_TOKEN through direnv (#509)"` block added in Task 2:

```bash
DOC="$ROOT/docs/AUTOPILOT.md"
creds="$(awk '/\*\*Credentials\.\*\*/{on=1} on{print} on && /^3\. /{exit}' "$DOC")"
case "$creds" in
  *'GH_TOKEN='*) fail "AUTOPILOT.md no longer says to put GH_TOKEN= in autopilot.env" "$creds" ;;
  *) pass "AUTOPILOT.md no longer says to put GH_TOKEN= in autopilot.env" ;;
esac
case "$creds" in
  *'direnv exec'*) pass "AUTOPILOT.md's credentials step names direnv exec" ;;
  *) fail "AUTOPILOT.md's credentials step names direnv exec" "$creds" ;;
esac
if grep -qE '^\| `5` \|' "$DOC"; then
  pass "AUTOPILOT.md documents exit code 5"
else
  fail "AUTOPILOT.md documents exit code 5"
fi
if grep -qE '^- `5`' "$ROOT/commands/autopilot.md"; then
  pass "/autopilot documents exit code 5"
else
  fail "/autopilot documents exit code 5"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-autopilot-driver-tests.sh 2>&1 | grep -E '✗|passed:'`
Expected: FAIL on all four new doc assertions.

- [ ] **Step 3: Implement**

In `docs/AUTOPILOT.md`, replace Setup steps 2–4 with:

```markdown
2. **Credentials.** Two tokens, from two places:
   - `CLAUDE_CODE_OAUTH_TOKEN` goes in `~/.config/agent-workflow/autopilot.env`,
     mode `0600`. A `--user` unit inherits nothing from a shell, so this file
     is not optional.
   - `GH_TOKEN` does **not** go in that file. GitHub auth is only the PAT that
     direnv exports from Passbolt (the operator's
     `~/repos/github/freaxnx01/public/.envrc`); a second copy drifts, outlives
     a rotation and hides an expiry (#509). Every launch runs under
     `direnv exec <dir with the .envrc>`, the unit included. Run
     `direnv allow <dir>` once as the user that runs the lane. If an older
     setup put a `GH_TOKEN` line in `autopilot.env`, delete it.

   The driver refuses to start without `GH_TOKEN` (exit `5`). It never falls
   back to a stored `gh` login. Verified 2026-10-19: `passbolt get` works from
   a `--user` unit with no login session, because go-passbolt-cli keeps its
   key and passphrase in its own config (no GPG agent), and the user has
   linger enabled.
3. **Dry run.** `direnv exec ~/repos/github/freaxnx01/public scripts/autopilot.sh --dry-run`.
   Nothing is written. Read every line before going further.
4. **One real issue.** `direnv exec ~/repos/github/freaxnx01/public scripts/autopilot.sh --max 1`
   against the sandbox.
```

In the exit-code table, after the `| \`4\` | …` row, add:

```markdown
| `5` | `GH_TOKEN` is not set or empty — launched without `direnv exec`, the `.envrc` is not `direnv allow`ed, or Passbolt was unreachable (the `.envrc` discards passbolt's errors, so an outage arrives as an empty token). Nothing was read or written |
```

In "When something is wedged", add as the last bullet:

```markdown
- **Every run exits `5` (`GH_TOKEN is not set`).** Run
  `direnv exec ~/repos/github/freaxnx01/public sh -c 'test -n "$GH_TOKEN" && echo ok'`
  as the lane's user. No `ok`: either the `.envrc` is blocked (`direnv allow`
  it) or Passbolt did not answer (`passbolt get resource --id …` by hand shows
  the real error). Do not work around it by copying the PAT into
  `autopilot.env`.
```

In `commands/autopilot.md`, in `## Exit codes`, after the `4` line add:

```markdown
- `5` — `GH_TOKEN` is not set. Start the session (or the driver) under
  `direnv exec` for the directory whose `.envrc` exports it; the driver never
  falls back to a stored `gh` login
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run-autopilot-driver-tests.sh 2>&1 | tail -4`
Expected: `failed: 0`.

- [ ] **Step 5: Run the whole suite and lint**

Run: `bash tests/run-all.sh 2>&1 | tail -5 && shellcheck -x -e SC1091 scripts/autopilot.sh tests/run-autopilot-driver-tests.sh`
Expected: all runners pass; shellcheck prints nothing.

- [ ] **Step 6: Commit**

```bash
git add docs/AUTOPILOT.md commands/autopilot.md tests/run-autopilot-driver-tests.sh
git commit -m "docs(autopilot): GH_TOKEN comes from direnv, never autopilot.env (#509)"
```
