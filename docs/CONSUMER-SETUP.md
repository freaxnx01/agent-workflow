# Consumer Setup

How to wire `claude-pipeline` into a consumer repo. Two flows:

1. **Minimum stub** — labeled-issue → draft PR (no auto-merge).
2. **Auto-review + auto-merge** — labeled-issue → draft PR → agent review → squash-merge, inside ADR-002's safety envelope.

## 1. Minimum stub

Add `.github/workflows/claude.yml`:

```yaml
name: Claude
on:
  issues:
    types: [labeled]

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

Apply `ai-implement` to an issue; Claude opens a draft PR. That's it.

## 2. Auto-review + auto-merge

The auto-merge flow promotes the draft → ready → `gh pr merge --auto --squash` **only when every gate in [ADR-002](DECISIONS.md#adr-002--auto-review-and-auto-merge-safety-envelope) is satisfied**. Failing any gate leaves the PR draft and stamps `ai:review-blocked` on the originating issue.

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

## 3. Issue chaining (optional, requires auto-review)

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
