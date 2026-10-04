# Unify the Claude Code CLI install across pipeline jobs

**Issue:** [#302](https://github.com/freaxnx01/agent-workflow/issues/302)
**Folds in:** [#384](https://github.com/freaxnx01/agent-workflow/issues/384) (remaining AC)
**Date:** 2026-09-22
**Status:** Approved

## Problem

`agent-implement.yml` acquires the Claude Code CLI **two different ways**:

| Job | Mechanism | Line |
|---|---|---|
| `implement` | `anthropics/claude-code-base-action` (installs the CLI itself) | `:665` |
| `ai_review_human_merge` | `npm install --prefix "$RUNNER_TEMP/claude-cli"` | `:1108` |
| `ai_review_ai_merge` (self-fix) | `npm install --prefix "$RUNNER_TEMP/claude-cli"` | `:1431` |

One dependency, two mechanisms. The npm path has produced two distinct live failures:

- **#302** — `npm install -g` into the shared `/usr/local` prefix died with
  `EACCES / syscall rename` on a persistent self-hosted runner whose prefix had
  once been written as root. Deterministic, not intermittent: the implement job
  never hit it because the base action never touches the shared prefix.
  *Already mitigated* by moving to a job-local `--prefix`, but npm remains.
- **#384** — a runner with no Node.js at all fails the same steps with a bare
  `npm: command not found`, exit 127, ~40 lines into a log whose failing step is
  named only `UNKNOWN STEP`.

Both are symptoms of the same shape: the review path installs a dependency through
a toolchain the implement path does not require.

### The silent-failure gap

`agent-implement.yml:1282` ("Mark issue blocked when review or envelope refuses")
carries no `if:` override, so it inherits GitHub's default `success()`. When an
install step fails, the job aborts and **nothing is posted on the issue**. A
reasoned refusal gets a comment plus `ai:review-blocked`; a toolchain crash gets
silence. From the issue, the two are indistinguishable — which is #384's AC2.

## Decisions

| # | Decision | Rejected alternative |
|---|---|---|
| D1 | Review/self-fix install via the **native installer**, no npm | Reusing `claude-code-base-action` as an installer — its contract is to *run* an agent, not install one |
| D2 | Installer is fetched by a repo script that **verifies a pinned SHA-256** before executing | Vendoring upstream `install.sh` — drifts silently; bare `curl \| bash` is forbidden by the repo's CI stack overlay |
| D3 | A toolchain failure gets a **new `ai:runner-blocked` label** + comment | Reusing `ai:review-blocked` — a label-only filter still could not tell a crash from a refusal |
| D4 | Pin `CLAUDE_CLI_VERSION` to **match the base action** (`2.1.270`) | Independent pin (silent divergence) or `stable` (behaviour changes without a commit) |
| D5 | The `ensure_opencode` shared-prefix hazard is **parked** as a follow-up | Fixing both paths in one PR — widens the diff beyond #302's concern |

## Design

### Component 1 — `scripts/install-claude-cli.sh` (new)

The single place the review and self-fix jobs acquire `claude`.

Sequence:

1. Guard prerequisites (`curl`, `sha256sum`) with `command -v`.
2. `curl -fsSL` upstream `install.sh` into a `mktemp` dir (`trap ... EXIT`).
3. Verify against pinned `INSTALLER_SHA256`. Mismatch → refuse to execute.
4. `bash install.sh "$CLAUDE_CLI_VERSION"`.
5. Append the resulting bin dir to `$GITHUB_PATH`.
6. Verify `claude --version` resolves.

Contract:

```
exit 0   claude on PATH at CLAUDE_CLI_VERSION
exit 64  prerequisite absent (curl / sha256sum) — names it + the doc
exit 65  installer checksum mismatch — refuses to execute
exit 66  installer ran but `claude` is still not on PATH
```

Every non-zero exit prints a **single-line diagnostic naming the unmet
requirement and `docs/RUNNER-REQUIREMENTS.md`** — #384 AC1. The guard shape
generalises past `npm`: it now covers `curl` and `sha256sum` too.

Env:

- `CLAUDE_CLI_VERSION` — default `2.1.270`, matching `agent-implement.yml:665`.
  A comment on both sides states they bump together.
- `INSTALLER_SHA256` — pinned in the script. Obtained at implementation time by
  fetching `install.sh` once and recording `sha256sum` of that exact byte
  sequence, with the capture date in a comment beside it. This is the only value
  to refresh when upstream edits the installer; a refresh is a deliberate commit,
  reviewed like any other dependency bump.
- `DRY_RUN=1` — perform the guards and report, skip network and execution.
  Mirrors `ensure-toolchain.sh`'s existing convention; this is what makes
  Layer-1 tests cheap.

### Component 2 — `scripts/post-runner-block.sh` (new)

Surfaces a toolchain failure the way `post-auto-review-block.sh` surfaces a
refusal, so the two are symmetric but distinct.

- Required env: `REPO`, `ISSUE_NUMBER`. Optional: `PR_NUMBER`, `REASON`,
  `EXIT_CODE`, `JOB_NAME`.
- Posts a comment on the PR when known, else the issue:

  > **Review did not run** — the `claude` CLI could not be installed on this runner.
  > Unmet requirement: `<name>`
  > See `docs/RUNNER-REQUIREMENTS.md` in the agent-workflow repo.

  The doc reference is a plain path, not a relative markdown link: the comment
  renders in the **consumer** repo, where a relative link would resolve against
  the wrong tree.

- Creates (idempotently) and applies `ai:runner-blocked`.

### Component 3 — `ensure-issue-labels.sh`

Add alongside the existing `ai:review-blocked` definition:

```bash
create ai:runner-blocked D73A4A 'Review never started — runner toolchain unmet'
```

Semantics, stated in the script's header comment:

- `ai:review-blocked` — the reviewer **ran** and refused to promote.
- `ai:runner-blocked` — the reviewer **never started**; fix the runner.

### Component 4 — `agent-implement.yml`

At `:1108` and `:1431`, replace the `npm install --prefix` block with:

```yaml
- name: Install Claude Code CLI
  id: install_cli
  if: <unchanged condition>
  run: bash .claude-pipeline/scripts/install-claude-cli.sh
```

The existing `if:` conditions, including the `stub-review-verdict` skip, are
preserved verbatim. Each gains a sibling failure-path step:

```yaml
- name: Mark issue runner-blocked
  if: failure() && steps.install_cli.outcome == 'failure'
  env: { REPO, ISSUE_NUMBER, PR_NUMBER, GH_TOKEN, REASON, EXIT_CODE }
  run: bash .claude-pipeline/scripts/post-runner-block.sh
```

The long `#302` comment block currently explaining the job-local prefix is
replaced by a short note saying npm is no longer on this path and pointing at
`install-claude-cli.sh`.

### Component 5 — `docs/RUNNER-REQUIREMENTS.md`

- The `AGENT=claude` row stops naming `npm install -g`. New text: installed by
  `claude-code-base-action` in the implement job, and by
  `scripts/install-claude-cli.sh` (native installer, requires `curl` +
  `sha256sum`) in the review and self-fix jobs.
- The promise at `:27` — *"If `npm` is not on the runner, the script fails with
  a clear error"* — is **narrowed to the opencode path**, which is the only path
  that honours it. #384 AC3.
- `nodejs` stays in the Ansible package list, annotated `# opencode only`.
- New row: `curl`, `sha256sum` — required whenever `AGENT=claude`.

## Testing

**Layer 0** — `actionlint` on the workflow, `shellcheck -x` on both new scripts.

**Layer 1** — `tests/run-install-claude-cli-tests.sh` (new), following the
existing `run-script-tests.sh` idiom (`assert_contains`, `run_capture_ec`, PATH-
shadowed mocks). One case per branch:

| Case | Asserts |
|---|---|
| happy path (mocked curl + matching sum) | exit 0, bin dir appended to `GITHUB_PATH` |
| `curl` absent | exit 64, message names `curl` and `RUNNER-REQUIREMENTS.md` |
| `sha256sum` absent | exit 64, names `sha256sum` |
| checksum mismatch | exit 65, installer **not** executed |
| installer ran, no binary | exit 66 |
| `DRY_RUN=1` | guards run, no network, exit 0 |

`tests/run-post-runner-block-tests.sh` (new) against the existing `gh` mock:
comment targets the PR when `PR_NUMBER` is set and the issue when it is not;
`ai:runner-blocked` applied; `ai:review-blocked` **never** applied.

Both must run in well under the 5-second Layer-1 budget — no network, so the
`curl` mock writes a fixture file and the `sha256sum` mock returns a canned
verdict.

## Acceptance criteria

- [ ] No `npm` invocation remains on the `AGENT=claude` path in `agent-implement.yml`
- [ ] Review and self-fix jobs install the CLI via `scripts/install-claude-cli.sh`
      at the same pinned version the implement job's base action provides
- [ ] The installer script verifies a pinned SHA-256 before executing anything
      fetched over the network, and refuses to execute on mismatch
- [ ] A runner missing a prerequisite produces an error naming the requirement
      and `docs/RUNNER-REQUIREMENTS.md`, not a bare `command not found` (#384)
- [ ] A toolchain failure stamps `ai:runner-blocked` and comments on the
      issue/PR, so it is distinguishable from an `ai:review-blocked` refusal (#384)
- [ ] `docs/RUNNER-REQUIREMENTS.md`'s clear-error promise is true for every path
      it covers, or narrowed to the paths that honour it (#384)
- [ ] `actionlint` and `shellcheck -x` pass; Layer-1 suites green in <5s
- [ ] A follow-up issue exists for the `ensure_opencode` shared-prefix hazard

## Out of scope

- `ensure_opencode`'s `npm install -g` into the shared prefix (D5 — follow-up: #395)
- Provisioning the homelab runner's toolchain (#384 problem 1 — homelab Ansible role)
- A job-start runner preflight covering all requirements at once (#384 open Q3)
