[//]: # (Stack overlay — loaded together with .ai/base-instructions.md for CI / automation / pipeline projects)

# CI / Automation Stack Overlay

Applies on top of `.ai/base-instructions.md` for repos whose primary deliverable is **automation glue** rather than application code: GitHub Actions reusable workflows, composite actions, shell-script tooling, runner provisioning, release-engineering helpers, and similar pipeline-style projects.

Use this stack for repos like `claude-pipeline`, homelab tooling, internal action libraries, or any repo where the bulk of the source is `bash`, `.github/workflows/*.yml`, and supporting fixtures/tests.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Shell | Bash 5+ (`set -euo pipefail` + `IFS=$'\n\t'` at the top of every script) |
| Workflow definition | GitHub Actions YAML (reusable workflows + composite actions) |
| JSON / API tooling | `jq`, `gh` CLI, `curl` |
| Search | `ripgrep` (preferred over `grep` for runner consistency and gitignore-aware defaults) |
| Workflow linting | `actionlint` (workflows) + `shellcheck` (scripts) |
| Local workflow testing | [`act`](https://github.com/nektos/act) for end-to-end workflow runs without GitHub |
| Script testing | Fixture-driven bash tests with mocked external CLIs (`gh`, `curl`, etc.) |
| Containerization (optional) | Docker / `docker-compose` only when a workflow genuinely needs it |
| Documentation | Markdown under `docs/` — `DESIGN.md`, `DECISIONS.md` (ADRs), `CONSUMER-SETUP.md` |

---

## Project Structure

```
.github/workflows/
  <name>.yml              ← public reusable workflows consumers call
  <name>.test.yml         ← act-runnable test workflows (stubbed external steps)
  lint.yml                ← actionlint + shellcheck on PRs
scripts/
  <task>.sh               ← one script per discrete task
  lib/                    ← shared helpers (jq wrappers, formatters)
tests/
  fixtures/               ← canonical inputs (JSON / YAML / text) per scenario
  mocks/                  ← stubs for external CLIs (e.g. gh-mock.sh)
  run-script-tests.sh     ← layer-1 test entry point
docs/
  DESIGN.md               ← architecture + rationale
  DECISIONS.md            ← ADR-style record of choices
  CONSUMER-SETUP.md       ← how a consumer repo wires this up
  RUNNER-REQUIREMENTS.md  ← toolchain contract (hosted + self-hosted)
```

A repo using this stack ships either reusable workflows, composite actions, or both. It must not ship application code — promote that to a stack-specific overlay (`dotnet`, `flutter`) and split repos.

---

## Bash Conventions

Every script starts with the same prelude:

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
```

- `set -e` — fail on any command error
- `set -u` — fail on unset variables
- `set -o pipefail` — fail when any command in a pipeline errors
- Restricted `IFS` — prevents word-splitting surprises with filenames containing spaces

Conventions:

- **Quote every variable expansion** — `"$var"`, `"${arr[@]}"`. Unquoted is a bug.
- **`[[ ... ]]` over `[ ... ]`** — only POSIX `sh` warrants `[ ... ]`.
- **`$(...)` over backticks** — backticks don't nest cleanly.
- **Functions over inline blocks** — anything reused twice goes into `lib/`.
- **Exit codes are part of the API** — `0` success, `1` generic error, `2` usage error, `64+` task-specific. Document them.
- **Env-driven, not flag-driven, for CI scripts** — workflows pass values via `env:`. Reserve flags for human-invoked tools.
- **No `eval`** — ever. If you think you need it, you need a different design.
- **Use `mktemp` for temp files** and clean them up with `trap '... ' EXIT`.
- **`printf` over `echo` for anything with formatting** — `echo` semantics differ across shells.
- **Strict on unset config**: `: "${REQUIRED_VAR:?REQUIRED_VAR must be set}"` at the top of the script.

---

## GitHub Actions Conventions

### Reusable workflows

Public reusable workflows are the primary deliverable. Define inputs and outputs explicitly:

```yaml
on:
  workflow_call:
    inputs:
      runner-labels:
        description: JSON array of runner labels
        type: string
        default: '["ubuntu-latest"]'
      timeout-minutes:
        type: number
        default: 30
    secrets:
      TOKEN:
        required: true
```

- **One reusable workflow per public entry point.** Don't multiplex unrelated triggers in one file.
- **Pin every action by full SHA**, not by tag. Renovate/Dependabot promotes the SHA.
  ```yaml
  - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11  # v4.1.1
  ```
- **Concurrency control** on every long-running workflow: cancel in-progress runs of the same ref.
  ```yaml
  concurrency:
    group: ${{ github.workflow }}-${{ github.ref }}
    cancel-in-progress: true
  ```
- **Permissions: least-privilege.** Top of the workflow:
  ```yaml
  permissions:
    contents: read
  ```
  Then escalate per-job only where needed (`pull-requests: write`, `issues: write`, `id-token: write`).
- **`timeout-minutes:` on every job.** Defaults of 6 hours are not safe defaults.
- **Output extraction in scripts, not inline bash.** Inline bash in YAML is unlinted, untested, hard to read. One-liners excepted.

### Composite actions

Use composite actions for steps reused across multiple workflows in the same repo. Keep them in `.github/actions/<name>/action.yml`. A composite action without tests does not exist.

### Self-hosted runners

- **Never attach self-hosted runners to public repos.** Pwn-request attack surface. Public repos must use `ubuntu-latest` (or other GitHub-hosted) permanently.
- Self-hosted labels conventional: `[self-hosted, <site>, <purpose>]` (e.g. `[self-hosted, homelab, claude]`).
- The runner toolchain contract is defined in `docs/RUNNER-REQUIREMENTS.md` and provisioned by an Ansible role in the homelab repo — not by the workflow repo itself.

---

## Testing Strategy — Layered

Every layer must run in CI; the lower layers also run locally in seconds.

### Layer 0 — Lint

`actionlint` for workflows, `shellcheck -x` for scripts. Runs on every PR.

### Layer 1 — Script tests with fixtures

Bash scripts execute against fixture files (`tests/fixtures/*.json`) with external CLIs mocked via `tests/mocks/`. Should run in **<5 seconds** total. No network, no GitHub, no Docker.

```
tests/
  fixtures/
    result-success.json
    result-rate-limit.json
    result-max-turns.json
  mocks/
    gh-mock.sh           ← stubs `gh` CLI: parses argv, returns canned output per fixture
  run-script-tests.sh    ← drives scripts against each fixture, asserts outputs
```

Convention: every branch in a script must be covered by at least one fixture. If a script grows a new failure mode, add the fixture in the same PR.

### Layer 2 — `act` end-to-end

A `*.test.yml` workflow exercises the reusable workflow with the actual external step (e.g. Claude, deploy) replaced by a stub. `act` runs it locally inside Docker. Catches YAML/inputs/secrets-wiring errors that lint can't.

### Layer 3 — Real run on a sandbox repo

Before integrating into the production consumer repo, dogfood on a private throwaway repo (`<name>-sandbox`). Iterate until clean before promoting.

### Layer 4 — Real run on the production consumer

Only after layers 0–3 are clean.

**Don't skip layers.** Each catches a different class of bug, and the cost grows by ~10× per layer.

---

## Linting

```yaml
# .github/workflows/lint.yml
jobs:
  actionlint:
    - uses: rhysd/actionlint@<sha>
  shellcheck:
    - run: shellcheck -x -e SC1091 scripts/**/*.sh tests/**/*.sh
```

- `-x` follows sourced files; required if you use `lib/`.
- `SC1091` (can't follow non-constant source) is normally suppressed; everything else is opt-in per script with an inline `# shellcheck disable=SCxxxx` and a short reason comment.
- New rule suppressions go through review — don't blanket-suppress.

---

## Essential Commands / Make Targets

Pipeline repos using this stack should ship a repo-root `Makefile` with these canonical targets. Recipe bodies are project-specific; target names are not.

### Quality
- `lint` — actionlint + shellcheck on workflows and scripts
- `test` — Layer-1 fixture tests
- `test-act` — Layer-2 `act` run of `*.test.yml` workflows
- `format` — formatters where applicable (e.g. `shfmt -w scripts/`)

### Local development
- `fixtures-update` — regenerate fixtures from a known-good real run (when intentional)
- `docs` — generate / verify docs (e.g. CHANGELOG via `git-cliff`)

### Release
- `version` / `version-set V=X.Y.Z` / `bump-major` / `bump-minor` / `bump-patch` / `bump-auto`
- `changelog` — `git-cliff --output CHANGELOG.md`
- `release` — tag `v$(VERSION)`, regenerate changelog, commit, tag (no auto-push)
- `push-release` — `git push origin main "v$(VERSION)"`

### Cleanup
- `clean` — remove generated artifacts (`.act/`, `coverage/`, etc.)

Document each target with an inline `## <description>` and expose a `help` target that greps them.

---

## Security

- **Secrets:** declared at the workflow_call boundary, passed in by the consumer repo. Never hardcoded, never logged. `set +x` before any line that interpolates a secret.
- **Action pinning:** full SHA, never `@v3` or `@main`. Mutable tags are a supply-chain risk.
- **`pull_request_target`:** avoid. If genuinely needed, never check out the PR's code with elevated permissions in the same job that handles untrusted input.
- **Fork PRs from public repos:** treat as untrusted. Don't run them on self-hosted. Don't expose secrets.
- **Workflow permissions:** `contents: read` at workflow scope, escalate per-job.
- **Third-party scripts:** if a workflow installs anything via `curl | bash`, pin the script's checksum or vendor it into the repo. No exceptions.

---

## Versioning (stack binding)

Base rules (SemVer, Conventional Commits → bump mapping, git-cliff) live in `base-instructions.md`. For this stack:

- **Reusable workflows are versioned by git tag.** Consumers reference `freaxnx01/<repo>/.github/workflows/<name>.yml@v1` — so a `v1` major-version tag is moved forward as backward-compatible changes ship, and `v2` is cut for breaking changes. Document the breaking change in `CHANGELOG.md` and provide a migration note.
- **Single source of truth for the version**: `VERSION` file at repo root, read by the Makefile.
- **Tag format**: `vMAJOR.MINOR.PATCH` (e.g. `v1.4.2`); the major-version moving tag is `vMAJOR` (e.g. `v1`).

---

## CI/CD (self-test)

This stack's own pipeline:

```yaml
jobs:
  lint:        actionlint + shellcheck
  test:        run-script-tests.sh
  act-run:     workflow_call test of *.test.yml under act (Linux only)
  release:     on tag — regenerate changelog, publish release notes
```

Every PR runs `lint` + `test`. `act-run` is opt-in (label-gated) to keep PR runtime low.

---

## Project Scaffold Checklist (CI / automation)

- [ ] `.editorconfig`
- [ ] `Makefile` with the targets above
- [ ] `VERSION` file
- [ ] `CHANGELOG.md` with `[Unreleased]` section
- [ ] `cliff.toml` for `git-cliff`
- [ ] `.github/workflows/lint.yml` (actionlint + shellcheck)
- [ ] At least one reusable workflow under `.github/workflows/`
- [ ] At least one `*.test.yml` covering the reusable workflow under `act`
- [ ] `tests/fixtures/` with one fixture per documented scenario
- [ ] `tests/mocks/` for any external CLI the scripts call
- [ ] `tests/run-script-tests.sh` — runs in <5 seconds locally
- [ ] `docs/DESIGN.md` and `docs/DECISIONS.md`
- [ ] `docs/CONSUMER-SETUP.md` with a copy-paste consumer stub
- [ ] `docs/RUNNER-REQUIREMENTS.md` if the stack supports self-hosted runners
- [ ] `CLAUDE.md`, `.github/copilot-instructions.md`, `SKILL.md` (via `/sync-ai-instructions ci`)
- [ ] Branch protection on `main`; require lint + test green

---

## Agent Guardrails (stack-specific additions)

In addition to the base guardrails:

- Do not pin actions to floating tags (`@v3`, `@main`). Always full SHA + comment.
- Do not introduce inline bash longer than 5 lines inside a YAML step — extract to `scripts/` and add a fixture test.
- Do not call external CLIs without a corresponding mock in `tests/mocks/`.
- Do not edit a workflow without verifying `actionlint` and `shellcheck` pass.
- Do not loosen workflow `permissions:` — always start from `contents: read` and escalate per-job.
- Do not attach self-hosted runners to public repos.
- Do not add a workflow that runs on `pull_request_target` without a written security review in `docs/DECISIONS.md`.

### Never generate (this stack)

- `curl | bash` in a workflow without a vendored script or a checksum
- Action references with mutable tags (`@v3`, `@latest`, `@main`) — full SHA only
- Bash scripts without `set -euo pipefail`
- Inline bash >5 lines inside a YAML step
- Secrets in plaintext, logs, or fixture files
- `pull_request_target` with `actions/checkout@... ref: ${{ github.event.pull_request.head.sha }}` and elevated permissions in the same job
- Tests that hit the real GitHub API or a real runner
- Hardcoded organization or repo names — use `${{ github.repository }}` and inputs
- Workflow-level `permissions: write-all` or unscoped `contents: write`
- Self-hosted runner labels on public-repo workflows
