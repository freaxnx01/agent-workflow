#!/usr/bin/env bash
#
# intake-label.sh — the intake stamp, defined once.
#
# needs-enrichment is the entry ticket to the unattended lane: an issue
# carrying it may be enriched by a paid nested session
# (lib/autopilot-candidates.sh) and the result dispatched. Its name, colour and
# description live here so the two writers cannot drift —
# ensure-issue-labels.sh seeds it at onboarding, and issue-intake.sh creates it
# per issue as well, because a repo onboarded before this label existed has
# never had it seeded and `gh issue edit --add-label` fails outright on a label
# that does not exist.
#
# Sourced, not executed. Exposes:
#   INTAKE_LABEL        the label name
#   INTAKE_LABEL_COLOR  its colour — the same /new's Forgejo path uses
#                       (commands/new.md)
#   INTAKE_LABEL_DESC   its description
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2034  # consumed by the caller after sourcing, not in this file
INTAKE_LABEL='needs-enrichment'
# shellcheck disable=SC2034  # consumed by the caller after sourcing, not in this file
INTAKE_LABEL_COLOR='d4c5f9'
# shellcheck disable=SC2034  # consumed by the caller after sourcing, not in this file
INTAKE_LABEL_DESC='Needs a spec and plan before it can be implemented — /enrich or the autopilot lane'
