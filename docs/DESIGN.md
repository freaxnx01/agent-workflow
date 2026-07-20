# Claude Pipeline — Design Notes for Implementation

> Handoff from desktop brainstorming (April 2026) to local Claude Code session.
> Drop this file into the new `freaxnx01/agent-workflow` repo as `docs/DESIGN.md`
> or similar, and reference it from CLAUDE.md so future sessions stay aligned.
>
> Brainstorming transcript: <https://claude.ai/share/3f06e2d3-2b65-4b64-87a6-81d6715005f7>
>
> Architectural decisions made after this design landed are recorded in
> [DECISIONS.md](DECISIONS.md).

## Goal

Build a personal Issue→PR autonomous pipeline using **Claude Code in GitHub Actions**,
modeled after the GitHub Copilot Coding Agent workflow but using your Claude Max
subscription, your model choices, and your existing `dotnet-ai-instructions` conventions.

## Scope

- **Personal repos only.** Work repos (`anim-bossinfo-ch`) are out of scope for now.
- **CI side *and* operator console.** This repo owns both the CI implementation
  (`.github/workflows`, `scripts`, fixtures) **and** the user-level slash-command
  console (`commands/`) you drive the pipeline with — forge-agnostic across GitHub
  Actions (now) and Forgejo Actions (later). See ADR-005.
- **Modes #0 and #1 only.** Mode #2 (Copilot Coding Agent) is deferred — not needed
  for personal use, since the focus is on the Claude ecosystem.
- **Mode #0**: do it now locally, no delegation. The skill must support deciding this.
- **Mode #1**: delegate to Claude Code running in GH Action via labeled issue.

## Architecture

### Three repos, distinct concerns

```text
freaxnx01/agent-workflow       # the pipeline end-to-end: CI side (workflows, scripts, fixtures, docs) + operator console (commands/)
freaxnx01/dotnet-ai-instructions # EXISTING — local Claude Code stack, /sync-ai-instr
freaxnx01/<homelab-ansible>      # EXISTING — add github-actions-runner role here
```

Plus consumer repos (FlowHub, future personal projects) that get a ~15-line workflow
stub via `/sync-ai-instr`.

### Reusable workflow pattern

`agent-workflow` exposes a single reusable workflow that consumer repos call:

```yaml
# In consumer repo: .github/workflows/agent.yml
jobs:
  claude:
    uses: freaxnx01/agent-workflow/.github/workflows/agent-implement.yml@v1
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    with:
      runner-labels: '["ubuntu-latest"]'   # or self-hosted for private repos
      default-model: claude-sonnet-5
```

This means:

- Single source of truth for the pipeline logic
- Each consumer repo has a tiny stub (good for `/sync-ai-instr`)
- `agent-workflow` must be **public** (or accessible via PAT) for FlowHub (public) to call it

### Runner strategy

| Repo type | Runner |
|---|---|
| Public (FlowHub) | `ubuntu-latest` (GitHub-hosted, unlimited free minutes) |
| Private homelab repos | `[self-hosted, homelab]` (LXC on Proxmox) |

**Critical security constraint:** never attach self-hosted runners to public repos.
Fork-PR attack surface is unacceptable. FlowHub stays GitHub-hosted permanently.

The self-hosted LXC runner is provisioned via a new Ansible role in the existing
homelab Ansible repo (`roles/github-actions-runner/`), not in `agent-workflow` itself.
Treat it like any other homelab service.

### Runner toolchain (both hosted and self-hosted)

Headless Claude benefits from a small standard toolset on the runner. Some are
pre-installed on `ubuntu-latest`, others need explicit install. On self-hosted
runners, bake everything into the LXC via Ansible so per-run install cost is zero.

**Required:**

- `ripgrep` — Claude Code's built-in Grep tool prefers `rg` when available.
  ~5–20× faster than grep on medium repos, respects `.gitignore` by default
  (no node_modules noise), better Unicode/regex defaults. Pre-installed on
  `ubuntu-latest`; verify before adding install step. Required on self-hosted.
- `gh` CLI — needed for issue comments, label updates, PR creation. Pre-installed
  on `ubuntu-latest`.
- `jq` — used by `post-run-report.sh` and other scripts. Pre-installed on
  `ubuntu-latest`.

**Recommended:**

- `fd` — file finder, complements ripgrep. Modest benefit; nice to have.
- Language formatters in scope: `dotnet format` (for .NET repos), `prettier`
  (for JS/TS), `black` (for Python). Lets Claude run formatter as a self-check
  before opening PR. Headless Claude's CLAUDE.md should mandate running these.
- `actionlint` and `shellcheck` for the pipeline repo's own lint workflow.

**Not installed by default — explicit opt-in only:**

- LSP servers (csharp-lsp, vtsls, etc.). Deferred — see "Deferred decisions".
- Superpowers / other Claude Code plugins. Deferred — see "Deferred decisions".

For self-hosted runners, the Ansible role's `defaults/main.yml` should declare
these as a list; provisioning installs them via apt or appropriate package
manager. Document the contract in `RUNNER-REQUIREMENTS.md`.

For GitHub-hosted runners, only install missing tools in the workflow as a
named step — keep it conditional on the tool being absent so Ubuntu version
upgrades that bundle new tools don't waste time reinstalling them.

## Pipeline behavior

### Triggers

- Label `ai-implement` on an issue → autonomous Issue→PR run
- Label `model:opus` / `model:sonnet` / `model:haiku` (alongside `ai-implement`) → override triage
- `@claude` mention in issue/PR comment → interactive mode, no `prompt:` injected

### Triage step

A small Haiku-powered classifier reads the issue and decides Opus / Sonnet / Haiku
for the implementation step, unless an explicit `model:*` label is present.
Bias toward Sonnet when uncertain. Posts decision as issue comment for observability.

### Metrics & reporting

Every run posts a comment to the issue with:

- Outcome, duration, turns, cost
- Tokens (input / output / cache read / cache create)
- Cache hit rate (key signal of CLAUDE.md health)
- Avg context utilization per turn (warn at 50%, alert at 75%)
- Workflow run link

Plus stamps labels: `ai:running`, `ai:done`, `ai:failed`, `ctx:high` / `ctx:medium`.

### Retry / rate-limit handling

Retry policy depends on failure mode:

- **Rate limit**: parse reset time from error, sleep, re-dispatch via workflow_dispatch.
  Hard cap 3 retries.
- **Transient infra (5xx, network)**: exponential backoff, 3 retries.
- **Task failure (max-turns, tests fail)**: 1 retry max, only with bumped max-turns
  or escalated model. Default: stop and ping human.

Failure classification done by a small Haiku classifier step (same pattern as triage).

For self-hosted runners: sleeping during rate-limit waits is free. For GitHub-hosted
(FlowHub): minutes are unlimited on public repos, also free. Pattern A from the
brainstorm (self-rescheduling) is fine for both.

## Repo structure for agent-workflow

```text
agent-workflow/
├── .github/workflows/
│   ├── agent-implement.yml         # the reusable workflow consumers call
│   ├── agent-implement.test.yml    # stubbed Claude step, for act-based testing
│   └── lint.yml                     # actionlint + shellcheck on PRs
├── commands/                        # user-level operator console (routers, gh/, fj/) — linked into ~/.claude/commands/
├── scripts/
│   ├── classify-failure.sh          # rate_limit | transient | task_failure | bug
│   ├── classify-task.sh             # haiku triage: opus | sonnet | haiku
│   ├── post-run-report.sh           # the metrics comment generator
│   ├── retry-dispatch.sh            # parses reset time, schedules re-run
│   ├── ensure-toolchain.sh          # idempotent: installs ripgrep etc. if missing
│   └── lib/                         # shared helpers (jq wrappers, gh mocks for tests)
├── tests/
│   ├── fixtures/
│   │   ├── result-success-cheap.json
│   │   ├── result-success-expensive.json
│   │   ├── result-rate-limit.json
│   │   ├── result-max-turns.json
│   │   ├── result-low-cache-hit.json
│   │   └── result-high-context.json
│   ├── run-script-tests.sh          # layer-1 tests, no GH/Claude needed
│   └── mocks/
│       └── gh-mock.sh               # stub gh CLI for offline testing
├── docs/
│   ├── DESIGN.md                    # this file
│   ├── CONSUMER-SETUP.md            # how to wire up a new repo
│   ├── RUNNER-REQUIREMENTS.md       # toolchain contract for hosted + self-hosted
│   ├── METRICS.md                   # what each metric means, when to act
│   ├── DELEGATE-TO-GH.md            # design of the local skill (not the skill itself)
│   └── DECISIONS.md                 # ADR-style record of choices and reasoning
├── CLAUDE.md                        # for Claude Code working on the pipeline itself
└── README.md
```

## Implementation order

Strict order. Don't skip ahead.

### Phase 1: Foundations (Layer 0/1 testing)

1. Create `agent-workflow` repo (private at first; flip public when stable)
2. Set up `actionlint` + `shellcheck` lint workflow
3. Build `scripts/post-run-report.sh` with extracted bash, env-driven
4. Build fixture set (~6 JSON files covering success/failure/edge cases)
5. Build `tests/run-script-tests.sh` that runs scripts against fixtures with mocked `gh`
6. Verify locally — should run in <5 seconds, exercise all branches

### Phase 2: Workflow assembly

7. Build `agent-implement.yml` reusable workflow with stubbed Claude step
8. Add `ensure-toolchain.sh` step that installs ripgrep et al. on hosted runners
   (idempotent, conditional, cheap)
9. Build `agent-implement.test.yml` for `act`-based local runs
10. Verify with `act` — workflow logic correct end-to-end

### Phase 3: First consumer integration

11. Create `claude-action-sandbox` repo (private, throwaway)
12. Add CLAUDE.md and the consumer stub workflow
13. Generate `CLAUDE_CODE_OAUTH_TOKEN` via `claude setup-token`
14. Add token as repo secret
15. Run a real `ai-implement` task on a trivial issue (e.g., "add a hello.md file")
16. Iterate until clean

### Phase 4: Triage + retry

17. Add the Haiku classify-task.sh step for model selection
18. Add classify-failure.sh and retry-dispatch.sh
19. Test rate-limit path with fixtures + act (real rate limits are too slow to wait for)

### Phase 5: FlowHub integration

20. Add consumer stub to FlowHub
21. Configure FlowHub-specific settings (concurrency, timeout, fork-PR protection)
22. Run a real task end-to-end

### Phase 6: Self-hosted runner (later, only for private repos)

23. Add Ansible role for github-actions-runner LXC in homelab repo
24. Bake toolchain (ripgrep, gh, jq, fd, formatters) into the LXC image
25. Provision LXC, register as runner with labels `[self-hosted, homelab]`
26. Test with a private homelab repo (NOT FlowHub)

### Phase 7: delegate-to-gh skill (only after using Phases 1–5 manually for ~2 weeks)

27. Build the local skill once you've written ~20 issue specs by hand and know
    what makes them succeed or fail
28. Implement skill-assisted path discovery (Grep/Glob/Read/LSP orchestration)
29. Skill enforces spec template (see "Skill behavior" section)
30. Skill supports Mode #0 ("don't delegate, do it now") as valid outcome
31. Skill surfaces negative findings explicitly in generated specs

## Skill behavior: assisted spec writing

The skill is not just a form to fill out. It is an **exploration → spec
crystallization** workflow. The user starts with fuzzy intent ("add 24h caching
to SRF episode lookups") and the skill helps them end with a precise, actionable
spec — using the local Claude session's tools to do real exploration.

### Skill-assisted path discovery

Filling in `Affected files` correctly is the skill's most important job. It must
not punt this to the user OR to headless Claude. Path discovery happens *now*,
in the local session, using the tools local Claude has available:

- `Grep` / `ripgrep` for term-based search
- `Glob` for filename patterns
- `Read` for verifying suspected files
- `csharp-lsp` `findReferences` / `goToDefinition` when on .NET projects with the
  plugin loaded
- Existing knowledge from the conversation (files already discussed)

The skill should run targeted exploration automatically, present candidates with
context, and ask focused follow-ups. Example flow:

```text
User: /delegate-to-gh "Add 24h caching to SRF episode lookups"

Skill (orchestrating local Claude):
  - Searches "SRF" → identifies SrfRadioService.cs, ISrfRadioService.cs, tests
  - Runs LSP findReferences on SrfRadioService → enumerates callers
  - Globs *Cache* → finds existing IMemoryCacheWrapper pattern
  - Reads candidate files to confirm relevance
  - Presents:
    "Candidate files: [list with one-line justification each]
     Existing pattern in repo: IMemoryCacheWrapper — suggest reusing.
     Out-of-scope candidates I'd recommend excluding: [...]
     Negative findings: no existing 24h-style time-based cache in repo."

User: refines, adds, removes
Skill: regenerates spec, asks for final approval
Skill: only after explicit approval, creates the issue
```

### Skill behavior rules

- **Be opinionated.** If grep returns 47 candidates, narrow with follow-ups
  ("auth means SSO, password handling, or session validation?"). Don't dump.
- **Surface negative findings explicitly.** "I did not find an existing pattern
  for X" prevents headless Claude from hallucinating one.
- **Distinguish 'no match' from 'greenfield'.** If no files found, ask whether
  this is new code or whether the user used different terminology than the
  codebase does.
- **Refuse to delegate vague tasks.** If after exploration the user can't approve
  a concrete file list and acceptance criteria, the right outcome is Mode #0
  (do it now locally) or "spec not ready, work on it more first."
- **Surface the spec for approval before creating the issue.** Show the full
  rendered issue body. Allow edits. Never auto-submit.

### Spec template the skill produces

```markdown
## Goal
<1-2 sentences. What does done look like?>

## Affected files (explicit paths)
- path/to/file1.cs — <one-line role: "primary change" / "interface update" / "tests">
- path/to/file2.cs — <...>

## Out of scope
- DO NOT touch X
- DO NOT refactor Y unless directly required

## Existing patterns to follow
- <link or path to similar code already in the repo, if any>
- <or: "this is greenfield — no existing pattern to mirror">

## Acceptance criteria
- [ ] criterion 1
- [ ] criterion 2
- [ ] tests pass
- [ ] formatter clean (`dotnet format` / equivalent)

## Test expectations
<which test project, what new tests, what existing tests must still pass>

## Constraints / context
<anything not in CLAUDE.md that the headless Claude needs to know>
```

The "Existing patterns to follow" section is added because skill-assisted
discovery often surfaces it, and headless Claude benefits enormously from
"mirror this file" guidance vs. inventing a new pattern.

If the local Claude can't fill all sections after exploration, the task is not
ready for Mode #1. The skill's value lies in enforcing this — refuse to delegate
vague tasks. A refusal is a successful skill invocation.

## Deferred decisions (do not re-litigate without new data)

These were considered and explicitly deferred:

- **Superpowers in the runner**: don't install. Use bare Claude + good CLAUDE.md
  for at least the first month. Decide based on metrics whether subagents help.
- **LSP integration in CI**: don't add until metrics show navigation-heavy patterns
  (high turns, lots of file reads). For TypeScript-heavy work, vtsls is the cheapest
  win when needed. C# LSP is fragile in headless mode currently — wait for it to mature.
- **Mode #2 (Copilot)**: deferred. Personal work doesn't need it. Re-evaluate if/when
  building the work-repo variant.
- **Pattern B scheduler (LXC queue service)**: don't build. Pattern A (self-rescheduling
  workflow) is sufficient for personal scale. Reconsider only if personal use grows
  to multiple parallel tasks per day.
- **Plugin marketplace via self-hosted GitLab**: out of scope. Stick with GitHub for this.

## Open questions for the next session

- Exact Ansible role layout for the runner LXC (depends on existing homelab role conventions)
- Whether `agent-workflow` should be public from day 1 or flip later
- Naming: `agent-workflow` vs `ci-claude` vs `claude-actions` — pick one
- Where the `delegate-to-gh` skill lives long-term: in `dotnet-ai-instructions`
  (alongside other personal skills) or in `agent-workflow`? Probably the former.

## Critical constraints — non-negotiable

1. **No self-hosted runner on public repos.** Ever. Pwn-request attack model.
2. **`CLAUDE_CODE_OAUTH_TOKEN` is the auth path for personal use** — uses Max sub
   instead of API billing. Generated via `claude setup-token`, valid one year.
3. **All quotes from sources must be paraphrased** in PRs and issue comments
   (CLAUDE.md should remind headless Claude of this).
4. **Draft PRs by default; promotion allowed only inside ADR-002's safety
   envelope.** The pipeline opens drafts. Promotion to ready + auto-merge
   requires every gate in [DECISIONS.md](DECISIONS.md) ADR-002 to be true;
   otherwise the PR stays draft.
5. **Conventional Commits** for all auto-commits.
6. **Mode #0 is a valid skill outcome.** The skill must support "don't delegate."
7. **Chain dispatch fires only on auto-merge, never on manual merge.** When the
   pipeline auto-merges a PR with `Closes #N`, it walks `#N`'s `Blocks:` markers
   and dispatches any opted-in successor whose `Blocked by:` set just emptied.
   See [DECISIONS.md](DECISIONS.md) ADR-003 for the full conventions
   (`Blocks:` / `Blocked by:` markers, `ai-chain` opt-in, `ai:chain-paused`
   kill-switch issue, depth + visited-set cycle defenses).

## References from the desktop brainstorm

Key design rationale captured in the conversation that produced this doc:

- Why explicit file paths beat module names (3 reasons: cold context, autonomy
  amplifies ambiguity, forces user to verify scope)
- Why the spec quality matters more than the executor choice
- Why self-hosted runners + public repos is the most-attacked GH Actions config
- Why bare Claude beats Superpowers-in-CI as a starting point
- Why testing is layered (lint → script tests → act → sandbox repo → real repo)
- Why path discovery happens in the local skill, not in headless Claude or by
  asking the user — local Claude has the tools (Grep, Glob, Read, optionally LSP)
  and the conversation context to do it well
- Why ripgrep matters for headless runs even though Claude Code's tools "just work"
  with regular grep — the Grep tool prefers rg when present, and the
  gitignore-aware defaults reduce false-positive turns
- Why "negative findings" in spec writing (what was searched but not found) are
  as valuable as positive findings — they prevent headless Claude from
  hallucinating patterns that don't exist

When in doubt, prefer the simpler choice. This pipeline is for a single user;
over-engineering is the failure mode, not under-engineering.
