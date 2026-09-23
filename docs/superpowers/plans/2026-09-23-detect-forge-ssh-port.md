# `_forge_url_path` ssh-port fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `_forge_url_path` parse a remote by its shape so an `ssh://` URL carrying an explicit port resolves correctly instead of silently shifting every field.

**Architecture:** Replace the single `sed` pipeline with a `case` on whether the remote has a URL scheme. In the URL form the path starts at the first `/` after the authority, so userinfo and `:port` fall away together. In scp-style form there is no scheme and git supports no port, so the first `:` is always the path separator. Pure bash parameter expansion, no `sed`.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), Layer-1 fixture tests via `tests/run-detect-forge-tests.sh`, `shellcheck -x`.

**Spec:** `docs/superpowers/specs/2026-09-23-detect-forge-ssh-port-design.md`

## Global Constraints

- Bash scripts start with `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'` — already present in both files; do not remove.
- Quote every variable expansion. `[[ ... ]]` over `[ ... ]`. No `eval`.
- `scripts/lib/detect-forge.sh` is **sourced, not executed** — it must define functions and have no side effects at source time.
- Tests are Layer-1: no network, no `gh`/`tea`/`az`, run in under 5 seconds. `tests/run-all.sh` discovers `run-*-tests.sh` with `find`, so no registration step exists or is needed.
- `shellcheck -x -e SC1091` must stay clean. New suppressions need a reason comment.
- `_forge_host` is **out of scope** — it already ends the host at the first `:` or `/`, which is correct for both shapes.
- Do not add IPv6 bracket-literal support (`ssh://git@[::1]:22/…`); explicitly out of scope per the spec.

---

### Task 1: Parse by remote shape so an explicit port stops shifting the fields

**Files:**
- Modify: `scripts/lib/detect-forge.sh:27-31` (the `_forge_url_path` function)
- Test: `tests/run-detect-forge-tests.sh` (append cases to the `azure devops — context resolution` section, after the existing `ssh:// v3 form` case at ~line 159)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `_forge_url_path <url>` — unchanged signature, echoes the path after the hostname with no leading slash. `resolve_azdo_context` and `detect_forge` continue to call it as they do today; no caller changes.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-detect-forge-tests.sh`, immediately after the existing `ssh:// v3 form` block (the one asserting `contoso|MyProject|my-repo`):

```bash
# An ssh:// remote may carry an explicit port. The port must not be mistaken for
# a path segment — doing so shifts org/project/repo each by one. See #387.
REPO="$(make_repo "ssh://git@ssh.dev.azure.com:22/v3/contoso/MyProject/my-repo")"
assert_eq "ssh:// with explicit port 22" "contoso|MyProject|my-repo" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

REPO="$(make_repo "ssh://git@ssh.dev.azure.com:7999/v3/contoso/MyProject/my-repo")"
assert_eq "ssh:// with non-standard port" "contoso|MyProject|my-repo" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"

# No userinfo, with a port — the authority is host:port alone.
REPO="$(make_repo "ssh://ssh.dev.azure.com:22/v3/contoso/MyProject/my-repo")"
assert_eq "ssh:// port, no userinfo" "contoso|MyProject|my-repo" \
  "$(run_resolve_azdo "$REPO")"
rm -rf "$REPO"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run-detect-forge-tests.sh`

Expected: FAIL on all three new cases, each reporting a shifted result, e.g.
`expected: contoso|MyProject|my-repo | actual: 22|v3|my-repo`. Every pre-existing
case still passes — if any of those broke, stop: the test file was edited in the
wrong place.

- [ ] **Step 3: Replace `_forge_url_path` with the shape-aware form**

In `scripts/lib/detect-forge.sh`, replace the whole `_forge_url_path` function —
comment block included — with:

```bash
# _forge_url_path <url>  echoes everything after the hostname, no leading slash.
#
# The two remote shapes give `:` opposite meanings, so they are parsed apart:
#   URL form   scheme://[user@]host[:port]/path   `:` separates a PORT
#   scp-style  [user@]host:path                   `:` separates the PATH
# git supports no port in scp-style syntax, which is what makes them separable.
_forge_url_path() {
  local url=$1
  case "$url" in
    [a-zA-Z]*://*)
      # The path begins at the first `/` after the authority, so userinfo and
      # any `:port` fall away with it — neither needs its own step.
      url=${url#*://}
      printf '%s' "${url#*/}"
      ;;
    *)
      # Strip userinfo only when the `@` precedes the `:`; an `@` after it
      # belongs to the path, not to a user.
      if [[ "${url%%:*}" == *@* ]]; then url=${url#*@}; fi
      printf '%s' "${url#*:}"
      ;;
  esac
}
```

Note for the reviewer: the existing `ssh://git@ssh.dev.azure.com:v3/…` case now
resolves by a **different route** — `v3` is consumed as part of the authority
rather than stripped by `resolve_azdo_context`'s `${path#v3/}`, which then
no-ops. The result is unchanged; the intermediate value is not.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `tests/run-detect-forge-tests.sh`

Expected: PASS — all three new cases green and **every** pre-existing case still
green, in particular `ssh:// v3 form`, `scp-style v3 form (no _git segment)`,
`percent-encoded space in project name`, and both `visualstudio.com` cases.

- [ ] **Step 5: Verify shellcheck is clean**

Run: `shellcheck -x -e SC1091 scripts/lib/detect-forge.sh tests/run-detect-forge-tests.sh`

Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/detect-forge.sh tests/run-detect-forge-tests.sh
git commit -m "fix(detect-forge): parse remotes by shape so an ssh port is not a path segment

_forge_url_path ended the host at the first : or /, so ssh://host:22/v3/... kept
the port as the first path segment and org/project/repo each shifted by one.
_forge_host uses a different expression and was unaffected, so detect_forge still
reported azdo and the failure was silent.

Parse by shape instead: in a URL the path starts at the first / after the
authority, so userinfo and :port fall away together; in scp-style form git
supports no port, so the first : is always the path separator.

Closes #387"
```

---

### Task 2: Cover the shared-helper blast radius beyond Azure DevOps

`_forge_url_path` serves all three forges, so the same expression broke Forgejo
remotes on a non-standard SSH port. Task 1 fixes that too; this task proves it and
pins it, and labels the `:v3` case that Task 1's change routes differently.

These assertions **pass as soon as Task 1 lands** — they are regression tests, not
red-green. Step 2 verifies they would have failed beforehand, which is what makes
them meaningful.

**Files:**
- Modify: `tests/run-detect-forge-tests.sh` (add a `run_url_path` helper beside `run_resolve_azdo` at ~line 67, and a new section at the end of the cases)

**Interfaces:**
- Consumes: `_forge_url_path` as rewritten in Task 1.
- Produces: `run_url_path <repo-dir>` — echoes `_forge_url_path`'s result for that repo's `origin`. Test-harness only; nothing outside the test file uses it.

- [ ] **Step 1: Add the `run_url_path` helper**

`run_resolve_azdo` returns early for non-ADO hosts, so it cannot exercise a
Forgejo remote. Add a direct helper immediately after `run_resolve_azdo` in
`tests/run-detect-forge-tests.sh`:

```bash
# run_url_path <repo-dir> — echoes _forge_url_path's result for that repo's
# origin. resolve_azdo_context bails on non-ADO hosts, so this is the only way
# to assert the shared path parser against a GitHub or Forgejo remote.
run_url_path() {
  local dir="$1"
  (
    cd "$dir"
    # shellcheck disable=SC1090
    source "$LIB"
    _forge_url_path "$(git remote get-url origin)"
    printf '\n'
  )
}
```

- [ ] **Step 2: Add the blast-radius cases**

Append a new section at the end of the cases block, before the `--- summary ---`
divider:

```bash
section "shared path parser (_forge_url_path)"

# The same expression that broke ADO broke any forge on a non-standard SSH port.
REPO="$(make_repo "ssh://git@git.home.freaxnx01.ch:2222/freax/hello-forgejo")"
assert_eq "forgejo ssh:// with explicit port" "freax/hello-forgejo" \
  "$(run_url_path "$REPO")"
rm -rf "$REPO"

REPO="$(make_repo "ssh://git@github.com:2222/freaxnx01/agent-workflow")"
assert_eq "github ssh:// with explicit port" "freaxnx01/agent-workflow" \
  "$(run_url_path "$REPO")"
rm -rf "$REPO"

# scp-style has no port: the `:` is the path separator and must stay one.
REPO="$(make_repo "git@github.com:freaxnx01/agent-workflow")"
assert_eq "scp-style colon is the path separator" "freaxnx01/agent-workflow" \
  "$(run_url_path "$REPO")"
rm -rf "$REPO"

# Load-bearing: ssh:// carrying the scp-style `:v3` with NO port. After #387 the
# `v3` is consumed as part of the authority rather than by resolve_azdo_context's
# ${path#v3/} strip. Same result, different route — do not "simplify" either side
# without re-running this.
REPO="$(make_repo "ssh://git@ssh.dev.azure.com:v3/contoso/MyProject/my-repo")"
assert_eq "ssh:// :v3 with no port still resolves" "contoso/MyProject/my-repo" \
  "$(run_url_path "$REPO")"
rm -rf "$REPO"
```

- [ ] **Step 3: Confirm these cases would have failed before Task 1**

The assertions above pass against the fixed parser, so prove they have teeth by
temporarily removing the fix. From the repo root:

```bash
git stash push -- scripts/lib/detect-forge.sh
tests/run-detect-forge-tests.sh; echo "exit=$?"
git stash pop
```

Expected: with Task 1's fix stashed, the run **fails**, naming at least
`forgejo ssh:// with explicit port` and `github ssh:// with explicit port`.

If it passes with the fix stashed, the new assertions are not exercising the bug —
stop and fix them before continuing. A regression test that cannot fail is worse
than none, because it reads as coverage.

Confirm `git stash pop` restored the fix before moving on:

```bash
grep -q 'shapes give `:` opposite meanings' scripts/lib/detect-forge.sh && echo "fix restored"
```

- [ ] **Step 4: Run the full suite**

Run: `tests/run-detect-forge-tests.sh`

Expected: PASS — every case green, new and old.

- [ ] **Step 5: Run the whole Layer-1 suite and shellcheck**

Run:

```bash
tests/run-all.sh
shellcheck -x -e SC1091 tests/run-detect-forge-tests.sh
```

Expected: both exit 0. `run-all.sh` discovers this file by `find`, so it needs no
registration — if it is not listed in the output, that is a discovery problem
worth reporting, not something to fix by hand-adding it.

- [ ] **Step 6: Commit**

```bash
git add tests/run-detect-forge-tests.sh
git commit -m "test(detect-forge): pin the shared path parser across forges

_forge_url_path serves all three forges, so the ssh-port bug was never
ADO-specific. Add a run_url_path helper — resolve_azdo_context bails on non-ADO
hosts and cannot reach these — and cover Forgejo and GitHub remotes on an
explicit port, the scp-style colon, and the ssh:// :v3 form whose resolution
route changed even though its result did not.

Refs #387"
```

---

## Verification

After both tasks:

```bash
tests/run-all.sh
shellcheck -x -e SC1091 scripts/lib/detect-forge.sh tests/run-detect-forge-tests.sh
```

Both exit 0, and `run-detect-forge-tests.sh` reports the pre-existing cases plus
seven new ones, none failing.

Do **not** consider this done on a green run alone: confirm by reading the output
that `ssh:// v3 form` and `scp-style v3 form (no _git segment)` are among the
passing cases. They are the two the rewrite is most likely to have broken, and a
suite that skipped them would still print green.
