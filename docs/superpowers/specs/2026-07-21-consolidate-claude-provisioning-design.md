# Consolidate Claude provisioning into agent-workflow — Design

**Issue:** #133 · **ADR:** 007 · **Status:** Accepted · **Date:** 2026-07-21

Follow-on to #128, which moved the 46 commands and the `handoff-resume` hook here.
This moves what remained: the three CLAUDE.md partials and the provisioning scripts.

## Problem

`config` still holds Claude content (`claude/`, 3 partials + README) and is still the
Claude bootstrap entry point (`setup/`, 4 scripts). It also holds `oh-my-posh/` (3 files)
and `windows/` (8 files), which have nothing to do with Claude and are installed manually.

So `config` is 4/31 Claude content, yet owns the provisioning contract for a surface that
now lives entirely in `agent-workflow`. Two of its four setup scripts exist only to clone
this repo and call its scripts.

### Why the two moves must be bundled

Moving `setup/` alone does not remove the cross-repo dependency — it **inverts** it.
`00-claude-partials.sh` `@`-imports config's own `claude/*.md`, so a relocated bootstrap
would have to clone `config` to find them:

| | Cross-repo clone |
|---|---|
| Today | `config` clones `agent-workflow` |
| `setup/` alone moves | `agent-workflow` clones `config` |
| **Both move** | **none** |

Only moving both eliminates it. This is the design's central constraint.

## End state

```text
agent-workflow/                        config/
├── commands/   (46)                   ├── oh-my-posh/   (3)
├── hooks/      (1)                    ├── windows/      (8)
├── partials/   (3)      ← NEW         ├── docs/
└── setup/                             ├── README.md     → points here
    ├── link-commands.sh               └── setup/
    ├── link-hooks.sh                      └── bootstrap.sh  ← deprecation stub
    ├── link-partials.sh ← NEW
    └── bootstrap.sh     ← MOVED
```

`agent-workflow` owns every Claude thing, content and provisioning. `config` becomes an
honest machine-setup repo: shell, prompt, Windows tooling.

## Inventory

### Moves

| From | To |
|---|---|
| `config/claude/task-checklist.md` | `partials/task-checklist.md` |
| `config/claude/skill-authoring.md` | `partials/skill-authoring.md` |
| `config/claude/subagent-driven-default.md` | `partials/subagent-driven-default.md` |
| `config/claude/README.md` | `partials/README.md` |
| `config/setup/bootstrap.sh` | `setup/bootstrap.sh` |

### Rewritten

`config/setup/00-claude-partials.sh` → `setup/link-partials.sh`, adopting this repo's
`link-*.sh` conventions: self-clone with `--no-sync` opt-out, and source from the script's
own checkout (`$(dirname "${BASH_SOURCE[0]}")/../partials`) rather than a `$HOME`-derived
guess — the same fix `link-hooks.sh` documents, so a scratch `$HOME` cannot silently copy
nothing while reporting success.

### Deleted

`config/setup/01-claude-commands.sh` and `config/setup/02-claude-hooks.sh`. Both exist only
to clone `agent-workflow` and call its link step, and `link-commands.sh` / `link-hooks.sh`
already self-clone. Once `bootstrap.sh` sits beside them, the shims are dead weight.

### Edited in this repo

- `commands/update-commands.md` — hardcodes `config/setup/01-claude-commands.sh`; repoint.
- `README.md` — document the `partials/` surface and the new bootstrap URL.
- `docs/DECISIONS.md` — ADR-007.
- `docs/TODO.md` — close out the deferred item.
- `CHANGELOG.md` + `VERSION` — minor bump (1.7.0 → 1.8.0); new surface, no breaking change
  for pipeline consumers.

## Bootstrap flow

```text
curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-workflow/main/setup/bootstrap.sh | bash [-s -- --copy]
  ├─ clone/pull agent-workflow
  ├─ link-partials.sh          → @-imports into ~/.claude/CLAUDE.md
  ├─ link-commands.sh [--copy] → 46 commands into ~/.claude/commands/
  └─ link-hooks.sh             → handoff-resume + settings.json wiring
```

No `config` clone at any point.

`--copy` must pass through both the deprecation stub and `bootstrap.sh` into
`link-commands.sh`. Losing it means Windows and other no-symlink filesystems silently get
symlinks — the hazard #117 was raised for.

## `link-partials.sh` behaviour

Idempotent, marker-delimited rewrite of `~/.claude/CLAUDE.md`, preserving all unrelated user
content. A single `awk` pass strips three things before appending the fresh block:

1. The **current** block, `<!-- BEGIN provisioned:claude-partials (managed by setup/link-partials.sh) -->` — idempotency.
2. The **legacy** block, `<!-- BEGIN provisioned:claude-partials (managed by setup/00-claude-partials.sh) -->` — verbatim match.
3. Any free-floating `@`-line pointing into `config/claude/`.

Steps 2 and 3 are the migration. Without them the old block survives — the installer only
strips markers it matches exactly — and since the `config` clone remains on disk, both sets
of partials load. That failure is silent: no error, no missing file, just duplicated
instructions.

Mark the legacy handling with a removal note; it can go once every machine is migrated.

Partials are `@`-imported by absolute path, so the emitted lines use `~/...` for
cross-platform home resolution, as today.

## Hazards

| Hazard | Mitigation |
|---|---|
| `update-commands.md` points into `config/setup/` — and it is the recovery path, so a stale copy cannot repair itself | Fix in the **same commit** as the move |
| Stale marker block → partials load twice, silently | Legacy sweep, plus a migration test |
| `--copy` lost through stub or bootstrap | `bash -s -- "$@"` passthrough, plus an explicit test |
| Old bootstrap URL invoked from memory or old notes | Deprecation stub forwards and prints the new URL |
| Installed `~/.claude/commands/` drifts from repo | Out of scope; pre-existing, noted only |

## Testing

`tests/run-script-tests.sh` covers 19 scripts under `scripts/` but **nothing under
`setup/`** — installers are currently untested. `link-partials.sh` rewrites a user file and
carries the migration logic, so it gets the first such coverage, using the harness's
existing `assert_contains` / `pass` / `fail` helpers against a scratch `$HOME`:

| Test | Asserts |
|---|---|
| Idempotency | Two consecutive runs leave `CLAUDE.md` byte-identical |
| Migration | Seeded legacy block + stray `config/claude` lines → exactly one block, new paths only, zero `config/` references |
| Fresh machine | Empty `$HOME` → block created, file well-formed |
| Non-destructive | Unrelated user content survives verbatim, order preserved |
| `--copy` passthrough | Flag reaches `link-commands.sh` through `bootstrap.sh` |

## Non-goals

- `oh-my-posh/` and `windows/` stay in `config`, installed manually as today.
- Folding `agent-skills` in. Its charter is sharable, non-personal skills distributed via
  `.claude-plugin/marketplace.json` — a different audience and mechanism. Unchanged from the
  #128 spec's Non-goals.
- Repo renames.
- The `retry-dispatch.sh` `CONSUMER_WORKFLOW` defect and the OpenRouter 402 blocking #114.
  Both found while investigating; both tracked separately.

## Self-review

- **Placeholders:** none. Every file path, marker string and script name is concrete.
- **Consistency:** the bundling argument (§Problem) matches the deletion of the two shims
  (§Inventory) and the "no `config` clone" claim (§Bootstrap flow). Partial counts (3 + README)
  agree throughout.
- **Scope:** one plan's worth — a file move, one rewritten script, one deleted pair, four
  doc edits, five tests.
- **Ambiguity:** "moves" means `git mv` semantics across repos, i.e. added here and deleted
  there in the same PR pair; the two repos are separate, so this is two PRs landing together,
  not one atomic commit. Sequencing is the plan's job.
