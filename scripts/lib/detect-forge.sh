#!/usr/bin/env bash
#
# detect-forge.sh — sourced, not executed.
#   detect_forge          echoes "github <host>" | "forgejo <host>" |
#                         "azdo <host>" | "unknown <host>" based on the cwd's
#                         `origin` remote.
#   resolve_azdo_context  sets AZDO_ORG / AZDO_PROJECT / AZDO_REPO from that
#                         remote; returns 1 when it is not an Azure DevOps one.
set -euo pipefail
IFS=$'\n\t'

# _forge_remote_url  echoes the cwd's origin URL with any trailing `.git` removed.
_forge_remote_url() {
  local url
  url=$(git remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  printf '%s\n' "${url%.git}"
}

# _forge_host <url>  echoes just the hostname — scheme, `user@` and everything
# from the first `:` or `/` removed. The `:` matters for scp-style remotes
# (`git@ssh.dev.azure.com:v3/org/project/repo`), where it, not `/`, ends the host.
_forge_host() {
  printf '%s' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^@/]*@##; s#[:/].*##'
}

# _forge_url_path <url>  echoes everything after the hostname, no leading slash.
# The host separator is `[:/]` for the same scp-style reason as above.
_forge_url_path() {
  printf '%s' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^@/]*@##; s#^[^:/]+[:/]##'
}

# _forge_urldecode <string>  decodes %XX escapes. ADO project names are allowed
# to contain spaces, which arrive as %20 in the remote URL.
_forge_urldecode() {
  printf '%b' "${1//%/\\x}"
}

detect_forge() {
  local url host
  url=$(_forge_remote_url) || url=""
  host=$(_forge_host "$url")

  # Azure DevOps is matched on the hostname alone, before any auth probe: these
  # three host forms collide with nothing else, so there is no ambiguity for a
  # login check to resolve. A machine with no `az` login still routes here — the
  # ADO command section is where a missing login gets reported, and reporting it
  # there beats falling through to "unknown host" and naming the wrong CLI.
  case "$host" in
    dev.azure.com|ssh.dev.azure.com|*.visualstudio.com)
      echo "azdo $host"
      return 0
      ;;
  esac

  if gh auth token --hostname "$host" >/dev/null 2>&1; then
    echo "github $host"
  elif tea logins list 2>/dev/null | grep -qiF "$host"; then
    echo "forgejo $host"
  elif [ "$host" = "github.com" ]; then
    echo "github $host"
  else
    echo "unknown $host"
  fi
}

# resolve_azdo_context — sets AZDO_ORG, AZDO_PROJECT, AZDO_REPO from the cwd's
# origin remote; returns 1 if that remote is not Azure DevOps or is unparseable.
#
# Values are returned as variables rather than echoed as one line **because an
# ADO project name may contain spaces** — the space-separated `"<forge> <host>"`
# idiom detect_forge uses would split such a name in half at the call site.
#
# Four remote shapes, all in the wild:
#   https://dev.azure.com/<org>/<project>/_git/<repo>
#   https://<org>@dev.azure.com/<org>/<project>/_git/<repo>
#   git@ssh.dev.azure.com:v3/<org>/<project>/<repo>      (and the ssh:// spelling)
#   https://<org>.visualstudio.com/[DefaultCollection/]<project>/_git/<repo>
# The legacy form is the odd one out: its org comes from the *hostname*, and an
# optional DefaultCollection segment sits where the project otherwise would.
resolve_azdo_context() {
  local url host path rest
  url=$(_forge_remote_url) || return 1
  host=$(_forge_host "$url")
  path=$(_forge_url_path "$url")

  case "$host" in
    dev.azure.com|ssh.dev.azure.com)
      path=${path#v3/}          # scp-style/ssh remotes carry a v3/ prefix
      AZDO_ORG=${path%%/*}
      rest=${path#*/}
      ;;
    *.visualstudio.com)
      AZDO_ORG=${host%%.*}
      rest=${path#DefaultCollection/}
      ;;
    *) return 1 ;;
  esac

  # `rest` is "<project>/_git/<repo>" on the https forms and "<project>/<repo>"
  # on the ssh ones. Taking the first and last segments covers both without
  # having to know which shape produced it.
  AZDO_PROJECT=$(_forge_urldecode "${rest%%/*}")
  AZDO_REPO=$(_forge_urldecode "${rest##*/}")

  # Reject a `rest` with no separator — one segment cannot yield both a project
  # and a repo. Testing for a `/` rather than comparing the two values, because
  # project and repo legitimately share a name: ADO gives a new project's first
  # repo the project's own name, so that is the *common* case, not a broken one.
  [[ "$rest" == */* ]] || return 1
  [ -n "$AZDO_ORG" ] && [ -n "$AZDO_PROJECT" ] && [ -n "$AZDO_REPO" ] || return 1
}
