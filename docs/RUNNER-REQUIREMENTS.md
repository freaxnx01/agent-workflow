# Runner Requirements

Tools the pipeline expects on the runner. `scripts/ensure-toolchain.sh` installs the missing ones at job start.

## Always required

| Tool | Default source | Why |
|---|---|---|
| `rg` (ripgrep) | apt: `ripgrep` | Claude Code's Grep tool prefers it; faster + gitignore-aware |
| `jq` | apt: `jq` | Used by `post-run-report.sh`, `classify-failure.sh`, `find-next-blocked-issue.sh` |
| `gh` | apt: `gh` (pre-installed on `ubuntu-latest`) | Every issue/PR/label operation |
| `curl` | apt: `curl` | Fetches the agent CLI installers (`scripts/install-claude-cli.sh`, `scripts/install-opencode.sh`) |
| `sha256sum` | apt: `coreutils` | Verifies the pinned checksum of those installers before either is executed |

Pre-installed on `ubuntu-latest` — `ensure-toolchain.sh` is a no-op there in practice. Self-hosted runners must have these baked in via the Ansible role (see homelab repo).

## Conditionally required (per-agent)

### When `AGENT=opencode`

| Tool | Pinned version | Source |
|---|---|---|
| `opencode` | **1.15.13** | native installer (`scripts/install-opencode.sh`, checksum-pinned) |

The version pin lives in `scripts/ensure-toolchain.sh` at the top (`OPENCODE_VERSION`). Bump in one place; this doc and the script must agree.

`ensure-toolchain.sh` skips the OpenCode install entirely when `AGENT` is unset or `claude` — Claude-only consumers pay zero cost for the multi-agent feature.

Both agents install via a checksum-pinned native installer, so **no pipeline
path requires Node.js or npm**. Their shared prerequisites are `curl` and
`sha256sum`, listed under *Always required* above.

The installer lands the binary in the per-user `$HOME/.opencode/bin` and appends that directory to `$GITHUB_PATH`, so it is on `PATH` for subsequent steps — never in a global prefix shared across jobs on a persistent runner.

### When `AGENT=claude`

| Tool | Source |
|---|---|
| `claude` (Claude Code CLI) | Installed by `anthropics/claude-code-base-action` in the `implement` job, and by `scripts/install-claude-cli.sh` (native installer — requires `curl` + `sha256sum`) in the review and self-fix jobs |

## Provisioning self-hosted runners

If/when self-hosted runners are added (see ADR-001 caveat — public repos must stay on `ubuntu-latest`), the homelab Ansible role (`roles/github-actions-runner/`) is the source of truth for the toolchain. The role's `defaults/main.yml` should list:

```yaml
github_actions_runner_packages:
  - ripgrep
  - jq
  - gh
```

…and provision via `apt`. `ensure-toolchain.sh` does the per-run `command -v` check anyway, so this is belt-and-suspenders.
