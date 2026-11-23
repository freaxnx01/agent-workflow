#!/usr/bin/env bash
#
# private-feed-restore.sh — sourced, not executed.
#
# The credentialed half of #641. Under the agent user boundary (#591, ADR-024)
# the agent holds no Azure DevOps credential, so it cannot restore a package
# that only a private Azure Artifacts feed serves. The driver (`azp`) does that
# restore for it, BEFORE the agent starts, into a folder the agent can only
# read; `awf-agent-run` then points NuGet at that folder with its constant
# NUGET_FALLBACK_PACKAGES, and NuGet takes what it finds there without asking
# any source.
#
# Two rules shape everything here:
#
#   The token never travels in argv. /proc/<pid>/cmdline is world readable, so
#   it goes into a temporary NuGet config, mode 0600, inside a mode-0700
#   directory, which is deleted on every exit path. `--configfile` and a
#   leading <clear /> mean the repository's own nuget.config hierarchy cannot
#   add a source that would also receive it.
#
#   The restore never runs on code the agent wrote. MSBuild evaluation executes
#   repository logic, so it runs only on a detached worktree of the commit the
#   agent is seeded from — never on an agent workspace.
#
# Requires `bgit` from lib/agent-boundary.sh: every git call must disable hooks
# and fsmonitor, and that wrapper is where that rule lives.
#
# Functions (0 on success, 1 on failure with the cause on stderr):
#   feed_restore_enabled              AWF_NUGET_FEEDS holds a non-blank value
#   feed_restore_config_check         `dotnet` is present and every feed URL is
#                                     an Azure DevOps feed URL
#   feed_restore_targets_syntax_check every AWF_NUGET_RESTORE entry is a
#                                     relative solution or project path
#   feed_write_config <file>          writes the credentialed NuGet config, 0600
#   feed_cache_clear                  empties AWF_NUGET_CACHE; 0 when it is
#                                     absent, 1 when it is a symlink or not a
#                                     directory this user owns
#   feed_restore_targets <worktree>   sets FEED_TARGETS; 2 when there is none
#   feed_pre_restore <seed-ref> <work-dir>
#                                     the whole restore; cleans up on both
#                                     paths; 2 when there is nothing to restore
#
# Optional environment:
#   AWF_NUGET_FEEDS   space-separated feed index URLs. Empty or unset = off.
#   AWF_NUGET_RESTORE space-separated relative paths of the solutions or
#                     projects to restore. Empty or unset = the solutions at the
#                     repository root (#682).
#   AWF_NUGET_CACHE   the fallback folder. Default /var/cache/awf-nuget. The
#                     library tests override it; in a pipeline the driver's
#                     preflight_cache refuses any other value.
#
# Sourcing has no side effects beyond defining these and their defaults.

AWF_NUGET_CACHE="${AWF_NUGET_CACHE:-/var/cache/awf-nuget}"
# NuGet wants a username with a token password; the value is not checked.
AWF_FEED_USER=ai-implement
AWF_NUGET_ORG_URL=https://api.nuget.org/v3/index.json

# The feeds of the current AWF_NUGET_FEEDS, filled by feed_list.
FEED_URLS=()

# feed_list — splits AWF_NUGET_FEEDS into FEED_URLS. The split is explicit
# because this repo's scripts run with IFS=$'\n\t', which does not split on the
# spaces the pipeline variable separates its URLs with.
feed_list() {
  FEED_URLS=()
  local IFS=$' \t\n'
  read -r -a FEED_URLS <<<"${AWF_NUGET_FEEDS:-}"
}

feed_restore_enabled() {
  feed_list
  (( ${#FEED_URLS[@]} > 0 ))
}

# The entries of the current AWF_NUGET_RESTORE, filled by feed_restore_list.
FEED_RESTORE_ENTRIES=()

# feed_restore_list — splits AWF_NUGET_RESTORE into FEED_RESTORE_ENTRIES. The
# split is explicit for the same reason feed_list's is: this repo's scripts run
# with an IFS that does not split on spaces. A blank value yields no entry, so
# it is the same as an unset one.
feed_restore_list() {
  FEED_RESTORE_ENTRIES=()
  local IFS=$' \t\n'
  read -r -a FEED_RESTORE_ENTRIES <<<"${AWF_NUGET_RESTORE:-}"
}

# feed_restore_targets_syntax_check — the cheap half of the target check, safe
# to run in preflight before the seed worktree exists. An entry must stay inside
# the worktree and name a solution or project: the path reaches `dotnet restore`
# in argv, and MSBuild evaluation executes whatever it points at.
feed_restore_targets_syntax_check() {
  feed_restore_list
  local entry
  for entry in "${FEED_RESTORE_ENTRIES[@]}"; do
    if [[ "$entry" =~ ^[A-Za-z0-9._/-]+\.(sln|slnx|csproj|fsproj)$ ]] &&
       [[ "$entry" != /* ]] &&
       [[ "$entry" != ../* && "$entry" != */../* && "$entry" != */.. ]]; then
      continue
    fi
    printf "AWF_NUGET_RESTORE entry '%s' is not a relative solution or project path\n" \
      "$entry" >&2
    return 1
  done
  return 0
}

# feed_is_azdo_feed <url> — the token is written for these two forms only, so a
# typo or a hostile pipeline variable cannot send it to another host.
feed_is_azdo_feed() {
  [[ "$1" =~ ^https://pkgs\.dev\.azure\.com/[^/]+/ ]] && return 0
  [[ "$1" =~ ^https://[A-Za-z0-9-]+\.pkgs\.visualstudio\.com/ ]] && return 0
  return 1
}

# feed_restore_config_check — the cheap half, safe to run in preflight before
# the work dir and the default branch exist.
feed_restore_config_check() {
  if ! command -v dotnet >/dev/null 2>&1; then
    printf 'dotnet is not on PATH; rebuild the agent image with --target dotnet\n' >&2
    return 1
  fi
  feed_list
  local url
  for url in "${FEED_URLS[@]}"; do
    if ! feed_is_azdo_feed "$url"; then
      printf 'not an Azure DevOps feed URL: %s\n' "$url" >&2
      return 1
    fi
  done
  return 0
}

# feed_xml_escape <text> — the token is opaque: `&` and `<` in it would make the
# config unparseable, and NuGet would report a corrupt file rather than a
# credential problem.
#
# Character by character, NOT `${text//&/&amp;}`: since bash 5.2 a `&` in the
# replacement of a pattern substitution means "the text that matched", so the
# obvious one-liner turns `a&b<c` into `a&amp;b<lt;c`. Appending is unambiguous
# on every bash, and the token stays inside this process.
feed_xml_escape() {
  local text="$1" out='' index char
  for (( index = 0; index < ${#text}; index++ )); do
    char="${text:index:1}"
    case "$char" in
      '&') out+='&amp;' ;;
      '<') out+='&lt;' ;;
      '>') out+='&gt;' ;;
      '"') out+='&quot;' ;;
      *)   out+="$char" ;;
    esac
  done
  printf '%s' "$out"
}

# feed_write_config <file> — the only place the token is ever written. The mode
# is set on the empty file first, so it is never readable with content in it.
feed_write_config() {
  local file="$1" url secret index
  feed_list
  : > "$file" || return 1
  chmod 0600 "$file" || return 1
  secret="$(feed_xml_escape "${AZURE_DEVOPS_EXT_PAT:-}")"
  {
    printf '<?xml version="1.0" encoding="utf-8"?>\n'
    printf '<configuration>\n'
    printf '  <packageSources>\n'
    # <clear /> drops every source the repository's own nuget.config hierarchy
    # would otherwise contribute: only the sources below receive the token.
    printf '    <clear />\n'
    printf '    <add key="nuget.org" value="%s" />\n' "$AWF_NUGET_ORG_URL"
    index=0
    for url in "${FEED_URLS[@]}"; do
      index=$((index + 1))
      printf '    <add key="feed%s" value="%s" />\n' "$index" "$(feed_xml_escape "$url")"
    done
    printf '  </packageSources>\n'
    printf '  <packageSourceCredentials>\n'
    index=0
    for url in "${FEED_URLS[@]}"; do
      index=$((index + 1))
      printf '    <feed%s>\n' "$index"
      printf '      <add key="Username" value="%s" />\n' "$AWF_FEED_USER"
      printf '      <add key="ClearTextPassword" value="%s" />\n' "$secret"
      printf '    </feed%s>\n' "$index"
    done
    printf '  </packageSourceCredentials>\n'
    printf '</configuration>\n'
  } >> "$file"
}

# feed_cache_clear — the container outlives the job, so a previous run's
# packages are stale and must not be offered to the next agent. `-mindepth 1`
# empties, dotfiles included, without removing the folder the image created
# with the right ownership. The folder must be a real directory this user owns:
# `find -delete` and the `chmod -R` after a restore would otherwise act on
# whatever a symlink or a foreign path points at.
feed_cache_clear() {
  local cache="$AWF_NUGET_CACHE"
  [[ -e "$cache" || -L "$cache" ]] || return 0
  if [[ -L "$cache" || ! -d "$cache" || ! -O "$cache" ]]; then
    printf 'the package cache %s is a symlink or not a directory owned by %s\n' \
      "$cache" "$(id -un)" >&2
    return 1
  fi
  if ! find "$cache" -mindepth 1 -delete; then
    printf 'could not empty the package cache %s\n' "$cache" >&2
    return 1
  fi
  return 0
}

# feed_restore_cleanup <worktree-root> <config-dir> — runs on BOTH exit paths of
# feed_pre_restore, and deliberately not from an EXIT trap: the driver owns its
# trap, and installing a second one here would replace the driver's.
feed_restore_cleanup() {
  local worktree_root="$1" config_dir="$2"
  [[ -z "$config_dir" ]] || rm -rf "$config_dir"
  if [[ -n "$worktree_root" ]]; then
    bgit worktree remove --force "$worktree_root/seed" >/dev/null 2>&1 || true
    rm -rf "$worktree_root"
    bgit worktree prune >/dev/null 2>&1 || true
  fi
  return 0
}

# feed_restore_targets <worktree> — what to restore, as paths relative to
# <worktree>, in FEED_TARGETS. AWF_NUGET_RESTORE names them; without it, the
# solution files at the root, a root with both a .sln and a .slnx getting both.
#
# Returns 2 when there is nothing to restore (#682). `dotnet restore` with no
# argument in a root that holds no solution stops with MSB1003, so a consumer
# whose solution lives in a subdirectory is told which variable to set instead.
#
# A named entry must be a regular file in the worktree: the worktree is the seed
# commit, and a symlink there could point at a project outside it.
FEED_TARGETS=()
feed_restore_targets() {
  local worktree="$1" entry path
  FEED_TARGETS=()
  feed_restore_list
  if (( ${#FEED_RESTORE_ENTRIES[@]} > 0 )); then
    for entry in "${FEED_RESTORE_ENTRIES[@]}"; do
      if [[ -L "$worktree/$entry" || ! -f "$worktree/$entry" ]]; then
        printf "AWF_NUGET_RESTORE entry '%s' is not in the seed commit\n" "$entry" >&2
        return 2
      fi
      FEED_TARGETS+=("$entry")
    done
    return 0
  fi
  for path in "$worktree"/*.sln "$worktree"/*.slnx; do
    [[ -f "$path" ]] || continue
    FEED_TARGETS+=("${path##*/}")
  done
  if (( ${#FEED_TARGETS[@]} == 0 )); then
    printf 'no solution at the repository root; set AWF_NUGET_RESTORE to the solution or project to restore\n' >&2
    return 2
  fi
  return 0
}

# feed_restore_one <worktree> <config> <target> — one `dotnet restore`, run
# inside the worktree so only the target's relative path reaches argv.
feed_restore_one() {
  local worktree="$1" config="$2" target="$3"
  # No build server or reused MSBuild node may outlive this call: it would keep
  # running with the driver's environment, token included, into the agent run.
  local args=("$target" --configfile "$config" --packages "$AWF_NUGET_CACHE" --disable-build-servers)
  ( cd "$worktree" && MSBUILDDISABLENODEREUSE=1 dotnet restore "${args[@]}" )
}

# feed_pre_restore <seed-ref> <work-dir> — the whole credentialed restore.
feed_pre_restore() {
  local seed_ref="$1" work_dir="$2"
  local config_dir='' worktree_root='' worktree='' config='' target='' rc=0

  umask 077

  if [[ ! -e "$AWF_NUGET_CACHE" && ! -L "$AWF_NUGET_CACHE" ]]; then
    printf 'the package cache %s does not exist; rebuild the agent image\n' \
      "$AWF_NUGET_CACHE" >&2
    return 1
  fi

  config_dir="$(mktemp -d "$work_dir/feed-config.XXXXXX")" || return 1
  worktree_root="$(mktemp -d "$work_dir/feed-seed.XXXXXX")" || {
    feed_restore_cleanup '' "$config_dir"
    return 1
  }
  chmod 0700 "$config_dir" "$worktree_root" || {
    feed_restore_cleanup "$worktree_root" "$config_dir"
    return 1
  }
  config="$config_dir/nuget.config"
  worktree="$worktree_root/seed"

  if ! bgit worktree add --quiet --detach "$worktree" "$seed_ref" >/dev/null 2>&1; then
    printf 'could not check out %s for the restore\n' "$seed_ref" >&2
    feed_restore_cleanup "$worktree_root" "$config_dir"
    return 1
  fi
  chmod 0700 "$worktree" || rc=1

  # The targets come before the config: a run with nothing to restore refuses
  # without the token ever having been written.
  if [[ "$rc" -eq 0 ]] && ! feed_restore_targets "$worktree"; then
    feed_restore_cleanup "$worktree_root" "$config_dir"
    return 2
  fi

  if [[ "$rc" -eq 0 ]] && ! feed_write_config "$config"; then
    printf 'could not write the temporary NuGet config\n' >&2
    rc=1
  fi

  if [[ "$rc" -eq 0 ]] && ! feed_cache_clear; then
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    for target in "${FEED_TARGETS[@]}"; do
      feed_restore_one "$worktree" "$config" "$target" || { rc=1; break; }
    done
    [[ "$rc" -eq 0 ]] || printf 'the restore of %s failed\n' "$seed_ref" >&2
  fi

  # Directories 0755 and files 0644: the restore ran under umask 077, and
  # `awf-agent` has to read every package. It must not be able to write any.
  if [[ "$rc" -eq 0 ]] && ! chmod -R u=rwX,go=rX "$AWF_NUGET_CACHE"; then
    printf 'could not make the package cache readable for the agent\n' >&2
    rc=1
  fi

  feed_restore_cleanup "$worktree_root" "$config_dir"
  return "$rc"
}
