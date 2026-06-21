#!/usr/bin/env bash
#
# Install (idempotently) and run Stryker.NET from the directory that holds
# stryker-config.json. Stryker exits non-zero when the mutation score falls
# below the configured `break` threshold — that is the gate.
#
# Usage: run-stryker.sh [config-dir]   (default: current directory)
set -euo pipefail
IFS=$'\n\t'

config_dir="${1:-.}"

dotnet tool install -g dotnet-stryker >/dev/null 2>&1 \
  || dotnet tool update -g dotnet-stryker >/dev/null 2>&1 \
  || true
export PATH="$PATH:$HOME/.dotnet/tools"

command -v dotnet-stryker >/dev/null \
  || { printf '::error::dotnet-stryker not on PATH after install\n'; exit 1; }

cd "$config_dir"
dotnet-stryker
