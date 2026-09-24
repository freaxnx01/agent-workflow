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

# azdo_work_item_types  echoes the project's work-item type names, one per line.
#
# What /new offers and what /triage orders by: Azure DevOps has no `bug` LABEL,
# it has a Bug TYPE, so "bugs first" keys off this rather than a tag. Shares the
# workitemtypes call with azdo_closed_states -- a caller needing both should
# capture them from one invocation rather than paying for two round trips.
azdo_work_item_types() {
  : "${AZDO_PROJECT:?AZDO_PROJECT must be set — call resolve_azdo_context first}"
  az devops invoke --org "$(azdo_org_url)" --area wit --resource workitemtypes \
    --route-parameters project="$AZDO_PROJECT" \
    --api-version 7.1 --output json --only-show-errors \
  | python3 -c '
import sys, json
for t in json.load(sys.stdin).get("value", []):
    print(t["name"])'
}

# azdo_fields <ids-csv>  echoes one JSON object per work item, one per line,
# with keys: id, title, state, tags, iteration.
#
# This second call is not optional. WIQL returns IDS ONLY -- the SELECTTed
# columns come back as a `columns[]` description of the fields, not their
# values -- so anything beyond the id needs workitemsbatch.
#
# System.Tags is ABSENT from the response when a work item has no tags: the key
# is missing, not null and not an empty string. Defaulted here so callers never
# have to remember.
azdo_fields() {
  local ids="${1:?azdo_fields requires a comma-separated id list}"
  : "${AZDO_PROJECT:?AZDO_PROJECT must be set — call resolve_azdo_context first}"
  [[ -n "${ids//,/}" ]] || return 0

  python3 -c '
import json, sys
print(json.dumps({"ids": [int(i) for i in sys.argv[1].split(",") if i.strip()],
                  "fields": ["System.Id", "System.Title", "System.State",
                             "System.Tags", "System.IterationPath"]}))' "$ids" \
  | az devops invoke --org "$(azdo_org_url)" --area wit --resource workitemsbatch \
      --route-parameters project="$AZDO_PROJECT" \
      --http-method POST --in-file /dev/stdin --api-version 7.1 \
      --output json --only-show-errors \
  | python3 -c '
import sys, json
for w in json.load(sys.stdin).get("value", []):
    f = w.get("fields", {})
    print(json.dumps({
        "id":        f.get("System.Id"),
        "title":     f.get("System.Title", ""),
        "state":     f.get("System.State", ""),
        "tags":      f.get("System.Tags", ""),
        "iteration": f.get("System.IterationPath", ""),
    }))'
}

# _azdo_nodes <area|iteration>  shared by azdo_areas / azdo_iterations.
#
# Two traps, both silent. The response is a SINGLE OBJECT, not an array, so the
# obvious `--query '[].name'` returns nothing at all -- no output, no error,
# exit 0 -- which is indistinguishable from a project that has no nodes. And
# `children` is null rather than [] on a childless project, so `length(children)`
# ERRORS. Parsing in python rather than JMESPath sidesteps both.
#
# --depth is passed because it defaults to 1, which hides nested nodes -- the
# sprints that actually hold work items.
_azdo_nodes() {
  : "${AZDO_PROJECT:?AZDO_PROJECT must be set — call resolve_azdo_context first}"
  az boards "$1" project list --org "$(azdo_org_url)" --project "$AZDO_PROJECT" \
    --depth 3 --output json --only-show-errors \
  | python3 -c '
import sys, json
for c in (json.load(sys.stdin).get("children") or []):
    print(c["name"])'
}

azdo_areas()      { _azdo_nodes area; }
azdo_iterations() { _azdo_nodes iteration; }

# azdo_active_pr_work_items  echoes the ids of work items linked to an ACTIVE
# pull request, one per line, sorted and deduplicated.
#
# "Not WIP" means no *active* PR: a completed or abandoned one does not count,
# which is why --status is `active` and not `all`. Note there is no `open` --
# the values are active / completed / abandoned / all.
#
# Iterates the active PRs (few) and asks each for its work items, rather than
# asking every work item for its PRs (many). Both --query paths here were
# verified against a live organization.
#
# Empty output is a legitimate answer meaning nothing is WIP, not a failure.
azdo_active_pr_work_items() {
  : "${AZDO_PROJECT:?AZDO_PROJECT must be set — call resolve_azdo_context first}"
  : "${AZDO_REPO:?AZDO_REPO must be set — call resolve_azdo_context first}"
  local org_url pr
  org_url="$(azdo_org_url)"

  for pr in $(az repos pr list --org "$org_url" --project "$AZDO_PROJECT" \
                --repository "$AZDO_REPO" --status active \
                --output tsv --only-show-errors --query '[].pullRequestId'); do
    az repos pr work-item list --org "$org_url" --id "$pr" \
      --output tsv --only-show-errors --query '[].id'
  done | sort -u
}
