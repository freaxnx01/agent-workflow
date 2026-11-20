#!/usr/bin/env bash
#
# agent-boundary.sh — sourced, not executed.
#
# The driver side of the agent user boundary (#591, ADR-024). In an Azure
# Pipelines run the implement and self-fix agents run as `awf-agent`, a second
# Linux user that holds no Azure DevOps credential and can write nothing the
# driver later executes or trusts. This library is how the driver (`azp`) talks
# to that user: through the three fixed, root-owned entry points of
# /usr/local/libexec/awf-agent/, and nothing else.
#
# Everything that crosses back is hostile data. The agent's commits arrive only
# as a git bundle, verified in the driver's own checkout — which the agent
# cannot write — with hooks and fsmonitor disabled on every call, with the
# bundle's branch name validated before it reaches a git command line, and with
# the commits required to descend from the attempt's base. Its result JSON is
# size-capped by the caller and read only through import-result-output.sh.
#
# Functions (0 on success, 1 on failure with one line on stderr naming it):
#   boundary_check                  every entry point answers the known protocol
#   boundary_new_workspace <n>      prints workspace <n>'s path (not created)
#   boundary_seed <ws> <dir> <ref>  bundles <ref> into <dir> and seeds <ws>
#   boundary_exec_claude <ws> <args...>   runs the agent CLI in <ws>
#   boundary_commit <ws> <message>  commits in <ws>; 3 = nothing to commit
#   boundary_reap                   ends every agent process; 1 = survivors
#   boundary_collect <ws> <base> <dir>
#                                   fetches the agent's commits into
#                                   refs/awf/collected and prints the branch the
#                                   bundle carried (empty when detached);
#                                   3 = no commit beyond <base>;
#                                   4 = the bundle names a branch the driver
#                                   will not use
#   valid_branch_name <name>        the branch-name rule for agent-chosen names
#   cap_file_bytes <file> <max>     1 when the file is larger, missing or unreadable
#   checkout_has_credentials        0 when the checkout carries a credential
#   url_has_credential <url>        0 when the URL's userinfo may carry a secret
#   azdo_git <git-args...>          git with the Azure DevOps Basic header in its
#                                   ENVIRONMENT, never in its argv
#
# Optional environment:
#   AWF_BOUNDARY_DIR  where the entry points live. Default
#                     /usr/local/libexec/awf-agent.
#   AWF_WS_ROOT       where agent workspaces live. Default /home/awf-agent/ws.
#   AWF_RUN_ID        distinguishes this run's workspaces. Default the driver's pid.
#
# Sourcing has no side effects beyond defining these and their defaults.

AWF_BOUNDARY_DIR="${AWF_BOUNDARY_DIR:-/usr/local/libexec/awf-agent}"
AWF_WS_ROOT="${AWF_WS_ROOT:-/home/awf-agent/ws}"
AWF_AGENT_USER=awf-agent
AWF_BOUNDARY_PROTOCOL=2

# bgit <git-args...> — the only git in this file. Hooks and fsmonitor are off on
# EVERY call: a bundle, a fetch and a rev-list all run repo config, and the
# agent owns the repo they came from. The calls that touch no agent data go
# through it too, so "every git call here disables hooks" stays a property a
# static guard can check (tests/run-azdo-isolation-tests.sh) rather than a
# judgement about which call needs it.
bgit() {
  git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

# boundary_sudo <entry-point> <args...> — the only way this library runs anything
# as the agent user. `-n`: a sudo that would prompt is a broken boundary, not a
# thing to wait for.
boundary_sudo() {
  local entry="$1"; shift
  sudo -n -u "$AWF_AGENT_USER" "$AWF_BOUNDARY_DIR/$entry" "$@"
}

boundary_check() {
  local entry answer
  for entry in awf-agent-run awf-agent-git awf-agent-reap; do
    if ! answer="$(boundary_sudo "$entry" --protocol 2>&1)"; then
      printf 'agent boundary: sudo could not run %s as %s: %s\n' \
        "$entry" "$AWF_AGENT_USER" "$(printf '%s' "$answer" | head -n1)" >&2
      return 1
    fi
    if [[ "$answer" != "$AWF_BOUNDARY_PROTOCOL" ]]; then
      printf 'agent boundary: %s speaks protocol %q, this driver speaks %s\n' \
        "$entry" "$answer" "$AWF_BOUNDARY_PROTOCOL" >&2
      return 1
    fi
  done
  return 0
}

# boundary_new_workspace <n> — the path of this run's workspace <n>; it creates
# nothing (the seed, as the agent, is what creates it). The sequence number is
# the caller's (the attempt, the fix iteration) rather than state in here: a
# counter kept here would be incremented inside the caller's `$( )` subshell and
# lost, handing the next attempt the last agent's workspace.
boundary_new_workspace() {
  local sequence="${1:?boundary_new_workspace needs a sequence number}"
  printf '%s/%s-%s\n' "$AWF_WS_ROOT" "${AWF_RUN_ID:-$$}" "$sequence"
}

# boundary_seed <workspace> <bundle-dir> <ref> — hands the agent its starting
# point as a bundle of the driver's own checkout. A bundle, not a clone or a
# shared directory: it carries commits and nothing else, so no remote, no
# config and no credential of the driver's can travel with it.
boundary_seed() {
  local workspace="$1" bundle_dir="$2" ref="$3" bundle="$2/seed.bundle"
  if ! mkdir -p "$bundle_dir"; then
    printf 'agent boundary: could not create the handoff dir %s\n' "$bundle_dir" >&2
    return 1
  fi
  # 0711 and 0644: the agent user can reach this one file and list nothing.
  chmod 0711 "$bundle_dir" || return 1
  if ! bgit bundle create -q "$bundle" "$ref" 2>/dev/null; then
    printf 'agent boundary: could not bundle %s for the agent\n' "$ref" >&2
    return 1
  fi
  chmod 0644 "$bundle" || return 1
  if ! boundary_sudo awf-agent-git "$workspace" seed "$bundle" "$ref"; then
    printf 'agent boundary: could not seed the agent workspace %s\n' "$workspace" >&2
    return 1
  fi
  return 0
}

# boundary_exec_claude <workspace> <agent-args...> — stdin (the prompt) and
# stdout (the result JSON) pass straight through, and the agent's exit status is
# this function's, so the caller classifies it exactly as a local run.
boundary_exec_claude() {
  local workspace="$1"; shift
  boundary_sudo awf-agent-run "$workspace" -- "$@"
}

# boundary_commit <workspace> <message> — 3 when there was nothing to commit,
# which is a run outcome (the agent changed nothing), not a boundary failure.
boundary_commit() {
  local workspace="$1" message="$2" rc=0
  boundary_sudo awf-agent-git "$workspace" commit "$message" || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    return 3
  fi
  if [[ "$rc" -ne 0 ]]; then
    printf 'agent boundary: the commit in %s failed\n' "$workspace" >&2
    return 1
  fi
  return 0
}

boundary_reap() {
  local remaining rc=0
  remaining="$(boundary_sudo awf-agent-reap 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf 'agent boundary: an agent process survived the attempt (%s)\n' \
      "$(printf '%s' "$remaining" | tr '\n' ' ' | sed 's/ *$//')" >&2
    return 1
  fi
  return 0
}

# bundle_branch <bundle> — the branch the bundle's single head names, empty for
# a detached HEAD. Fails when the bundle carries no head, more than one, or a
# ref name that is not a plain branch: the name is the agent's to choose, so it
# is checked HERE, before it can reach a git command line.
bundle_branch() {
  local bundle="$1" heads ref name
  heads="$(bgit bundle list-heads "$bundle" 2>/dev/null)" || return 1
  if [[ "$(printf '%s\n' "$heads" | grep -c . || true)" != 1 ]]; then
    printf 'agent boundary: the agent bundle must carry exactly one head\n' >&2
    return 1
  fi
  ref="${heads#* }"
  if [[ "$ref" == "HEAD" ]]; then
    printf '\n'
    return 0
  fi
  name="${ref#refs/heads/}"
  if [[ "$ref" == "$name" ]] || ! valid_branch_name "$name"; then
    printf 'agent boundary: the agent bundle names an unusable branch\n' >&2
    return 1
  fi
  printf '%s\n' "$name"
  return 0
}

# boundary_collect <workspace> <base-sha> <bundle-dir> — the only path the
# agent's commits take back. The bundle is produced through the boundary and
# every check runs in the driver's checkout, which the agent cannot write.
boundary_collect() {
  local workspace="$1" base="$2" bundle_dir="$3" bundle="$3/out.bundle"
  local rc=0 branch ref
  mkdir -p "$bundle_dir" || return 1
  boundary_sudo awf-agent-git "$workspace" bundle "$base" > "$bundle" || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    return 3
  fi
  if [[ "$rc" -ne 0 ]]; then
    printf 'agent boundary: could not read the agent commits out of %s\n' "$workspace" >&2
    return 1
  fi
  if ! bgit bundle verify "$bundle" >/dev/null 2>&1; then
    printf 'agent boundary: the agent bundle does not verify against this checkout\n' >&2
    return 1
  fi
  branch="$(bundle_branch "$bundle")" || return 4
  ref="refs/heads/$branch"
  [[ -n "$branch" ]] || ref=HEAD
  if ! bgit fetch --quiet "$bundle" "+$ref:refs/awf/collected" 2>/dev/null; then
    printf 'agent boundary: could not fetch the agent commits into refs/awf/collected\n' >&2
    return 1
  fi
  if ! bgit merge-base --is-ancestor "$base" refs/awf/collected 2>/dev/null; then
    printf 'agent boundary: the agent commits do not descend from %s\n' "$base" >&2
    return 1
  fi
  printf '%s\n' "$branch"
  return 0
}

# valid_branch_name <name> — the agent names its own branch, so the name is
# hostile input. Both rules apply: a conservative charset (no leading dash, so
# it can never be read as an option) and git's own ref grammar.
valid_branch_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  [[ "$name" != -* ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || return 1
  bgit check-ref-format --branch "$name" >/dev/null 2>&1
}

# cap_file_bytes <file> <max> — 1 when the file is larger than <max>, and also
# when it cannot be measured: an unreadable result is no evidence.
cap_file_bytes() {
  local file="$1" max="$2" size
  size="$(wc -c < "$file" 2>/dev/null | tr -d ' ')" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  (( size <= max ))
}

# checkout_has_credentials — true when this checkout would hand a credential to
# anything that runs git in it. Nothing in this repo can enforce
# `persistCredentials: false` on the consumer's pipeline YAML, so the driver
# checks the result and refuses.
checkout_has_credentials() {
  if bgit config --get-regexp '^http\..*extraheader$' >/dev/null 2>&1; then
    return 0
  fi
  local url
  while read -r url; do
    [[ -n "$url" ]] || continue
    url_has_credential "$url" && return 0
  done < <(bgit remote -v 2>/dev/null | awk '{ print $2 }' | sort -u)
  return 1
}

# url_has_credential <url> — 0 when the URL's userinfo may carry a secret.
# The one exception is the Azure DevOps checkout's own form,
# https://<org>@dev.azure.com/<org>/..., which names the organization as the
# user even with persistCredentials: false. Any other bare user counts, since
# Azure DevOps accepts a PAT in the user position.
url_has_credential() {
  local url="$1"
  [[ "$url" =~ ^[A-Za-z+.-]+://([^/@]*)@[^/]+/([^/]*) ]] || return 1
  local userinfo="${BASH_REMATCH[1]}" first_segment="${BASH_REMATCH[2]}"
  [[ "$userinfo" == *:* ]] && return 0
  [[ -n "$userinfo" && "$userinfo" == "$first_segment" ]] && return 1
  return 0
}

# azdo_git <git-args...> — an authenticated git call. The header goes in through
# GIT_CONFIG_* rather than `git -c`, because /proc/<pid>/cmdline is world
# readable and the agent user can read it; the environment of another user's
# process is not.
azdo_git() {
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=http.extraheader \
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf ':%s' "${AZURE_DEVOPS_EXT_PAT:-}" | base64 -w0)" \
  bgit "$@"
}
