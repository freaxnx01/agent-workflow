# `_forge_url_path` — parse remotes by shape, not by first delimiter (#387)

**Date:** 2026-09-23
**Issue:** [#387](https://github.com/freaxnx01/agent-workflow/issues/387)
**Status:** approved

## Problem

`_forge_url_path` in `scripts/lib/detect-forge.sh` returns the wrong path for any
`ssh://` remote carrying an explicit port. Found during the live-org run of the
Azure DevOps manual test plan (`docs/ai-notes/2026-09-22-ado-manual-test-run.md`).

```
ssh://git@ssh.dev.azure.com:22/v3/bossinfo/bossDMS/knowledge-base
  → AZDO_ORG=[22]  AZDO_PROJECT=[v3]  AZDO_REPO=[knowledge-base]
```

Expected `bossinfo / bossDMS / knowledge-base`. Every field is shifted by one.

### Cause

The function ends the host at the **first** `:` or `/`:

```bash
s#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^@/]*@##; s#^[^:/]+[:/]##
```

Applied to the failing remote:

```
ssh://git@ssh.dev.azure.com:22/v3/bossinfo/…
  → (scheme)    git@ssh.dev.azure.com:22/v3/bossinfo/…
  → (userinfo)      ssh.dev.azure.com:22/v3/bossinfo/…
  → (host)                          22/v3/bossinfo/…      ← port kept as a path segment
```

`resolve_azdo_context` then runs `path=${path#v3/}`, which no longer matches
because the string starts `22/`, so the `v3` prefix survives and each field takes
the previous one's value.

### Why it is silent

`_forge_host` uses a different expression (`s#[:/].*##`) and is **not** affected,
so `detect_forge` still correctly reports `azdo`. Nothing errors; the command
proceeds with plausible-looking garbage. Any port reproduces it — `:7999` yields
`AZDO_ORG=[7999]`.

### Blast radius beyond Azure DevOps

`_forge_url_path` is shared by all three forges. A Forgejo remote on a non-standard
SSH port — `ssh://git@git.home.freaxnx01.ch:2222/freax/repo` — is broken today by
the same expression, yielding `2222/freax/repo`. The bug was found via ADO but is
not ADO-specific.

## Decision

Parse by **remote shape** rather than by first delimiter, because the two shapes
give `:` opposite meanings:

| Shape | Form | What `:` means |
|---|---|---|
| URL | `scheme://[user@]host[:port]/path` | port separator |
| scp-style | `[user@]host:path` | **path** separator |

The key fact: **git does not support a port in scp-style syntax.** So a `:` in a
scheme-less remote is never a port, and a `:` before the first `/` in a URL-form
remote is always a port. The shapes are unambiguous once told apart; the current
single expression conflates them.

### Rejected — numeric-port guard

`s#^([^:/]+)(:[0-9]+)?[:/]##` was considered and rejected. It fixes the reported
case with a one-line diff and passes the existing suite (`v3` is not numeric), but
it encodes a heuristic rather than the rule: scp-style `git@host:22/foo` genuinely
means the path `22/foo`, and the guard would misread it as a port. The function is
six lines, so the more correct form costs nothing to write or read.

## Design

```bash
# _forge_url_path <url>  echoes everything after the hostname, no leading slash.
#
# The two remote shapes give `:` opposite meanings, so they are parsed apart:
#   URL form   scheme://[user@]host[:port]/path   `:` is a port separator
#   scp-style  [user@]host:path                   `:` is the PATH separator
# git supports no port in scp-style syntax, which is what makes them separable.
_forge_url_path() {
  local url=$1
  case "$url" in
    [a-zA-Z]*://*)
      # The path begins at the first `/` after the authority, so userinfo and
      # any `:port` fall away with it — neither needs its own step.
      url=${url#*://}
      printf '%s' "${url#*/}"
      ;;
    *)
      # Strip userinfo only when the `@` precedes the `:`; an `@` after it
      # belongs to the path.
      if [[ "${url%%:*}" == *@* ]]; then url=${url#*@}; fi
      printf '%s' "${url#*:}"
      ;;
  esac
}
```

### Why the URL branch needs no userinfo step

Userinfo lives in the authority, which is everything before the first `/`. Taking
`${url#*/}` discards the whole authority at once, so `user@`, `host` and `:port`
all go together. This removes the `s#^[^@/]*@##` step rather than reimplementing it.

### Why the scp branch guards the `@`

The original `s#^[^@/]*@##` only stripped userinfo when the `@` appeared before any
`/`. The replacement keeps an equivalent guard against `:` — without it, a remote
like `host:path@x` would lose `path@`.

### `_forge_host` is unchanged

`s#[:/].*##` already ends the host at the first `:` **or** `/`, which is correct for
both shapes. It is out of scope.

## Compatibility

The existing suite contains `ssh://git@ssh.dev.azure.com:v3/contoso/MyProject/my-repo`
(`tests/run-detect-forge-tests.sh:159`) — a scheme **with** a colon and **no** port.
Under the new URL branch the authority is taken as `git@ssh.dev.azure.com:v3` and the
path as `contoso/MyProject/my-repo`. The `v3` prefix is consumed as part of the
authority rather than by `${path#v3/}`, which then no-ops — and the resolved values
are unchanged:

```
AZDO_ORG=contoso  AZDO_PROJECT=MyProject  AZDO_REPO=my-repo
```

So the case keeps passing, by a different route. This is the one behaviour worth
watching in review, because the intermediate value differs even though the result
does not.

## Acceptance criteria

- [ ] `ssh://git@ssh.dev.azure.com:22/v3/<org>/<project>/<repo>` resolves correctly
- [ ] A non-22 port (`:7999`) resolves identically
- [ ] `ssh://git@git.home.freaxnx01.ch:2222/freax/repo` yields path `freax/repo`
- [ ] Every form in the table below still resolves as it does today
- [ ] `shellcheck -x` and `actionlint` stay clean

### Regression matrix

| Remote | Expected |
|---|---|
| `https://dev.azure.com/o/p/_git/r` | `o / p / r` |
| `https://o@dev.azure.com/o/p/_git/r` | `o / p / r` |
| `git@ssh.dev.azure.com:v3/o/p/r` | `o / p / r` |
| `ssh://git@ssh.dev.azure.com:v3/o/p/r` | `o / p / r` (existing test) |
| `ssh://git@ssh.dev.azure.com/v3/o/p/r` | `o / p / r` |
| **`ssh://git@ssh.dev.azure.com:22/v3/o/p/r`** | **`o / p / r`** (new) |
| **`ssh://git@ssh.dev.azure.com:7999/v3/o/p/r`** | **`o / p / r`** (new) |
| `https://o.visualstudio.com/p/_git/r` | `o / p / r` |
| `https://o.visualstudio.com/DefaultCollection/p/_git/r` | `o / p / r` |
| `https://dev.azure.com/o/My%20Project/_git/r` | `o / My Project / r` |
| `https://dev.azure.com/o/p/_git/r.git` | `o / p / r` |

## Testing

`tests/run-detect-forge-tests.sh` builds throwaway repos with `make_repo` and never
touches the network, so this stays a Layer-1 fixture test running in seconds.
`tests/run-all.sh` discovers it with `find`, so no registration is needed.

New cases: the two ported ADO forms, the ported Forgejo form, and an explicit
regression case labelling the existing `:v3` no-port form so a future reader knows
it is load-bearing.

## Out of scope

- `_forge_host` — already correct for both shapes.
- IPv6 literal hosts (`ssh://git@[::1]:22/…`). No such remote exists in this
  workflow, and supporting bracket syntax would need its own parsing branch.
- The other `/issues` Azure DevOps defects — those are #386.
