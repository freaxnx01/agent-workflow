#!/usr/bin/env bash
#
# opencode-model-config.sh — Print the opencode config that makes one
# OpenRouter model id resolvable (#518).
#
# opencode resolves `--model openrouter/<id>` against a catalog it never waits
# for: on a cold cache (every GitHub-hosted runner) it starts from a snapshot
# compiled into the binary and refreshes in the background, so an id newer than
# the pinned binary resolves only when a 5.4 MB download wins a race against
# startup. Declaring the id in config takes the catalog out of resolution:
# opencode accepts any id listed under `provider.openrouter.models`.
#
# Callers export the output as OPENCODE_CONFIG_CONTENT for the opencode
# process. No file is written, so nothing lands in the agent's checkout.
#
# The entry is deliberately empty: cost and limits come from the catalog when
# it is loaded, and the pipeline holds no per-model metadata — adding a model
# must not need a pipeline change.
#
# Required environment variables:
#   MODEL  OpenRouter model id, with or without a leading `openrouter/`.
#
# Output (stdout): one line of JSON.
#
# Exit codes:
#   0   config printed
#   2   MODEL missing
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${MODEL:-}" ]]; then
  printf 'error: MODEL must be set\n' >&2
  exit 2
fi

jq -nc --arg id "${MODEL#openrouter/}" \
  '{provider: {openrouter: {models: {($id): {}}}}}'
