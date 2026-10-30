#!/usr/bin/env bash
#
# ci-host.sh — sourced, not executed.
#
# CI-host identity adapter: tells a script which CI system it runs on and hands
# it that system's built-in identity token, so callers never branch on
# TF_BUILD / GITHUB_ACTIONS themselves. Sourcing has no side effects (no shell
# options are changed, nothing is run).
#
#   ci_host         echoes pipelines | actions | local
#                     pipelines  TF_BUILD is "True" (case-insensitive)
#                     actions    GITHUB_ACTIONS is "true"
#                     local      neither
#   ci_host_token   echoes the CI identity token
#                     pipelines  $SYSTEM_ACCESSTOKEN
#                     actions    $GITHUB_TOKEN
#
# Deliberately absent (spec D5): set-output and re-dispatch. Those differ per
# host in ways a one-verb adapter must not paper over.
#
# Exit codes:
#   0   success
#   1   ci_host_token: on a CI host but its token variable is empty (stderr
#       names the variable; on pipelines, how to map System.AccessToken)
#   64  ci_host_token: running locally — no CI identity; the caller supplies
#       its own credential (nothing on stdout)
#
# The token is only ever written to stdout of ci_host_token, never logged.

ci_host() {
  local tf_build="${TF_BUILD:-}"
  if [[ "${tf_build,,}" == "true" ]]; then
    printf 'pipelines\n'
  elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf 'actions\n'
  else
    printf 'local\n'
  fi
}

ci_host_token() {
  local host token
  host="$(ci_host)"
  case "$host" in
    pipelines)
      token="${SYSTEM_ACCESSTOKEN:-}"
      if [[ -z "$token" ]]; then
        printf '%s\n' "ci-host: SYSTEM_ACCESSTOKEN is empty; map System.AccessToken into the step env (env: SYSTEM_ACCESSTOKEN: \$(System.AccessToken))" >&2
        return 1
      fi
      ;;
    actions)
      token="${GITHUB_TOKEN:-}"
      if [[ -z "$token" ]]; then
        printf '%s\n' "ci-host: GITHUB_TOKEN is empty; pass it into the step env (env: GITHUB_TOKEN: \${{ github.token }})" >&2
        return 1
      fi
      ;;
    *)
      printf '%s\n' "ci-host: no CI identity; caller supplies its own credential" >&2
      return 64
      ;;
  esac
  printf '%s\n' "$token"
}
