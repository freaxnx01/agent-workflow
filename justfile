# agent-pipeline recipes. Run `just` with no args to list them.
# Recipe bodies are project-specific; names follow the CI/automation stack overlay.

# List available recipes
default:
    @just --list --unsorted

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
