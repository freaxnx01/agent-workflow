#!/usr/bin/env bash
#
# Generate a Code Metrics XML report for a solution/project.
#
# Relies on the Microsoft.CodeAnalysis.Metrics package being referenced by the
# project(s) under analysis (wired via templates/dotnet/Directory.Build.props in
# the standard). Fails loudly if no report is produced — an empty/missing report
# would let the downstream method-size check scan nothing and report green.
#
# Usage: gen-metrics.sh <solution> <configuration> <output-xml>
set -euo pipefail
IFS=$'\n\t'

solution="${1:?usage: gen-metrics.sh <solution> <configuration> <output-xml>}"
configuration="${2:?usage: gen-metrics.sh <solution> <configuration> <output-xml>}"
output="${3:?usage: gen-metrics.sh <solution> <configuration> <output-xml>}"

dotnet build "$solution" -c "$configuration" -t:Metrics \
  -p:MetricsOutputFile="$output" --no-incremental

if [[ ! -s "$output" ]]; then
  printf '::error::no metrics report at %s — is Microsoft.CodeAnalysis.Metrics referenced?\n' "$output"
  exit 1
fi
printf 'metrics report written to %s\n' "$output"
