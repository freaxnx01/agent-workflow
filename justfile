# agent-pipeline recipes. Run `just` with no args to list them.
# Recipe bodies are project-specific; the names follow the CI/automation stack overlay.

# List available recipes
default:
    @just --list --unsorted

# === Quality =================================================================

# actionlint + shellcheck on workflows and scripts (Layer 0)
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    actionlint -color
    mapfile -t files < <(find scripts tests -type f -name '*.sh' 2>/dev/null | sort)
    if [[ ${#files[@]} -gt 0 ]]; then shellcheck -x -e SC1091 "${files[@]}"; else echo "no shell scripts"; fi

# Layer-1 fixture tests (no network, runs in seconds)
test:
    bash tests/run-script-tests.sh

# Layer-2: run the *.test.yml workflows under act (needs `act` + Docker; Linux only)
test-act:
    act -W .github/workflows/agent-implement.test.yml workflow_dispatch
    act -W .github/workflows/chain-dispatch.test.yml  workflow_dispatch

# Format shell scripts in place (needs `shfmt`)
format:
    shfmt -w scripts tests

# === Local development =======================================================

# Regenerate test fixtures from a known-good real run — manual, intentional only
fixtures-update:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Manual step (no automated generator — fixtures are curated by hand):"
    echo "  1. Capture a known-good run's canonical result into tests/fixtures/<scenario>.json"
    echo "  2. Run 'just test' and confirm the new/updated branch is covered"
    echo "  3. Commit the fixture in the same PR as the code that produced the new branch"

# Preview the pending [Unreleased] changelog section to stdout (non-destructive)
changelog:
    git-cliff --unreleased

# Generate / verify docs (currently: the changelog)
docs: changelog

# === Release =================================================================
# Single source of truth for the version is the ./VERSION file. Typical flow:
#   just bump-minor && just release && just push-release
# Tags are cut on `main` after merge (see CLAUDE.md → Versioning).

# Print the current version
version:
    @cat VERSION

# Set the version explicitly, e.g. `just version-set 1.5.0`
version-set ver:
    @printf '%s\n' "{{ver}}" > VERSION && echo "version → {{ver}}"

# Bump the major component (X.0.0) in VERSION — no commit, no tag
bump-major:
    #!/usr/bin/env bash
    set -euo pipefail
    IFS=. read -r ma _ _ < VERSION
    v="$((ma + 1)).0.0"; printf '%s\n' "$v" > VERSION; echo "version → $v"

# Bump the minor component (x.Y.0) in VERSION — no commit, no tag
bump-minor:
    #!/usr/bin/env bash
    set -euo pipefail
    IFS=. read -r ma mi _ < VERSION
    v="${ma}.$((mi + 1)).0"; printf '%s\n' "$v" > VERSION; echo "version → $v"

# Bump the patch component (x.y.Z) in VERSION — no commit, no tag
bump-patch:
    #!/usr/bin/env bash
    set -euo pipefail
    IFS=. read -r ma mi pa < VERSION
    v="${ma}.${mi}.$((pa + 1))"; printf '%s\n' "$v" > VERSION; echo "version → $v"

# Bump VERSION to the version implied by conventional commits (needs `git-cliff`)
bump-auto:
    #!/usr/bin/env bash
    set -euo pipefail
    v="$(git-cliff --bumped-version | sed 's/^v//')"
    printf '%s\n' "$v" > VERSION; echo "version → $v"

# Cut a release locally: regenerate changelog, commit, tag vX.Y.Z — does NOT push
release:
    #!/usr/bin/env bash
    set -euo pipefail
    v="$(cat VERSION)"
    if git rev-parse "v$v" >/dev/null 2>&1; then
      echo "tag v$v already exists — bump first (just bump-minor / bump-patch)"; exit 1
    fi
    git-cliff --tag "v$v" --unreleased --prepend CHANGELOG.md
    git add CHANGELOG.md VERSION
    git commit -m "chore(release): v$v"
    git tag -a "v$v" -m "v$v"
    echo "tagged v$v (not pushed) — run 'just push-release' when ready"

# Push the release commit + tag to origin/main
push-release:
    #!/usr/bin/env bash
    set -euo pipefail
    v="$(cat VERSION)"
    git push origin main "v$v"

# === Cleanup =================================================================

# Remove generated artifacts
clean:
    rm -rf .act coverage

# === Onboarding ==============================================================

# Pass the repo as owner/repo, then any onboard-consumer.sh flags after it:
#   just onboard freaxnx01/bridge --no-secret
#   just onboard freaxnx01/bridge --secret-cmd 'pass show claude/oauth' --auto-review
# Auth: the script's gh calls use the ambient credential. For a repo whose owner
# differs from your default login, run under that owner's credential, e.g.
#   direnv exec ~/repos/github/freaxnx01 just onboard freaxnx01/bridge --no-secret
# Full flag list: `just onboard-help`.
# Onboard a consumer repo onto agent-pipeline (wraps scripts/onboard-consumer.sh)
onboard repo *args:
    bash {{justfile_directory()}}/scripts/onboard-consumer.sh -R {{repo}} {{args}}

# Print onboard-consumer.sh usage / all flags
onboard-help:
    @bash {{justfile_directory()}}/scripts/onboard-consumer.sh --help
