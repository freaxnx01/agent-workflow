# Consumer Setup

How to wire `claude-pipeline` into a consumer repo. Two flows:

1. **Minimum stub** — labeled-issue → draft PR (no auto-merge).
2. **Auto-review + auto-merge** — labeled-issue → draft PR → agent review → squash-merge, inside ADR-002's safety envelope.

> **Agent selection — two independent mechanisms, don't conflate them:**
>
> - **GitHub-native agents** (Copilot, `anthropic-code-agent`, `openai-code-agent`
>   — GitHub's Agent HQ): steered by **assignee**. You choose the agent by
>   assigning the issue to that bot actor (e.g. the `replaceActorsForAssignable`
>   GraphQL mutation). There is **no label** for this, and these agents run
>   entirely on GitHub's side — they never invoke this pipeline.
> - **This pipeline** (`claude-implement.yml`): steered by **label**
>   (`agent:claude` / `agent:opencode`) or the `agent:` workflow input — the
>   ADR-001 mechanism. It is unrelated to GitHub issue assignment; the pipeline
>   is triggered by the `ai-implement` label, not by assigning a bot.

## Onboarding checklist (operator quick-start)

A repo-agnostic walkthrough for bringing a new consumer online. The numbered
sections below (§1–§4) are the reference detail; this is the order to do them in.
Replace `<owner>/<repo>` with the target consumer repo throughout. For a worked
example see `ai-notes/quicktask-vikunja-pipeline-runbook.md`.

### 0. Pre-flight

- [ ] Decide **public vs private**. Public → GitHub-hosted runners only
      (`'["ubuntu-latest"]'`). **Never attach a self-hosted runner to a public
      repo** — fork-PR attack surface (DESIGN.md, non-negotiable).
- [ ] Confirm the pipeline ref to pin. Use `@v1` once real tags exist; until then
      a `v1` branch on the pipeline repo also resolves for `uses: …@v1`.

### 1. Add the auth secret

The pipeline authenticates Claude via a Max-subscription OAuth token.

- [ ] Generate once on any logged-in Claude Code machine: `claude setup-token`
      (valid ~1 year).
- [ ] Store it as a **repository secret** named exactly `CLAUDE_CODE_OAUTH_TOKEN`.

Set it without the value touching a transcript or shell history. From a secrets
manager (Passbolt example — adjust CLI/field to yours):

```bash
passbolt get resource --id <RESOURCE_ID> --json \
  | jq -r '.password' \
  | gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>
```

Or interactively (paste, then Ctrl-D), then verify:

```bash
gh secret set  CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>
gh secret list -R <owner>/<repo>   # value never displayed
```

Only if using the OpenCode/OpenRouter backend (§3 below): also set
`OPENROUTER_API_KEY`. Skip for the Claude path.

> Secret hygiene: keep the token on the path secrets-manager → your shell →
> GitHub's encrypted store. Don't paste it into files, issues, commits, or an
> agent's chat context. Setting an Actions secret is always a human/CLI step —
> there is no API/MCP tool exposed for it, and a long-lived token shouldn't flow
> through an agent's context anyway.

### 2. Commit the consumer stub

Add `.github/workflows/claude.yml` (§1 below has the full template). Commit it on
a feature branch → PR, not direct to the default branch.

### 3. First run = a trivial smoke test

Validate wiring with a near-zero-risk issue before trusting the pipeline with
path-sensitive work (DESIGN.md). A good smoke test touches only files certain to
be safe (e.g. a new `CONTRIBUTING.md` + a one-line `README.md` link), fences off
source/test/build dirs in an **Out of scope** section, and uses the DESIGN.md
spec template. Create it, then label it **`ai-implement`**.

### 4. Observe, then graduate

Watch the run (§1 below describes the expected draft PR + metrics comment). Only
after several clean draft-only runs, enable auto-merge per §2 — including the
**required vulnerable-dependency check** (ADR-002 gate 5).

### Gotchas (learned in practice)

1. **`pipeline-repo` / `pipeline-ref` MUST be overridden** when the pipeline repo
   isn't `freaxnx01/claude-pipeline`. They default to that name, the cross-repo
   `scripts/` checkout uses them, and `@v1` in `uses:` does **not** propagate to
   that checkout (GitHub's `workflow_ref` points at the caller). Mismatch breaks
   the run at the scripts step.
2. **`v1` may be a branch, not a tag.** `uses:` accepts either; promote to real
   `v1.0.0` + moving `v1` tags when convenient.
3. **Public repos: hosted runners only.** No self-hosted, ever.
4. **First run draft-only.** Don't enable auto-merge until the required vuln
   check is in place and you've watched the pipeline behave on the repo.
5. **Caller needs a `permissions:` block.** Most repos default the workflow
   `GITHUB_TOKEN` to read-only, and a reusable workflow can't be granted more
   than its caller. Omitting `contents`/`pull-requests`/`issues: write` fails the
   run at **`startup_failure`** before any job runs (zero jobs, no logs). See §1.
6. **"Actions can create PRs" must be enabled.** Even draft-only runs need
   *Settings → Actions → General → Workflow permissions → Allow GitHub Actions to
   create and approve pull requests*. Off ⇒ the branch is pushed but `gh pr
   create` fails — and the run may still report **success**, so the absent PR is
   silent. See §1.
7. **The `$X.XX` in the metrics comment is notional under subscription auth.**
   It's Claude Code's reported `total_cost_usd`, computed from token counts ×
   public API list prices regardless of how you authenticated. With a
   `claude setup-token` (Max subscription) token nothing is billed per-token —
   usage counts against subscription limits. Read it as "equivalent API cost".

## 1. Minimum stub

Add `.github/workflows/claude.yml`:

```yaml
name: Claude
on:
  issues:
    types: [labeled]

permissions:            # the reusable jobs need these; a caller can't grant a
  contents: write       # reusable workflow more than it has, and the repo's
  pull-requests: write  # default GITHUB_TOKEN is read-only on most repos, so
  issues: write         # omitting this fails the run at startup (see below)

jobs:
  claude:
    if: github.event.label.name == 'ai-implement'
    uses: freaxnx01/claude-pipeline/.github/workflows/claude-implement.yml@v1
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    with:
      issue-number: ${{ github.event.issue.number }}
      runner-labels: '["ubuntu-latest"]'
      default-model: claude-opus-4-7
```

Drop in:

- `CLAUDE_CODE_OAUTH_TOKEN` secret (generate via `claude setup-token` against your Max subscription).
- Repo labels — the pipeline self-heals these, but a manual `bash scripts/ensure-issue-labels.sh` before the first run keeps the first issue tidy.

### Required repo settings (even for draft-only runs)

These two are needed for the **first** draft-only run — separate from the
auto-merge gate-7 settings in §2:

| Setting | Path | Why |
|---|---|---|
| **Allow GitHub Actions to create and approve pull requests** | Settings → Actions → General → Workflow permissions | The agent opens the draft PR with `gh pr create` using the ambient `GITHUB_TOKEN`. If this is off, the run pushes the branch but `gh pr create` fails with *"GitHub Actions is not permitted to create or approve pull requests"* — and the run can still report **success** (branch + `Closes #N` exist), so the missing PR is easy to miss. Enable via `gh api -X PUT repos/<owner>/<repo>/actions/permissions/workflow -F can_approve_pull_request_reviews=true`. |
| **Caller `permissions:` block** | the stub above | Not a repo setting but the same class of trap: a reusable workflow can't be granted more than its caller, and most repos default the workflow token to read-only. Without the block the run ends in `startup_failure` before any job runs. |

Apply `ai-implement` to an issue; Claude opens a draft PR. That's it.

## 2. Auto-review + auto-merge

The auto-merge flow promotes the draft → ready → `gh pr merge --auto --squash` **only when every gate in [ADR-002](DECISIONS.md#adr-002--auto-review-and-auto-merge-safety-envelope) is satisfied**. Failing any gate leaves the PR draft and stamps `ai:review-blocked` on the originating issue.

> **Auto-merge requires a GitHub App or PAT for PR creation — the ambient
> `GITHUB_TOKEN` is not enough.** GitHub does **not** run workflows on PRs opened
> by `GITHUB_TOKEN` (anti-recursion), so the required vulnerable-dependency check
> (gate 5) never runs and `gh pr merge --auto` waits forever. Create the PR with
> a **GitHub App token or a PAT** instead, and add that bot's login to
> `pipeline-author-allowlist` (the workflow normalizes `app/<name>` ⇄
> `<name>[bot]`, so either spelling matches — see #54). Draft-PR-only (§1) works
> fine with `GITHUB_TOKEN`; only auto-merge needs the App/PAT.

### Enabling the GitHub App for PR creation (#55)

The reusable workflow accepts a GitHub App so the agent opens the PR *as the
App* (triggers required checks; stable bot login). To enable:

1. **Create a GitHub App** — Settings → Developer settings → GitHub Apps → New.
   Repository permissions: **Contents: R/W**, **Pull requests: R/W**,
   **Issues: R/W**. No webhook needed.
2. **Generate a private key** (downloads a `.pem`) and **install the App** on the
   consumer repo.
3. **Add two repo secrets:** `PIPELINE_APP_ID` (the numeric App ID) and
   `PIPELINE_APP_PRIVATE_KEY` (the full `.pem` contents).
4. **Pass them through** in the consumer stub and allowlist the App's bot login
   (`<app-name>[bot]`; the `app/…` ⇄ `…[bot]` normalization makes either work):

   ```yaml
   jobs:
     claude:
       uses: freaxnx01/agent-pipeline/.github/workflows/claude-implement.yml@v1
       with:
         issue-number: ${{ github.event.issue.number }}
         auto-review: true
         pipeline-author-allowlist: my-app[bot]
       secrets:
         CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
         PIPELINE_APP_ID: ${{ secrets.PIPELINE_APP_ID }}
         PIPELINE_APP_PRIVATE_KEY: ${{ secrets.PIPELINE_APP_PRIVATE_KEY }}
   ```

When `PIPELINE_APP_ID` is unset the workflow mints nothing and falls back to
`GITHUB_TOKEN` (the draft-PR-only posture) — so this is a no-op until you opt in.

> ⚠️ **Experimental:** the App-token path is wired and falls back safely, but has
> not yet been verified end-to-end against a real installed App.

### Required GitHub repo settings (gate 7)

Two repo-level toggles **both** must be on, or gate 7 refuses promotion:

| Setting | Path | Default | Why |
|---|---|---|---|
| **Allow squash merging** | Settings → General → Pull Requests | usually on | The promote step calls `gh pr merge --squash`. |
| **Allow auto-merge** | Settings → General → Pull Requests | **off on new repos** | The promote step also passes `--auto`. Without this on, `gh pr merge --auto` fails *after* the draft has already been promoted to ready, leaving the PR in an awkward half-promoted state. Gate 7 verifies it up front. |

### CODEOWNERS (gate 7, optional)

If `.github/CODEOWNERS` (or root `CODEOWNERS`, or `docs/CODEOWNERS` — GitHub's resolution order) exists, gate 7 additionally verifies that every owner of a touched path either is the PR author or has left an `APPROVED` review on the PR.

Caveats:
- **Team owners** (`@org/team`) cannot be resolved without the team-membership API. They're logged as `codeowners-deferred-teams: …` and left to GitHub's native auto-merge to enforce (`gh pr merge --auto` honors CODEOWNERS as a hard requirement).
- **Path matching** uses bash `[[ p == pat ]]` semantics, not gitignore-style globstar. If your CODEOWNERS uses `**` deeply, the matcher may over- or under-match. Stick to simple `*.ext` or `dir/*` patterns for predictable behavior.
- No CODEOWNERS file → this sub-check vacuously passes.

### Opt-in (two layers)

```yaml
# .github/workflows/claude.yml
jobs:
  claude:
    uses: freaxnx01/claude-pipeline/.github/workflows/claude-implement.yml@v1
    with:
      issue-number: ${{ github.event.issue.number }}
      auto-review: true        # per-repo opt-in (ADR-002 gate 3)
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Then apply both `ai-implement` AND `ai-auto-review` to the issue (ADR-002 gate 2). Either alone leaves the PR draft.

### Required: a dependency-vulnerability check

ADR-002 gate 5 ("all required status checks green") is the only thing standing between auto-merge and a supply-chain attack. **Wire a vulnerable-dependency check as a required status check on the target branch.** Pick one that matches your stack:

| Stack | Check |
|---|---|
| Node | `npm audit --audit-level=high` step or Dependabot's review action |
| Python | `pip-audit --strict` |
| .NET | `dotnet list package --vulnerable --include-transitive` (fails build on findings) |
| Rust | `cargo audit` |
| Go | `govulncheck ./...` |

Mark it required under **Settings → Branches → Branch protection → Require status checks**.

If no such check is required, `auto-review: true` lets a malicious dependency bump squash-merge into `main`. The pipeline does not block manifest changes itself — gate 6 only blocks `.github/` and secret files (full list in ADR-002 §2.6).

### Optional: per-repo path blocklist

Drop a `.claude-auto-merge-blocklist` at the repo root, one glob per line, `#` for comments:

```
# Don't auto-merge infra or DB changes
terraform/**
migrations/**
*.tf
```

Absent file = empty blocklist. The hardcoded list (`.github/`, `*.sops.yaml`, `*.enc.*`, `*.age`, `*.gpg`, `*.pem`, `*.key`, `*.kbx`, `*.p12`, `*.pfx`, `secrets.*`) is always in effect — the blocklist file extends it, never weakens it.

### Optional: custom pipeline author allowlist

If your consumer repo uses a GitHub App or PAT for `gh pr create` instead of the ambient `GITHUB_TOKEN`, the PRs appear as a different `pr.user.login`. Add it to the allowlist (ADR-002 gate 1):

```yaml
with:
  auto-review: true
  pipeline-author-allowlist: |
    github-actions[bot]
    my-app[bot]
```

Never set this to a value that matches arbitrary humans — gate 1's purpose is defense in depth against label injection.

### Kill switches

- **Per-repo:** `auto-review: false` at the call site.
- **Per-issue:** remove `ai-auto-review` from the issue.

Both only take effect on the next run; PRs that already armed `gh pr merge --auto` will still land once required checks pass. Disarm in-flight with `gh pr merge --disable-auto <PR>`.

## 3. Using OpenCode via OpenRouter (optional)

The pipeline supports a second agent backend besides Claude Code — [OpenCode](https://github.com/opencode-ai/opencode) talking to [OpenRouter](https://openrouter.ai) (Mistral models are the obvious first stop, but any model on OpenRouter works). Per ADR-001, the result-shape contract is identical to the Claude path, so downstream scripts don't branch on agent identity.

### Opt-in

Choose the agent at the call site or per-issue:

```yaml
# .github/workflows/claude.yml
jobs:
  claude:
    uses: freaxnx01/claude-pipeline/.github/workflows/claude-implement.yml@v1
    with:
      issue-number: ${{ github.event.issue.number }}
      agent: opencode             # ← workflow-input default for this repo
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
```

Per-issue override: apply the `agent:opencode` (or `agent:claude`) label on the issue. Label wins over the workflow input.

### Mint the OpenRouter key

1. Create an account at https://openrouter.ai.
2. Top up credits or attach billing per their docs.
3. Settings → Keys → "Create Key". Scope it to a single model family if you want a tighter blast radius.
4. **Repo secret**: Settings → Secrets and variables → Actions → New repository secret. Name: `OPENROUTER_API_KEY`. Paste the value.

### Security notes

- The secret is declared `required: false` at the workflow boundary; consumers that never set `agent: opencode` don't need to provide it.
- Inside the runner, the OpenCode step (added in #10) reads it via `${{ secrets.OPENROUTER_API_KEY }}`. The value is never logged: `set +x` is applied around any line that interpolates it, and the GitHub Actions runtime auto-masks secret values in log output by default.
- The same `ai-auto-review` opt-in (§2) and chain semantics (§4 — below) apply regardless of which agent ran the implementation.

### What's left (multi-agent epic)

Wiring the secret is just the first piece. The OpenCode CLI install (#8), classifier (#9), runner step (#10), and act fixtures (#11) land next. Until #10 merges, setting `agent: opencode` produces a no-op job per the workflow input docstring.

## 4. Issue chaining (optional, requires auto-review)

When an auto-merged PR closes an issue, the pipeline can dispatch a follow-up issue that was `Blocked by:` it. Conventions live in [ADR-003](DECISIONS.md#adr-003--issue-chain-dispatch-on-auto-merge); this section is just the wiring.

### Consumer-side trigger stub

Add `.github/workflows/chain-dispatch.yml` to the consumer repo (alongside the `claude.yml` stub from §1):

```yaml
name: Chain-dispatch on merged ai-implement PR
on:
  pull_request:
    types: [closed]

permissions:
  issues: read
  pull-requests: read
  actions: write

jobs:
  chain:
    if: |
      github.event.pull_request.merged == true
      && contains(github.event.pull_request.labels.*.name, 'ai-implement')
    uses: freaxnx01/claude-pipeline/.github/workflows/chain-dispatch.yml@v1
    with:
      closed-pr-number: ${{ github.event.pull_request.number }}
      # `target-workflow` defaults to claude.yml — override if your
      # consumer pipeline stub lives under a different filename.
    secrets:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### File issues with chain markers

In each chained issue's body, declare dependencies using GitHub's native convention:

```
Blocks: #101
Blocked by: #100
```

Then label each chained issue with **both** `ai-implement` and `ai-chain`. Label the *first* one only with `ai-implement` initially (or also with `ai-chain` — the dispatcher adds `ai-implement` to opted-in successors automatically).

Dispatch the first issue. The pipeline implements + auto-merges it (subject to all ADR-002 gates). On merge, the chain-dispatch workflow fires, finds the next eligible issue, and dispatches it. The chain walks to completion.

### Kill switch

Open an issue **titled exactly** `ai:chain-paused`. The dispatcher checks for this title before each step and refuses to dispatch while it's open. Close the issue to lift the pause.

### Out of scope (today)

- **Cross-repo dependencies.** `Blocks: org/other-repo#42` is parsed but ignored.
- **Cycle / depth caps.** Coming in #19. Until then, file shallow chains and watch the chain-state issue.
- **Manual merges don't trigger the chain** — by design. A human who steps in mid-chain takes over the rest.

## Troubleshooting

### "Auto-merge held: …" comment on the PR

The auto-review job ran, but a gate refused promotion. The comment names the reason. The originating issue gets `ai:review-blocked`. Take over manually: review the diff, fix any blocker, then `gh pr ready` + `gh pr merge --squash` yourself.

### Draft PR opens but no auto-review job runs

Check the workflow run for the `auto_review` job. It only triggers when:

- the `implement` job succeeded
- `auto-review: true` was passed
- the issue carries `ai-auto-review`
- the `implement` job's `auto-review-enabled` output is `true`

If all four hold and the job still didn't run, the issue is in workflow plumbing — file an issue against `claude-pipeline`.

### Self-modification guard

The `freaxnx01/claude-pipeline` repo itself never auto-merges, regardless of input or label state — ADR-002 §"Self-modification / dogfooding". Hardcoded; no way to disable. If you forked `claude-pipeline`, update the guard's hardcoded repo string before enabling `auto-review: true` on the fork.
