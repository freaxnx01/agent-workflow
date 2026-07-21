# Session state — 2026-07-20/21: rename + consolidation

Cold-resume note. Everything described here is **shipped and merged**; nothing is
in flight. Read this to orient, then go to "Next step".

## What this session did

Three pieces of work, all complete:

1. **Console hardening.** `--copy` became the default for installing user-level
   commands (#117), because symlinks pointed into a working tree — a checkout on
   the wrong branch dangled all 34 links in every repo. Cleared three weeks of
   markdownlint debt that had `main` red and branch protection decorative (#119).
   Relocated `/process-feedback` to the console (#118 + config#42).
2. **Rename.** `freaxnx01/agent-pipeline` → **`freaxnx01/agent-workflow`**
   (ADR-006), executed via
   `docs/superpowers/plans/2026-07-20-rename-to-agent-workflow.md`. Released as
   `v1.7.0` with the `v1` tag moved. Five of six consumers migrated.
3. **Consolidation.** All 46 user-level commands plus the `handoff-resume` hook
   now live in this repo (#128 + config#45), per
   `docs/superpowers/specs/2026-07-20-consolidate-command-surface-design.md`
   (**Accepted** — all four decisions resolved).

## Current architecture

| Repo | Holds |
|---|---|
| `agent-workflow` (this repo) | CI workflows + all 46 `commands/` + `hooks/` + `setup/link-commands.sh`, `setup/link-hooks.sh` |
| `config` | CLAUDE.md partials only, plus `oh-my-posh/`, `windows/`, and the one-URL bootstrap that delegates here |
| `dotfiles` | **archived** 2026-07-21 (abandoned chezmoi experiment) |
| `agent-skills` | public plugin marketplace — deliberately separate, see spec Non-goals |

Commands install as **copies**, never symlinks. Hooks likewise: `settings.json`
references the installed path, so a checkout on any branch cannot change
behaviour underfoot. Verified state: 46 commands, 0 broken, hook wired.

## Next step

**Nothing is queued.** The remaining work is in `docs/TODO.md` under
"Deferred — decide with the user before starting". The live item:

> `config` still does two jobs — it holds `oh-my-posh/` and `windows/` alongside
> the Claude partials. Decoupled from the command surface by spec decision §3, so
> it is independent cleanup.

**The user explicitly asked to be consulted on how to proceed before this is
started.** Do not begin it unprompted. `dotfiles` is no longer a candidate
destination (archived), so the open question is genuinely open: a new repo, a
rename inside `config`, or leave the content and fix the README instead.

Also deferred, needing no action here: `FlowHub-CAS-AISE#186` (last
`agent-pipeline` reference anywhere, blocked on its own AngleSharp advisory — the
user handles that repo manually).

## Process notes worth carrying

Three defects were introduced and caught downstream, not by self-check:

- A verify gate demanding zero old-name references forced the ADR-002 safety
  guard to **fail open**, and rewrote a quoted git tag message. The fix was to
  distinguish *runtime-resolving values* (flip at rename time) from *prose*.
- A reviewer's findings were dismissed as stale after checking the **filesystem**
  instead of committed content. They were real and reached `main` (#124).
- `git add -A` committed `.claude/handoff.md` twice. Both repos now gitignore it.

The pattern: verification repeatedly asserted more than it established. CI,
reviewers and pre-commit hooks caught all three — an argument for keeping those
gates strict.

## Key references

- ADRs: `docs/DECISIONS.md` (ADR-005 console, ADR-006 rename)
- Spec: `docs/superpowers/specs/2026-07-20-consolidate-command-surface-design.md`
- Plan: `docs/superpowers/plans/2026-07-20-rename-to-agent-workflow.md`
- Deferred work: `docs/TODO.md`
