# Take opencode off the shared npm prefix

**Issue:** [#395](https://github.com/freaxnx01/agent-workflow/issues/395)
**Follows:** [#302](https://github.com/freaxnx01/agent-workflow/issues/302), which fixed the same hazard on the claude path
**Date:** 2026-09-23
**Status:** Approved

## Problem

`scripts/ensure-toolchain.sh` (`ensure_opencode`) installs with:

```bash
npm install -g "opencode-ai@${OPENCODE_VERSION}"
```

`npm install -g` resolves to `npm config get prefix` — `/usr/local` on a typical
runner — which on a **persistent** self-hosted runner is shared across every job
and every run. Once that prefix has been written as root, a later install as the
runner user cannot rename the existing package directory and dies with
`EACCES / syscall rename`. Deterministic, not intermittent.

This is the identical failure #302 documented and fixed for the Claude CLI. That
fix moved the claude path to a checksum-pinned native installer, leaving
`ensure_opencode` as the **only** remaining npm consumer in the pipeline — and
the only path still exposed.

## Decisions

| # | Decision | Rejected alternative |
|---|---|---|
| D1 | Install via opencode's native installer, checksum-pinned | A job-local `npm --prefix` — the mitigation #302 concluded was the wrong shape, and it keeps Node.js a runner requirement; or a writability preflight, which reports the hazard without removing it |
| D2 | Extract the shared fetch-and-verify logic to `scripts/lib/` | Duplicating ~25 lines in both installers. Two instances is where this repo's own rule says the pattern is clear, and checksum verification is the security-critical part — a bug there should be fixable once |
| D3 | `ensure_opencode` keeps orchestrating and delegates only the install | Calling the installer from a workflow step like the claude path. More symmetric, but it moves the `AGENT` gate into YAML, touches more of the workflow, and rehomes working tests for no functional gain |

## Design

### Component 1 — `scripts/lib/fetch-verified-installer.sh` (new, sourced)

Everything identical between the two installers, and everything
security-critical:

```
require_tool <name>
    command -v; on absence prints the tool and docs/RUNNER-REQUIREMENTS.md,
    then exits 64.

fetch_verified_installer <url> <expected_sha256>
    mktemp -d with a trap, curl -fsSL, sha256sum, compare.
    On match: echoes the path to the verified script.
    On mismatch: prints expected vs actual and exits 65 WITHOUT executing.
```

The caller executes the returned path. The helper never runs the installer
itself — fetching and running stay separate so the refusal path is
unmistakable.

Two details the implementation must honour, both easy to get wrong:

- **It publishes `exit-code` to `$GITHUB_OUTPUT` before any non-zero exit**,
  exactly as `install-claude-cli.sh`'s `die()` does today. The workflow's
  failure-path step reads `steps.install_cli.outputs.exit-code` to pick the
  right reason in `post-runner-block.sh`. A helper that exited directly would
  bypass that and silently regress #302/#384 — the claude suite's
  `exit-code=64` assertion is what catches it.
- **Progress output goes to stderr.** `fetch_verified_installer` returns the
  path on stdout, so anything else printed there would be captured by the
  caller's `$(...)` and corrupt the path.

Because it is sourced, `exit` inside the helper terminates the calling
installer — which is the intent: a failed fetch is terminal for both.

### Component 2 — `scripts/install-opencode.sh` (new)

```
Optional env: OPENCODE_VERSION (default 1.15.13, matching ensure-toolchain.sh),
              INSTALLER_URL (default https://opencode.ai/install),
              INSTALLER_SHA256 (fc3c1b21…f297e, captured 2026-09-23),
              DRY_RUN, GITHUB_PATH, GITHUB_OUTPUT

Exit: 0 installed | 64 prerequisite absent | 65 checksum mismatch
      | 66 installer ran but no opencode binary found
```

Runs `bash <verified> --version "$OPENCODE_VERSION"` — the installer's
documented pinning flag — and puts `$HOME/.opencode/bin` on `$GITHUB_PATH`.
That directory is per-user and per-runner, never a shared prefix, which is the
whole point.

### Component 3 — `scripts/install-claude-cli.sh` refactored

Sources the helper instead of carrying its own copy. **Its external contract is
unchanged**: same env vars, same exit codes `0/64/65/66`, same messages. Its 19
existing tests must pass unmodified — that is the regression guard on this
refactor, and they are not to be adjusted to accommodate it.

### Component 4 — `ensure_opencode` delegates

The `AGENT=opencode` gate, the already-at-pinned-version skip, the
`OPENCODE_DRY_RUN` seam and the post-install `command -v` check all stay.
Only the install call changes:

```bash
-  if command -v npm >/dev/null 2>&1; then
-    npm install -g "opencode-ai@${OPENCODE_VERSION}"
-  else
-    printf 'error: npm not available; cannot install opencode\n' >&2
-    return 1
-  fi
+  OPENCODE_VERSION="$OPENCODE_VERSION" bash "$HERE/install-opencode.sh"
```

`OPENCODE_VERSION` remains declared in exactly one place, at the top of
`ensure-toolchain.sh`, and is passed down. The installer's own default exists
only so it can be run standalone.

### Component 5 — npm leaves the pipeline

With opencode moved, no pipeline path uses npm. Therefore in
`docs/RUNNER-REQUIREMENTS.md`:

- `nodejs` is **removed** from the Ansible package list.
- The promise *"If `npm` is not on the runner… fails with a clear error"* is
  **deleted**, not narrowed again. #302 narrowed it to the opencode path
  because that was the last npm consumer; there is now no such path, so a
  narrowed promise would describe nothing.
- The `AGENT=opencode` row names the native installer and its `curl` +
  `sha256sum` prerequisites — the same two the claude path already requires,
  so the toolchain contract becomes one list for both agents.

## Testing

**Layer 0** — `shellcheck -x` over `scripts/`, `scripts/lib/` and `tests/`.

**Layer 1**

`tests/run-fetch-verified-installer-tests.sh` (new) — the helper alone:

| Case | Asserts |
|---|---|
| both tools present | returns a path whose contents match the payload |
| `curl` absent | exit 64, names `curl` and the doc |
| `sha256sum` absent | exit 64, names `sha256sum` |
| checksum matches | path echoed, file readable |
| checksum mismatches | exit 65, and the caller never receives a path |

`tests/run-install-opencode-tests.sh` (new) — mirrors the claude suite's
structure: a PATH built from symlinks to exactly the tools a case should see, so
a missing tool is a real absence; a `curl` stand-in writing a payload that the
**real** `sha256sum` hashes; `DRY_RUN` performing guards only.

**Regression guards, which must pass unmodified:**

- the 19 cases in `tests/run-install-claude-cli-tests.sh` — the proof that
  Component 3's refactor changed no behaviour
- the `ensure-toolchain` dry-run cases at `tests/run-script-tests.sh:2922-2954`

**New guard:** no `npm install` of any shape survives under `scripts/`.

## Acceptance criteria

- [ ] `ensure_opencode` no longer writes to the shared npm global prefix
- [ ] `opencode` is on PATH at the pinned `OPENCODE_VERSION` after a fresh install
- [ ] The opencode installer is checksum-verified before execution and refuses
      to execute on mismatch
- [ ] `scripts/install-claude-cli.sh` and `scripts/install-opencode.sh` share
      one fetch-and-verify implementation
- [ ] `install-claude-cli.sh`'s existing 19 tests pass **unmodified**
- [ ] No `npm install` remains anywhere under `scripts/`
- [ ] `docs/RUNNER-REQUIREMENTS.md` no longer requires Node.js, and its
      npm-missing promise is deleted rather than narrowed
- [ ] `shellcheck -x` clean; full Layer-1 suite green in <5s

## Out of scope

- Whether opencode is worth keeping as a second agent. A strategy question, not
  this fix.
- The `AGENT=opencode` gate moving into the workflow (D3).
