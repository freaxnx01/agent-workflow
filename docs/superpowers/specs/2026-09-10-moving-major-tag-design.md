# Moving major tag: update `vX` as part of publishing a release

**Issue:** [#261](https://github.com/freaxnx01/agent-workflow/issues/261)
**Date:** 2026-09-10
**Status:** approved

## Problem

Consumer repos pin the reusable workflow by major tag:

```yaml
uses: freaxnx01/agent-workflow/.github/workflows/agent-implement.yml@v1
with:
  pipeline-ref: v1
```

`v1` is meant to be a **moving major tag** that follows the newest `v1.x.y` release —
the convention `actions/checkout` and friends use. Nothing moves it. It is updated by
memory, and memory has now demonstrably failed twice.

### Evidence that this recurs

This is not a one-time catch-up problem. The catch-up was *already performed once* and
the drift came straight back:

| Date | Event | `v1` after |
|---|---|---|
| 2026-08-18 | Maintainer decision on #261: move `v1` → `v1.11.1` | `v1.11.1` (`0cf6554c`) |
| 2026-08-25 | `v1.12.0` cut | still `v1.11.1` |
| 2026-08-25 | `v1.13.0` cut | still `v1.11.1` |

Two releases shipped within a week of the manual fix and `v1` followed neither. Any
solution that depends on a human remembering a step has already been falsified.

### Why the drift is invisible

Staleness is silent by construction. Runs stay green; consumers just execute old code.
There is no signal in a consumer repo that its pinned ref has fallen behind, and none
in this repo that a release failed to propagate. Both discoveries so far were
accidents:

- **`startup_failure`** — a consumer set `self-fix: true`, an input that exists only on
  `main`. Loud, but only because the consumer happened to use a newer input.
- **Silent turn-budget starvation** (#261 comment, 2026-08-27) — `classify-turns.sh`
  does not exist at `v1`, so a `@v1` consumer silently got `max_turns: 30` and died at
  `error_max_turns`. This one *looks like a legitimate agent failure*: plausible cost
  table, `ai:failed` label, nothing pointing at the pinned ref. $3.69 to produce
  nothing, and the natural response — re-dispatch — burns it again.

## Approach

Move the major tag in **`.github/workflows/release.yml`**, the workflow that already
fires on a pushed semver tag.

### Why there, and not the alternatives

**Rejected: the `justfile` `push-release` recipe.** It is the obvious place and it is
wrong. `push-release` runs `git push origin main "v$v"` — it assumes the release is on
`main`. But `v1.12.0` and `v1.13.0` were cut on the `backport-v1.12.0-claude-timeout`
branch, so whatever produced them was not this recipe, and a fix living there would
have missed exactly the two releases that caused the current gap. Local recipes are
also opt-in: the failure mode is a human not running the step, so the fix must not be
another step a human has to run.

**Rejected: a scheduled reconciler** (a nightly job that moves `vX` to the newest
release). It repairs drift instead of preventing it, so there is always a window where
consumers run a stale pipeline, and it adds a second source of truth for where `vX`
should point.

**Chosen: extend `release.yml`.** It is triggered by the tag itself, so it fires
wherever the release was cut from — `main` or a backport branch — which is precisely
the case the `justfile` route misses. It is already the thing that reacts to a release.

### Pre-releases are already excluded

The existing trigger is:

```yaml
on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'
```

GitHub tag filter patterns are fully anchored, so `v1.12.0-rc.1`, `-alpha.N` and
`-beta.N` never fire this workflow. The AC's pre-release requirement is satisfied by
the trigger that already exists — **no new guard is needed in the trigger**.

The script must still defend itself, because it is reachable by hand and by a future
caller: it validates the tag shape it was given and refuses anything with a
pre-release suffix rather than trusting its caller.

## The one piece of real logic: only ever move forward

This is the part worth getting right, and it is not "move `vX` to the tag that was just
pushed".

Releases are not always cut in ascending order. Given `v1.13.0` already exists, pushing
a late hotfix `v1.11.2` off the old line must **not** drag `v1` backwards — that would
silently downgrade every consumer, the same failure this issue exists to prevent, in
the other direction.

So the rule is:

> Move `vX` to the pushed tag **only if** that tag is the highest non-prerelease
> `vX.*.*` in the repository.

Otherwise, skip and say so in the job summary. Concretely:

| Existing `v1.*` tags | Pushed tag | Action |
|---|---|---|
| `v1.11.1` | `v1.12.0` | move `v1` → `v1.12.0` |
| `v1.11.1`, `v1.13.0` | `v1.11.2` | **skip** — `v1.13.0` is higher |
| `v1.13.0` | `v1.13.0` (re-run) | no-op, already there |
| `v1.13.0` | `v2.0.0` | move `v2` → `v2.0.0`; `v1` untouched |
| `v1.13.0` | `v1.14.0-rc.1` | never triggers |

Version comparison must be semver-aware, not lexical: `v1.9.0` < `v1.10.0`, which
string sorting gets wrong. `sort -V` handles this; the script pins that rather than
rolling its own comparison.

### The moving tag may point off `main`

`v1` → `v1.13.0` points at a commit on a backport branch, not an ancestor of `main`.
That is correct and intended: the moving tag follows the newest *release*, and a
backport release is a release. A design that assumed "`vX` lives on `main`" would be
unable to express the repo's actual history. Nothing in the chosen approach assumes it.

A consequence worth naming: `v1` and `main` can diverge, so "what is released?" is
answered by the tags, never by `main`. The catch-up in scope here moves `v1` four
commits forward onto the backport line; the 145 commits on `main` are deliberately not
shipped by it.

## Scope boundary

**In scope:** the automation, its tests, and the docs that describe the convention.

**Out of scope — the one-time catch-up.** Moving `v1` from `v1.11.1` to `v1.13.0` today
is a manual maintainer action (it force-updates a tag every consumer follows). It is
tracked on the issue, not implemented by this change. The automation is what stops the
next one.

**Out of scope — surfacing the resolved ref in run output.** The 2026-08-27 comment
suggests logging `github.workflow_ref` so "which pipeline version am I running?" is
answerable from a run log. That is a genuinely good idea and a different change; file
separately.

**Out of scope — offering consumers exact pinning + Dependabot.** Also raised on the
issue, also a separate change.

## Acceptance criteria

- [ ] Pushing a release tag `vX.Y.Z` updates the moving tag `vX` to the same commit,
      with no human step
- [ ] The major is derived from the pushed tag, never hardcoded to `1`
- [ ] Pre-release tags (`v1.14.0-rc.1`, `-alpha.N`, `-beta.N`) do not move the moving
      tag
- [ ] A pushed tag that is **not** the highest non-prerelease tag in its major line
      leaves the moving tag alone, and the skip is visible in the job summary
- [ ] Semver ordering, not lexical: `v1.10.0` is recognised as newer than `v1.9.0`
- [ ] Re-running for the same tag is idempotent
- [ ] Works for a release cut off a branch other than `main`
- [ ] The tag-move logic lives in `scripts/`, not inline in YAML, and has fixture tests
      covering every branch above
- [ ] `contents: write` is scoped to the job that needs it, not the workflow
- [ ] `docs/` states the convention: consumers pin `@vX`, `vX` follows the newest
      non-prerelease `vX.*.*`, and it may point off `main`

## Consequences

- Every `@vX` consumer picks up a new pipeline on its next dispatch after a release,
  with no review step. That is the convention working as designed, and it is also the
  reason the one-time catch-up stays manual.
- `v1` and `main` diverge until a release is cut from `main`. Anything merged to `main`
  and not released — including the 145 commits there now — reaches no consumer.
- The release workflow gains write access to refs. It force-updates exactly one ref
  pattern (`refs/tags/v<major>`) and nothing else.
