#!/usr/bin/env bash
#
# azdo.sh — sourced, not executed.
#
# Azure DevOps query primitives shared by every command's `## Azure DevOps`
# section. The recipe is ~150 lines of prompt in commands/issues.md; putting it
# in twelve more markdown files would duplicate it twelve times, and the live
# run behind #386 found five defects in the single existing copy, four of them
# silent. Here a fix lands once.
#
# Lives beside detect-forge.sh, which every command already sources. Requires
# AZDO_ORG / AZDO_PROJECT / AZDO_REPO — set those with resolve_azdo_context.
#
#   azdo_org_url        echoes https://dev.azure.com/<org>
#   azdo_closed_states  echoes "'A','B'" — the project's closed state names
#   azdo_wiql <query>   echoes matching work-item ids, one per line
#
# Exit codes:
#   0  success, including a query that legitimately matched nothing
#   1  error (the underlying az stderr is passed through)
#   2  the Area Path in the query does not exist (TF51011)
#
# Callers must CAPTURE the status rather than calling bare. Sourcing this file
# applies `set -e` to the caller (as detect-forge.sh already does), so a bare
# `azdo_wiql ...` kills the shell on exit 2 before the caller can distinguish it
# from an empty result -- which is the entire point of that exit code. Use:
#
#   rc=0; ids=$(azdo_wiql "$q") || rc=$?
#   case $rc in
#     0) ;;                                   # rows, or a legitimate none
#     2) echo "no Area Path matching $AZDO_REPO" >&2 ;;
#     *) exit 1 ;;
#   esac
#
# Every shape here was verified against live organizations; see
# docs/ai-notes/2026-09-22-ado-manual-test-run.md.
set -euo pipefail
IFS=$'\n\t'

azdo_org_url() {
  : "${AZDO_ORG:?AZDO_ORG must be set — call resolve_azdo_context first}"
  printf 'https://dev.azure.com/%s' "$AZDO_ORG"
}

# azdo_closed_states  echoes "'Closed','Completed','Done'" — ready to interpolate
# into a WIQL `NOT IN (...)`.
#
# Read the states, never write them down. State NAMES are set by the project's
# process template and differ between them — a Basic project has Done, an
# Agile-derived one does not — while the CATEGORIES are template-independent.
# So key on the category: Completed and Removed are the ones that mean "not
# open". A fixed list is wrong somewhere, always.
azdo_closed_states() {
  : "${AZDO_PROJECT:?AZDO_PROJECT must be set — call resolve_azdo_context first}"
  az devops invoke --org "$(azdo_org_url)" --area wit --resource workitemtypes \
    --route-parameters project="$AZDO_PROJECT" \
    --api-version 7.1 --output json --only-show-errors \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
closed = sorted({s["name"] for t in d.get("value", [])
                 for s in t.get("states", [])
                 if s.get("category") in ("Completed", "Removed")})
print(",".join("%s%s%s" % ("'"'"'", c, "'"'"'") for c in closed))'
}

# azdo_wiql <query>  echoes the matching work-item ids, one per line.
#
# Two things this exists to get right:
#
# 1. `az boards query` is unusable. It exits 0 and prints NOTHING AT ALL -- not
#    `[]`, zero bytes -- in every output format, reproduced against two
#    organizations and three projects, while the identical WIQL through
#    `az devops invoke` returns rows. Do not "simplify" this back to it.
# 2. A missing Area Path does not return zero rows, it ERRORS with TF51011.
#    That gets exit 2, because an empty result is also this command's
#    legitimate "nothing is open" answer and the caller must be able to tell
#    them apart.
#
# The body is built with python3 rather than string-interpolated: a WIQL query
# carries both single quotes and backslashes, and hand-quoting it into JSON is
# exactly where the escaping breaks.
azdo_wiql() {
  local query="${1:?azdo_wiql requires a WIQL query}" body out rc=0
  : "${AZDO_PROJECT:?AZDO_PROJECT must be set — call resolve_azdo_context first}"

  body=$(python3 -c 'import json, sys; print(json.dumps({"query": sys.argv[1]}))' "$query")

  out=$(printf '%s' "$body" | az devops invoke \
          --org "$(azdo_org_url)" --area wit --resource wiql \
          --route-parameters project="$AZDO_PROJECT" \
          --http-method POST --in-file /dev/stdin --api-version 7.1 \
          --output json --only-show-errors 2>&1) || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    if [[ "$out" == *TF51011* ]]; then
      printf '%s\n' "$out" >&2
      return 2
    fi
    printf '%s\n' "$out" >&2
    return 1
  fi

  printf '%s' "$out" | python3 -c '
import sys, json
for w in json.load(sys.stdin).get("workItems", []):
    print(w["id"])'
}
