# Rename `🧊 parked` to `parked` (#397)

**Date:** 2026-09-23
**Issue:** [#397](https://github.com/freaxnx01/agent-workflow/issues/397)
**Status:** approved — Option A (rename to ASCII everywhere)

## Problem

Azure DevOps **rejects emoji in tag names**:

```
az boards work-item update --id 2 --fields "System.Tags=🧊 parked"
→ ERROR: TF401407: The tag name is invalid. It contains invalid characters.  (rc=1)
```

Rejected with and without the space. Not a Unicode restriction — `übung` stores
fine; ADO refuses emoji specifically. So the parked label **cannot exist** on that
forge, by any client, and the convention does not port.

`🧊 parked` is the **only** emoji-bearing label in the entire scheme. Every other
label `scripts/ensure-issue-labels.sh` creates is already plain ASCII, so exactly
one label blocks portability.

Nothing is broken today, because the twelve unported commands guard on ADO and
stop. It breaks the moment #286 ports `/new`, `/parked` or `/roadmap`.

## Decision

**Rename the label to `parked` on all forges.** One name everywhere, nothing to map.

Rejected: a per-forge mapping (`🧊 parked` on GitHub/Forgejo, `parked` on ADO). It
avoids a migration, and a partial seam already exists — `check-attempt-cap.sh`
parameterises `PARK_LABEL` — but it makes every label-touching command consult a
mapping forever, to preserve decoration on the one label in the scheme that carries
any. A permanent tax to avoid a one-time rename.

## Scope

38 files reference the emoji. They are **not** equal and must not be swept
uniformly:

| Kind | Files | Action |
|---|---|---|
| Functional code paths | `scripts/autopilot.sh`, `scripts/ensure-issue-labels.sh`, `scripts/check-attempt-cap.sh`, `scripts/lib/ai-funnel.sh`, `scripts/lib/autopilot-candidates.sh`, 1 test | **Change** |
| Command prompts | 12 files under `commands/` and `commands/gh/` | **Change** |
| Live docs | `TODO.md`, `docs/CONSUMER-SETUP.md`, cheat sheet | **Change** |
| Historical records | `docs/superpowers/specs/`, `docs/superpowers/plans/`, `docs/ai-notes/`, `CHANGELOG.md` | **Leave alone** |

Rewriting the historical set would falsify the record: those documents describe
what was true when written. A spec from July that says `🧊 parked` is not a bug.

## Migration — rename in place, never delete-and-create

```bash
gh label edit '🧊 parked' --name 'parked' --repo <owner>/<repo>
```

`gh label edit --name` renames **in place** and every issue keeps the label.
Deleting and re-creating would silently unpark every parked issue — the exact
outcome the label exists to prevent, and unrecoverable without the events API.

This repo has 2 issues carrying it. Consumer repos are unknown from here and need a
documented step rather than a guess.

## `PARK_LABEL` stays

`check-attempt-cap.sh`'s `PARK_LABEL="${PARK_LABEL:-🧊 parked}"` keeps its override
seam; only the default changes to `parked`. It costs nothing and lets a consumer
that has not migrated yet keep working by exporting the old value.

## Acceptance criteria

- [ ] `scripts/ensure-issue-labels.sh` creates `parked`, not `🧊 parked`
- [ ] All 6 functional code paths match on `parked`
- [ ] `PARK_LABEL` still overrides, defaulting to `parked`
- [ ] All 12 command prompts say `parked`
- [ ] **No historical spec, plan, ai-note or CHANGELOG entry is modified**
- [ ] The label on this repo is **renamed in place**; both currently-parked issues keep it
- [ ] `docs/CONSUMER-SETUP.md` documents the one-line rename for existing consumers
- [ ] No emoji remains in any label *name* anywhere in the scheme
- [ ] `shellcheck -x`, `markdownlint` and `tests/run-all.sh` stay clean

## Testing

`scripts/lib/autopilot-candidates.sh` and `ai-funnel.sh` have existing fixture
tests; their fixtures carry the label string and must be updated with the code, in
the same commit, so a stale fixture cannot mask a missed path.

The migration itself is verified by rename-then-list: both parked issues must still
be returned by a `--label parked` query afterwards.

## Out of scope

- **#386** — deleting `/issues`' bare-word rationale. Related but separate; that
  paragraph is wrong for its own reasons.
- **#286** — the ports that consume this decision.
- Other emoji in label *descriptions* or in prose. Only label **names** are
  constrained by ADO.
