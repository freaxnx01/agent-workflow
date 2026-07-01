#!/usr/bin/env bash
#
# onboard-consumer.sh — Bring a consumer repo onto the agent-pipeline in one
# command. Automates the §0–§4 checklist in docs/CONSUMER-SETUP.md:
#
#   1. Pre-flight   — resolve repo visibility + default branch; refuse to wire
#                     self-hosted runners onto a public repo (DESIGN.md).
#   2. Auth secret  — set CLAUDE_CODE_OAUTH_TOKEN (and optionally
#                     OPENROUTER_API_KEY) as a repo OR org secret. The value is
#                     read from a command or stdin and never echoed.
#   3. Labels       — run ensure-issue-labels.sh against the target repo.
#   4. Repo settings— enable "Actions can create PRs"; for --auto-review also
#                     enable allow-auto-merge + allow-squash-merge.
#   5. Consumer stub— commit .github/workflows/agent.yml (and chain-dispatch.yml
#                     with --chain) on a branch and open a PR — via the GitHub
#                     API, no local clone required. Idempotent.
#
# This is HUMAN-INVOKED operator tooling, so it is flag-driven (unlike the
# env-driven CI scripts in this repo).
#
# Usage:
#   onboard-consumer.sh -R <owner>/<repo> [options]
#
# Required:
#   -R, --repo <owner/repo>     Target consumer repo.
#
# Auth secret source (pick one, or --no-secret to skip):
#       --secret-cmd '<cmd>'    Command whose stdout is the Claude token
#                               (e.g. 'passbolt get resource --id X --json | jq -r .password').
#       --secret-stdin          Read the Claude token from this script's stdin.
#       --no-secret             Skip setting CLAUDE_CODE_OAUTH_TOKEN.
#       --openrouter-cmd '<cmd>' Command whose stdout is the OpenRouter key
#                               (only needed for the opencode agent).
#
# Secret scope (default: repo):
#       --secret-scope repo|org Where to store the secret(s). Default 'repo'.
#       --org <name>            Org for --secret-scope org. Default: repo owner.
#       --secret-visibility all|private|selected
#                               Org-secret visibility. Default 'selected' — the
#                               tightest option, so colleagues' repos cannot use
#                               the token. See the SECURITY note below.
#       --secret-repos r1,r2    Repos the org secret is scoped to when
#                               visibility=selected. Default: just the target repo.
#
# Pipeline wiring:
#       --ref <ref>             Pipeline ref to pin in `uses:` / `pipeline-ref:`.
#                               Default 'v1'.
#       --agent claude|opencode Default agent for the stub. Default 'claude'.
#       --model <model>         default-model input. Default 'claude-opus-4-7'.
#       --runner-labels '<json>' JSON array of runner labels.
#                               Default '["ubuntu-latest"]'.
#       --auto-review           Wire auto-review: true and enable the repo
#                               settings auto-merge needs (ADR-002 gate 7).
#       --chain                 Also commit chain-dispatch.yml (ADR-003).
#       --no-stub               Skip the PR; do secret + labels + settings only.
#       --no-settings           Skip repo-settings changes.
#       --branch <name>         Branch for the stub PR.
#                               Default 'chore/onboard-agent-pipeline'.
#       --dry-run               Print what would happen; make no changes.
#
# SECURITY — "the token should be usable only by me, not my colleagues":
#   A GitHub Actions secret is usable by anyone who can cause a workflow with
#   access to it to run with content they control. Scoping an ORG secret to
#   `selected` repos limits *which repos'* workflows can read it — but on each
#   of those repos, anyone with push/merge rights to `.github/workflows/**` can
#   still exfiltrate it. So "only me" means: scope to selected repos AND lock
#   workflow changes on those repos (branch protection + CODEOWNERS on
#   `.github/workflows/**` requiring your review). This script sets the tight
#   scope; it cannot enforce the branch protection for you.
#
# Exit codes:
#   0   success
#   1   a step failed (gh/network/permission)
#   2   usage error
#   3   refused: unsafe combination (e.g. self-hosted runner on a public repo)
set -euo pipefail
IFS=$'\n\t'

# ---- defaults --------------------------------------------------------------
REPO=''
SECRET_CMD=''
SECRET_STDIN=false
NO_SECRET=false
OPENROUTER_CMD=''
SECRET_SCOPE='repo'
ORG=''
SECRET_VISIBILITY='selected'
SECRET_REPOS=''
REF='v1'
AGENT='claude'
MODEL='claude-sonnet-5'
RUNNER_LABELS='["ubuntu-latest"]'
AUTO_REVIEW=false
CHAIN=false
NO_STUB=false
NO_SETTINGS=false
BRANCH='chore/onboard-agent-pipeline'
DRY_RUN=false

PIPELINE_REPO='freaxnx01/agent-pipeline'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- helpers ---------------------------------------------------------------
# Diagnostics go to stderr so they survive a caller's stdout redirect
# (e.g. `run gh api ... >/dev/null`) and never pollute data output.
err()  { printf 'error: %s\n' "$*" >&2; }
info() { printf '==> %s\n' "$*" >&2; }
usage_error() { err "$*"; printf 'run with --help for usage\n' >&2; exit 2; }

run() {
  # Echo + execute, honouring --dry-run. Never used for secret values.
  if [[ "$DRY_RUN" == true ]]; then
    local joined
    printf -v joined ' %s' "$@"   # space-join regardless of IFS=$'\n\t'
    printf '[dry-run]%s\n' "$joined" >&2
    return 0
  fi
  "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "required command not found: $1"; exit 1; }
}

# ---- arg parsing -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R|--repo)            REPO="${2:?}"; shift 2 ;;
    --secret-cmd)         SECRET_CMD="${2:?}"; shift 2 ;;
    --secret-stdin)       SECRET_STDIN=true; shift ;;
    --no-secret)          NO_SECRET=true; shift ;;
    --openrouter-cmd)     OPENROUTER_CMD="${2:?}"; shift 2 ;;
    --secret-scope)       SECRET_SCOPE="${2:?}"; shift 2 ;;
    --org)                ORG="${2:?}"; shift 2 ;;
    --secret-visibility)  SECRET_VISIBILITY="${2:?}"; shift 2 ;;
    --secret-repos)       SECRET_REPOS="${2:?}"; shift 2 ;;
    --ref)                REF="${2:?}"; shift 2 ;;
    --agent)              AGENT="${2:?}"; shift 2 ;;
    --model)              MODEL="${2:?}"; shift 2 ;;
    --runner-labels)      RUNNER_LABELS="${2:?}"; shift 2 ;;
    --auto-review)        AUTO_REVIEW=true; shift ;;
    --chain)              CHAIN=true; shift ;;
    --no-stub)            NO_STUB=true; shift ;;
    --no-settings)        NO_SETTINGS=true; shift ;;
    --branch)             BRANCH="${2:?}"; shift 2 ;;
    --dry-run)            DRY_RUN=true; shift ;;
    -h|--help)            sed -n '2,90p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                    usage_error "unknown argument: $1" ;;
  esac
done

# ---- validation (fail fast) ------------------------------------------------
require_cmd gh
require_cmd jq

[[ -n "$REPO" ]]            || usage_error "--repo is required"
[[ "$REPO" == */* ]]       || usage_error "--repo must be owner/repo (got: $REPO)"
[[ "$AGENT" == claude || "$AGENT" == opencode ]] \
                           || usage_error "--agent must be claude|opencode (got: $AGENT)"
[[ "$SECRET_SCOPE" == repo || "$SECRET_SCOPE" == org ]] \
                           || usage_error "--secret-scope must be repo|org (got: $SECRET_SCOPE)"

if [[ "$NO_SECRET" == false ]]; then
  local_sources=0
  [[ -n "$SECRET_CMD" ]] && local_sources=$((local_sources + 1))
  [[ "$SECRET_STDIN" == true ]] && local_sources=$((local_sources + 1))
  [[ "$local_sources" -eq 1 ]] \
    || usage_error "provide exactly one of --secret-cmd / --secret-stdin (or --no-secret)"
fi

OWNER="${REPO%%/*}"
[[ -n "$ORG" ]] || ORG="$OWNER"
[[ -n "$SECRET_REPOS" ]] || SECRET_REPOS="$REPO"

# ===========================================================================
# 1. Pre-flight
# ===========================================================================
info "Pre-flight: inspecting $REPO"
repo_json="$(gh repo view "$REPO" --json visibility,defaultBranchRef,isPrivate 2>/dev/null)" \
  || { err "cannot read $REPO — check the name and your gh auth"; exit 1; }

VISIBILITY="$(jq -r '.visibility' <<<"$repo_json")"
DEFAULT_BRANCH="$(jq -r '.defaultBranchRef.name' <<<"$repo_json")"
info "visibility=$VISIBILITY default-branch=$DEFAULT_BRANCH"

# Guard: never wire self-hosted runners onto a public repo (DESIGN.md).
if [[ "$VISIBILITY" == "public" && "$RUNNER_LABELS" == *self-hosted* ]]; then
  err "refusing: self-hosted runner labels on a PUBLIC repo are a fork-PR attack surface"
  err "public repos must use GitHub-hosted runners (e.g. '[\"ubuntu-latest\"]')"
  exit 3
fi

# ===========================================================================
# 2. Auth secret(s)
# ===========================================================================
set_secret() {
  # set_secret <NAME> <value-on-stdin>. Value never appears in argv/logs.
  local name="$1"
  if [[ "$DRY_RUN" == true ]]; then
    cat >/dev/null   # drain the piped value
    printf '[dry-run] gh secret set %s (scope=%s)\n' "$name" "$SECRET_SCOPE" >&2
    return 0
  fi
  if [[ "$SECRET_SCOPE" == org ]]; then
    if [[ "$SECRET_VISIBILITY" == selected ]]; then
      gh secret set "$name" --org "$ORG" \
        --visibility selected --repos "$SECRET_REPOS"
    else
      gh secret set "$name" --org "$ORG" --visibility "$SECRET_VISIBILITY"
    fi
  else
    gh secret set "$name" --repo "$REPO"
  fi
}

if [[ "$NO_SECRET" == true ]]; then
  info "Skipping CLAUDE_CODE_OAUTH_TOKEN (--no-secret)"
else
  info "Setting CLAUDE_CODE_OAUTH_TOKEN (scope=$SECRET_SCOPE)"
  if [[ "$SECRET_STDIN" == true ]]; then
    info "reading token from stdin (paste, then Ctrl-D)"
    set_secret CLAUDE_CODE_OAUTH_TOKEN
  else
    # Run the source command in a subshell; its stdout pipes straight into gh.
    bash -c "$SECRET_CMD" | set_secret CLAUDE_CODE_OAUTH_TOKEN
  fi
fi

if [[ -n "$OPENROUTER_CMD" ]]; then
  info "Setting OPENROUTER_API_KEY (scope=$SECRET_SCOPE)"
  bash -c "$OPENROUTER_CMD" | set_secret OPENROUTER_API_KEY
fi

# ===========================================================================
# 3. Labels
# ===========================================================================
info "Ensuring pipeline labels on $REPO"
if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] REPO=%s %s/ensure-issue-labels.sh\n' "$REPO" "$SCRIPT_DIR" >&2
else
  REPO="$REPO" bash "$SCRIPT_DIR/ensure-issue-labels.sh"
fi

# ===========================================================================
# 4. Repo settings
# ===========================================================================
if [[ "$NO_SETTINGS" == true ]]; then
  info "Skipping repo settings (--no-settings)"
else
  info "Enabling 'Allow GitHub Actions to create and approve pull requests'"
  run gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
    -F can_approve_pull_request_reviews=true >/dev/null

  if [[ "$AUTO_REVIEW" == true ]]; then
    info "Enabling allow-auto-merge + allow-squash-merge (ADR-002 gate 7)"
    run gh api -X PATCH "repos/$REPO" \
      -F allow_auto_merge=true -F allow_squash_merge=true >/dev/null
  fi
fi

# ===========================================================================
# 5. Consumer stub PR
# ===========================================================================
build_agent_yml() {
  local secrets_block with_block
  secrets_block=$'      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}'
  if [[ "$AGENT" == opencode ]]; then
    secrets_block+=$'\n      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}'
  fi

  with_block=$'      issue-number: ${{ github.event.issue.number }}'
  with_block+=$'\n      runner-labels: '"'$RUNNER_LABELS'"
  with_block+=$'\n      default-model: '"$MODEL"
  with_block+=$'\n      pipeline-ref: '"$REF"
  [[ "$AGENT" == opencode ]] && with_block+=$'\n      agent: opencode'
  [[ "$AUTO_REVIEW" == true ]] && with_block+=$'\n      auto-review: true'

  cat <<YAML
name: Claude
on:
  issues:
    types: [labeled]

permissions:            # a reusable workflow can't be granted more than its
  contents: write       # caller; the repo's default GITHUB_TOKEN is read-only,
  pull-requests: write  # so omitting this fails the run at startup_failure.
  issues: write

jobs:
  claude:
    if: github.event.label.name == 'ai-implement'
    uses: $PIPELINE_REPO/.github/workflows/agent-implement.yml@$REF
    secrets:
$secrets_block
    with:
$with_block
YAML
}

build_chain_yml() {
  cat <<YAML
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
    uses: $PIPELINE_REPO/.github/workflows/chain-dispatch.yml@$REF
    with:
      closed-pr-number: \${{ github.event.pull_request.number }}
      pipeline-ref: $REF
    secrets:
      GH_TOKEN: \${{ secrets.GITHUB_TOKEN }}
YAML
}

ensure_branch() {
  # Create $BRANCH off $DEFAULT_BRANCH if it doesn't already exist.
  if gh api "repos/$REPO/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
    info "branch $BRANCH already exists — reusing"
    return 0
  fi
  local base_sha
  base_sha="$(gh api "repos/$REPO/git/ref/heads/$DEFAULT_BRANCH" --jq '.object.sha')"
  run gh api -X POST "repos/$REPO/git/refs" \
    -f "ref=refs/heads/$BRANCH" -f "sha=$base_sha" >/dev/null
}

put_file() {
  # put_file <path> <commit-message>; content on stdin. Create-or-update.
  local path="$1" message="$2" content_b64 existing_sha payload
  content_b64="$(base64 | tr -d '\n')"
  existing_sha="$(gh api "repos/$REPO/contents/$path?ref=$BRANCH" --jq '.sha' 2>/dev/null || true)"

  payload="$(jq -n \
    --arg message "$message" --arg content "$content_b64" \
    --arg branch "$BRANCH" --arg sha "$existing_sha" \
    'if $sha == "" then {message:$message, content:$content, branch:$branch}
     else {message:$message, content:$content, branch:$branch, sha:$sha} end')"

  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] PUT repos/%s/contents/%s on %s\n' "$REPO" "$path" "$BRANCH" >&2
    return 0
  fi
  printf '%s' "$payload" | gh api -X PUT "repos/$REPO/contents/$path" --input - >/dev/null
}

open_pr() {
  local title="$1"
  if gh pr view "$BRANCH" --repo "$REPO" >/dev/null 2>&1; then
    info "PR for $BRANCH already open — leaving as-is"
    return 0
  fi
  run gh pr create --repo "$REPO" --base "$DEFAULT_BRANCH" --head "$BRANCH" \
    --title "$title" \
    --body "Wires this repo onto \`$PIPELINE_REPO\` (\`$REF\`). Generated by \`scripts/onboard-consumer.sh\`. Review, then merge; label an issue \`ai-implement\` to start." \
    >/dev/null
}

if [[ "$NO_STUB" == true ]]; then
  info "Skipping consumer stub PR (--no-stub)"
else
  info "Committing consumer stub on branch $BRANCH"
  ensure_branch
  build_agent_yml | put_file ".github/workflows/agent.yml" \
    "ci(agent-pipeline): add consumer stub"
  if [[ "$CHAIN" == true ]]; then
    build_chain_yml | put_file ".github/workflows/chain-dispatch.yml" \
      "ci(agent-pipeline): add chain-dispatch stub"
  fi
  open_pr "ci: onboard onto agent-pipeline"
fi

info "Done. Next: review the PR, merge it, then label a smoke-test issue 'ai-implement'."
