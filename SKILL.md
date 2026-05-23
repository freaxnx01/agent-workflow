[//]: # (Source of truth: .ai/base-instructions.md + .ai/stacks/ci.md — update those, then regenerate by re-running /sync-ai-instructions)

# SKILL.md — OpenClaw Agent Skill

This skill configures OpenClaw for this project.

# AI Agent Base Instructions

Canonical, **stack-agnostic** reference for all AI coding agents. Applies to every project regardless of language or framework. Stack-specific overlays live in `.ai/stacks/<stack>.md` and are loaded alongside this file. A project loads **base + exactly one stack overlay**. Tool-specific files (`CLAUDE.md`, `.github/copilot-instructions.md`, `SKILL.md`) derive from base + the chosen stack.

---

## Clean Code Principles

Apply to all generated and modified code, regardless of language:

- **Small methods/functions** — each does one thing at one level of abstraction; aim for ≤20 lines
- **Guard clauses** — validate and return/throw early at the top; avoid nested `if/else` pyramids
- **Command-Query Separation** — a function either performs an action (command, returns nothing) or returns data (query), never both
- **No flag arguments** — avoid boolean parameters that switch behaviour; split into two clearly named functions instead
- **Meaningful names** — names reveal intent; no abbreviations (`cnt`, `mgr`, `svc`) except universally understood ones (`id`, `url`, `dto`)
- **One level of abstraction per function** — don't mix high-level orchestration with low-level detail; extract helpers
- **Fail fast** — detect invalid state as early as possible and throw specific errors; don't let bad data travel deep into the call stack
- **DRY** — if the same logic exists in two places, extract it; but prefer duplication over the wrong abstraction — wait until the pattern is clear before generalising
- **No dead code** — delete unreachable branches, unused parameters, and vestigial methods; git has history
- **No commented-out code blocks** — delete them, git has history

---

## Testing — TDD, Tests First, No Shortcuts

Applies to every language and framework:

1. Write the failing test first
2. Write the minimum implementation to make it pass
3. Refactor
4. **Never modify a test to make it green** — fix the implementation
5. **Never hardcode return values, mock results, or stub logic** to satisfy a test
6. **Never silently swallow exceptions** to make a test green
7. **After implementation, run the full test suite** — not just the new test
8. **If a test fails after 3 attempts, STOP** and explain what's going wrong instead of continuing to iterate
9. Test naming: `MethodName_StateUnderTest_ExpectedBehavior` (or the idiomatic equivalent for the target language)
10. E2E tests must be independent and idempotent — seed and clean up their own data

Framework-specific test project layout, mocking library choice, and assertion library live in the stack overlay.

---

## UI Development Workflow (Mandatory Phase Order)

**Never skip phases. Never write component code before wireframe approval.**

| Phase | Skill | Gate |
|---|---|---|
| 1 — Brainstorm | `/ui-brainstorm` | ASCII wireframe approved |
| 2 — Flow       | `/ui-flow`       | Mermaid diagrams approved |
| 3 — Build      | `/ui-build`      | Shell → logic → interactions → polish |
| 4 — Review     | `/ui-review`     | Checklist passes |

Skill files live in `.ai/skills/`. The skills themselves are stack-neutral — UI component library preferences (e.g. MudBlazor, shadcn/ui, Material, Flutter widgets) are captured in the active stack overlay.

### What to check before writing UI code

- [ ] Does a similar component already exist in a shared folder?
- [ ] Has the ASCII wireframe been approved?
- [ ] Has the Mermaid flow been approved?
- [ ] Are you building the shell first (no business logic yet)?
- [ ] Does the component need a unit/component test?

---

## Localization (i18n) & Regional Formatting

User-facing apps must support **`de` and `en`**. CI tooling and developer-only utilities are exempt.

### Language

- Default language resolved from the OS / browser locale at first launch
- User can override at runtime via an in-app language switcher
- The user's choice is persisted (cookie, preferences store, or user profile — stack-specific)

### Regional formatting (decoupled from language)

Regional formatting (date, time, number, currency separators) is selected from the OS region — **not** dictated by the language.

- Auto-detect any `de-*` OS region (`de-CH`, `de-DE`, `de-AT`, …) and use the matching culture
- If the language is `de` but the OS region is missing or unrecognized: fall back to **`de-CH`**
- For `en`: use the OS-provided region (typically `en-US` / `en-GB`) — do not force a default

### Rules

- All date / number / currency rendering goes through the platform's localization API — never hand-format with raw `string.Format` / `toString()` / template literals.
- Do not couple regional formatting to the UI language. A user can read German text with US formatting, or English text with Swiss formatting; both must work.
- Stack overlays specify the concrete API (`CultureInfo` + `RequestLocalization` for .NET, `flutter_localizations` + `intl` for Flutter, etc.).

---

## Versioning (SemVer)

All projects follow [Semantic Versioning 2.0.0](https://semver.org/): `MAJOR.MINOR.PATCH` — `MAJOR` = breaking, `MINOR` = new feature (backwards-compatible), `PATCH` = bug fix.

Conventional Commits mapping: `BREAKING CHANGE:` footer or `!` after type → MAJOR; `feat` → MINOR; `fix`, `perf` → PATCH; `chore`, `docs`, `ci`, `test`, `refactor` → no bump.

- Git tags follow `v<MAJOR>.<MINOR>.<PATCH>` (e.g. `v1.3.0`) — tag on `main` after merge
- Pre-release: `v1.0.0-alpha.1`, `v1.0.0-beta.2`, `v1.0.0-rc.1`
- **git-cliff** is the changelog and release notes tool — configured via `cliff.toml`
- Where the version is declared in the project (build file, manifest, etc.) is defined by the stack overlay — but it must be declared in **exactly one place**

---

## Changelog

All projects maintain a `CHANGELOG.md` in the repo root following [Keep a Changelog](https://keepachangelog.com) conventions. **Sections per release:** `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.

- `[Unreleased]` section accumulates changes until a release is cut
- Auto-generation: **git-cliff** with `cliff.toml` configured for Conventional Commits
- CI integration: `orhun/git-cliff-action` in GitHub Actions generates release notes into GitHub Releases
- CI can validate that `[Unreleased]` is not empty before allowing a release branch

Example: [`.ai/references/base/changelog-example.md`](https://github.com/freaxnx01/ai-instructions/blob/main/.ai/references/base/changelog-example.md)

---

## 12-Factor App Compliance

Projects follow the [12-Factor App](https://www.12factor.net/) methodology: one repo per service, all deps declared, env-var config, attached backing services, separate build/release/run stages, stateless processes, port binding, scale via replicas not threads, fast disposability, dev/prod parity, logs to stdout, admin processes as one-offs.

Stack-specific enforcement details (logging library, migrations, etc.) live in the stack overlay.

Full per-factor table: [`.ai/references/base/12-factor.md`](https://github.com/freaxnx01/ai-instructions/blob/main/.ai/references/base/12-factor.md)

---

## Branching Strategy (GitHub Flow + protection rules)

```
main              ← always deployable, protected
  └── feature/<issue-id>-short-description
  └── fix/<issue-id>-short-description
  └── chore/<short-description>
  └── release/<version>   ← only if needed for staged releases
```

- `main` requires: passing CI, at least 1 PR review, no direct push
- Branch from `main`, PR back to `main`
- Delete branch after merge
- Rebase or squash merge — no merge commits on `main`

---

## Git Worktrees

### Worktree directory

- Use **project-local** worktrees under `.worktrees/` at the repo root (hidden directory)
- `.worktrees/` must be listed in `.gitignore` — add and commit it before creating the first worktree in a repo
- Use a **random, short branch name** when the user does not specify one (e.g. `wt/<8-hex-chars>`); do not prompt for a branch name

Agent tooling that automates worktree creation should discover these rules from `CLAUDE.md` / `AGENTS.md` (e.g. a `worktree.*director` grep) and honour them without asking.

---

## Commit Messages (Conventional Commits)

```
<type>(<scope>): <short summary>

[optional body]

[optional footer: Closes #<issue>]
```

**Types:** `feat`, `fix`, `test`, `refactor`, `chore`, `docs`, `ci`, `perf`
**Scope:** module or layer name, e.g. `orders`, `auth`, `infra`, `ui`

```
feat(orders): add order cancellation endpoint

Implements POST /api/v1/orders/{id}/cancel.
Validates order is in Pending state before cancelling.

Closes #42
```

- Subject line: imperative mood, ≤72 chars, no period
- Body: explain *why*, not *what*
- Breaking changes: add `BREAKING CHANGE:` footer (or `!` after the type)

---

## Pull Request Conventions

### PR Title

Follow Conventional Commits format: `feat(orders): add cancellation endpoint`

### PR Description Template

Body sections: **Summary** · **Changes** · **Testing** (unit, component/integration, E2E, local) · **Checklist** (tests pass, no new vulnerable deps, no secrets, migrations included if schema changed, API/OpenAPI spec still valid).

Template: [`.ai/references/base/pr-description-template.md`](https://github.com/freaxnx01/ai-instructions/blob/main/.ai/references/base/pr-description-template.md)

### Review Guidelines

- PRs should be small and focused — one concern per PR
- Reviewers check: architecture adherence, test quality, security, no shortcuts that make tests green
- Auto-assign reviewers via `CODEOWNERS`

---

## CI/CD (generic outline)

Pipeline stages: `build` → `test` → `security-scan` → `container-build` → `push`

- Build and test run on every PR
- Vulnerable-dependency scan fails the build on HIGH/CRITICAL
- Container image built and pushed only on `main` after tests pass
- E2E tests run against the built image before it is marked as a release candidate

Concrete CI configuration (GitHub Actions YAML, commands, package scanners) lives in the stack overlay.

---

## Documentation Structure

Repo-root `docs/` contains:
- `design/<feature-name>/` — UI wireframes (`wireframe.md`) & Mermaid flows (`flow.md`) per feature
- `adr/` — Architecture Decision Records
- `ai-notes/` — AI agent working notes

Rules:
- `README.md` and `CHANGELOG.md` live in the repo root
- UI design artifacts are saved per feature during the UI workflow phases
- AI agents write working notes to `docs/ai-notes/`, not `.ai/`
- `.ai/` is reserved for agent instructions and skill files only

Layout: [`.ai/references/base/documentation-structure.md`](https://github.com/freaxnx01/ai-instructions/blob/main/.ai/references/base/documentation-structure.md)

---

## Security (baseline)

- Transport security enforced (HTTPS + HSTS)
- No secrets in source files or per-environment config files — environment variables or a secrets manager only
- Validate all inputs at system boundaries before any domain logic
- Run a vulnerable-dependency scan in CI — fail the build on HIGH/CRITICAL findings
- Standard security response headers on every HTTP response

Language- and framework-specific enforcement (specific scanners, validation libraries, header mechanisms) lives in the stack overlay.

---

## Agent Guardrails

- Do not install additional packages without asking first
- Do not change the project's target runtime or framework version
- Do not modify build/project files unless the task requires it
- Do not introduce new architectural patterns unless explicitly asked
- Do not touch files outside the scope of the current task
- Keep changes minimal and focused — do not refactor unrelated code unless asked
- Never skip git hooks (`--no-verify`) unless the user explicitly asks
- Never commit secrets or credential files

Stack-specific guardrails (e.g. "do not add NuGet packages") live in the stack overlay.

---

## Project Scaffold Checklist (baseline)

Init-time checklist (every project, regardless of stack) — including baseline, .NET, and WebAPI layers — lives at [`.ai/references/scaffold-checklists.md`](https://github.com/freaxnx01/ai-instructions/blob/main/.ai/references/scaffold-checklists.md). Stack-specific additions are in the same file under their respective sections.

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

## Essential Commands / just Recipes

Pipeline repos using this stack should ship a repo-root `justfile` (using [casey/just](https://github.com/casey/just)) with these canonical recipes. Recipe bodies are project-specific; recipe names are not.

### Quality
- `lint` — actionlint + shellcheck on workflows and scripts
- `test` — Layer-1 fixture tests
- `test-act` — Layer-2 `act` run of `*.test.yml` workflows
- `format` — formatters where applicable (e.g. `shfmt -w scripts/`)

### Local development
- `fixtures-update` — regenerate fixtures from a known-good real run (when intentional)
- `docs` — generate / verify docs (e.g. CHANGELOG via `git-cliff`)

### Release
- `version` / `version-set 1.2.3` / `bump-major` / `bump-minor` / `bump-patch` / `bump-auto`
- `changelog` — `git-cliff --output CHANGELOG.md`
- `release` — tag `v$(just version)`, regenerate changelog, commit, tag (no auto-push)
- `push-release` — `git push origin main "v$(just version)"`

### Cleanup
- `clean` — remove generated artifacts (`.act/`, `coverage/`, etc.)

Document each recipe with a leading `# <description>` comment. Set a default recipe `default: @just --list --unsorted` so `just` with no args prints the documented set.

Install (requires just ≥ 1.20): `cargo install just` / `brew install just` / `winget install Casey.Just` / `sudo apt install just`. CI: `extractions/setup-just@v2`.

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
- **Single source of truth for the version**: `VERSION` file at repo root, read by the justfile.
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
- [ ] `justfile` with the recipes above
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
