# Consolidate the personal command surface into one repo

**Status:** Accepted — all four decisions resolved (§1 by ADR-006; §2–§4 on 2026-07-21)
**Date:** 2026-07-20
**Relates to:** ADR-005 (operator console lives here), PR #117 (`--copy` default),
PR #118 + config#42 (`/process-feedback` relocated), PR #119 (lint debt cleared)

## Problem

The 46 user-level slash commands are split across two repos on a boundary that
does not describe either side.

| Repo | Count | Install | Charter |
|---|---|---|---|
| `agent-workflow` — `commands/` | 35 | copied (PR #117) | issue-workflow console |
| `config` — `claude/commands/` | 11 | symlinked | "Claude Code configuration **plus other personal config**" |

Three symptoms:

1. **`config` does two unrelated jobs.** Its own README says so: Claude Code
   configuration *"plus other personal config (oh-my-posh, Windows)."* The name
   describes only the second half. Slash commands are not configuration at all —
   they are tooling that happens to install by copying files, which is what made
   `config` look like a plausible home in the first place.
2. **The misplacement is ongoing, not historical.** `/process-feedback` landed in
   `config` on 2026-07-16 — six commits after the batch that moved the console
   *out*. It triages notes into tracker Issues and `TODO.md`: console work by any
   reading. `config` is still the default gravity well for anything Claude-shaped.
   (Relocated on 2026-07-20 by #118 + config#42, which is why the counts above read
   35/11 rather than 34/12.)
3. **Two places to look.** Every "where does this command live?" question costs a
   lookup, and every new command re-opens the placement debate.

## Key insight that shapes the design

**PR #117 removed the only structural objection to consolidating.**

Before it, `config` had to keep `/update-commands`, `/commands`, `/clear-check`
and `/wt:status` because the console was symlinked into `agent-pipeline`'s
*working tree*: a checkout parked on the wrong branch dangled all 34 links (it
did, on 2026-07-20). Had the repair tool lived in the same repo, the bad branch
would have taken out the tool needed to fix it — a dependency cycle with no
in-design escape. `config` was immune only because it is effectively always on
`main`.

With `--copy` as the default, installed commands are pinned and survive any
checkout. The cycle is gone. Every remaining objection is preference-grade:

- changelog churn in a consumer-facing, SemVer-tagged repo;
- the name `agent-pipeline` not stretching over `/wt:*` and session hygiene.

Both are real but neither is structural.

## Non-goals

- Reversing ADR-005. The console's move here was correct and is not reopened.
- Touching `.claude/commands/` (project-scoped `commit`, `push`, `ui-*`).
  ADR-005 §2's two-surface distinction stands.
- Folding these into `agent-skills`. Its charter is explicitly the opposite —
  *"sharable, non-personal skills. Separate from personal slash commands"* — and
  it distributes via `.claude-plugin/marketplace.json` to other people, a
  different mechanism from `~/.claude/commands/` on your machines. Rejected.
- Renaming any repo. Noted as a consequence (§5), not proposed here.

## The 11 in question

| Group | Commands | Assessment |
|---|---|---|
| Worktree | `/wt:status` `/wt:finish` | generic git; no pipeline tie, no config tie — homeless either way |
| Phase handoff | `/handoff` `/pickup` | **coupled**: paired with `config/claude/hooks/handoff-resume.sh` (`SessionStart(clear)`) |
| Session hygiene | `/loose-ends` `/clear-check` `/todo` `/wrap-up` | Claude Code behaviour, forge-agnostic |
| Meta | `/commands` `/update-commands` | manage the install itself |
| Superpowers | `/subagent-driven` | pairs with a `config` CLAUDE.md partial |

Only `/handoff`+`/pickup` and `/subagent-driven` need more than a file move —
their other halves (a hook, a partial) live in `config` and are installed by its
`setup/00-*` and `setup/02-*` steps.

## Design

### Option A — consolidate all 46 into `agent-workflow` (proposed)

Move the 11 into `commands/`. `config` retains partials, hooks, `oh-my-posh/`,
`windows/`, and the bootstrap. `setup/01-claude-commands.sh` keeps its clone +
delegate step and stops installing commands of its own.

The `/handoff` hook moves too — a command and its hook must not be split across
repos. That means `agent-workflow` grows a hooks surface, and `config`'s
`setup/02-claude-hooks.sh` delegates the same way `01` already does.

- **For:** one home, one lookup, no recurring placement debate; the misplacement
  problem cannot recur.
- **Against:** `agent-pipeline`'s name then covers worktree helpers and session
  hygiene, which are not a pipeline. Trades `config`'s naming lie for a new one.
  `config` also becomes a thin shim whose only Claude content is partials.

### Option B — drain `config` into the existing `dotfiles` repo

**Correction (2026-07-21):** an earlier draft of this spec called
`freaxnx01/dotfiles` "empty". It is not. It is an abandoned **chezmoi** repo
created 2026-03-25 and untouched since (created and pushed four seconds apart),
containing `private_dot_claude/` with `commands/`, `skills/`, `settings.json`
and `empty_CLAUDE.md`. chezmoi is not installed on the working host and there is
no local source directory.

That makes it a **third, competing mechanism for managing `~/.claude`** —
alongside `config`'s shell installers and `agent-workflow`'s link step — not a
blank destination. Draining `oh-my-posh/` and `windows/` into it would mix
paradigms (chezmoi source-state naming vs plain files + installers) and revive
tooling nobody uses.

- **For:** would fix `config` doing two jobs; no new repo needed.
- **Against:** does **not** deliver the stated goal of one repo; and the
  destination carries an unresolved tooling question of its own.

### Option C — status quo plus cross-references

One pointer line in each README naming the other surface. Near-zero cost, fixes
only discoverability.

### Recommendation

**A, and do not touch `dotfiles` yet** (revised 2026-07-21).

The original recommendation was "A preceded by B's cheap half," on the belief
that `dotfiles` was an empty destination. It is not (see Option B), so the drain
is no longer cheap: it forces a decision about whether chezmoi is adopted,
which is unrelated to the command surface and would block a move that is
otherwise ready.

Sequence: move the 11 + the hook into `agent-workflow` → then decide `dotfiles`
separately (adopt chezmoi and migrate to it, or archive the repo and keep the
installer model). `config`'s "plus other personal config" incoherence is real
but is now a **separate** piece of work, not a prerequisite.

## Blast radius / risks

- **Bootstrap is load-bearing.** `curl | bash` on a fresh machine must still
  work. `config` is public specifically to allow no-auth clone; if it stops
  being the entry point, the documented bootstrap URL changes and any machine
  following the old README breaks. Mitigate: keep `config`'s bootstrap as a
  redirecting shim for one cycle, and verify on a scratch container before
  retiring it.
- ~~**Hook migration is the risky step.**~~ **Downgraded 2026-07-21** — see
  decision §2. `settings.json` points at the *installed* path
  (`$HOME/.claude/hooks/handoff-resume.sh`), never at the repo, so the hook's
  source repo can change without touching `settings.json` at all. `jq` remains a
  runtime dependency. The residual risk is ordinary: `02-claude-hooks.sh` must
  gain its delegation step in the same cycle the source moves.
- **Changelog noise.** `agent-workflow` is SemVer-tagged with a moving `v1` that
  consumers pin. Command edits would churn a consumer-facing changelog. Mitigate:
  scope `cliff.toml` to exclude `commands/` and `setup/`, or use a `chore(console)`
  type filtered from release notes.
- **Imported lint debt blocks the merge gate.** Files arrive from an unlinted repo
  into one with a blocking `pre-commit` job. Quantified in open decision §4 — 10
  errors, 3 files, of which 2 genuinely carry over. Must be fixed inside the
  moving PR.
- **Per-file history** stays in `config`'s log (same as ADR-005 §4 — copy +
  `git rm`, no history graft). Accepted precedent.
- **Low reversibility on naming.** Renaming `agent-pipeline` later breaks every
  consumer's `uses:` reference and the `v1` tag contract. Decide the name
  question *before* moving, not after.

## Success criteria

1. `find ~/.claude/commands -name '*.md' | wc -l` → 46, with 0 dangling links.
2. Every command resolves to exactly one source repo; no duplicates.
3. A fresh machine reaches a working 46-command install from one documented URL.
4. `SessionStart(clear)` still fires `handoff-resume.sh`; `/handoff` → `/clear` →
   `/pickup` round-trips.
5. Each repo's README describes everything in it without a "plus other …" clause.
6. `/process-feedback` lives with the console.

## Decisions

All four are resolved; none blocks execution.

1. **Name.** Does `agent-pipeline` become the home for non-pipeline commands
   under its current name, or is a rename part of this work? Renaming has a
   consumer-visible cost (§ blast radius) and must be settled first.
   **Resolved by [ADR-006](../../DECISIONS.md#adr-006--rename-agent-pipeline-to-agent-workflow-2026-07-20):**
   the repo is renamed to `agent-workflow`, settling the naming question ahead
   of this consolidation.
2. **Hook ownership.** ~~Confirm the `SessionStart` hook moves with `/handoff`.~~

   **Resolved (2026-07-21): the hook moves.** Investigation downgraded this from
   "the risky step" to a one-line change. `setup/02-claude-hooks.sh` **copies**
   `handoff-resume.sh` to `~/.claude/hooks/` and wires `settings.json` to the
   *installed* path (`$HOME/.claude/hooks/handoff-resume.sh`) — never to the repo
   path. The source repo is therefore invisible to `settings.json`: moving it
   means changing that script's `SRC` and adding a delegation step exactly like
   `01-claude-commands.sh` already does for the console. No `settings.json`
   migration, no half-migrated state to fear. `jq` stays a runtime dependency
   either way.
3. **Scope order.** ~~Drain `dotfiles` first, or move the 11 first?~~

   **Resolved (2026-07-21): move the 11 first; `dotfiles` is deferred and
   decoupled.** The premise of draining first was that `dotfiles` was an empty
   destination. It is an abandoned chezmoi repo that already claims `~/.claude`
   (see Option B), so the drain now carries its own unresolved question — adopt
   chezmoi, or archive it — which has nothing to do with the command surface and
   must not gate it. `config` keeping `oh-my-posh/` and `windows/` for now is
   untidy but harmless.
4. **Markdownlint reconciliation.** `config` has **no** markdownlint config, no
   pre-commit hook, and no lint workflow — its only CI is `add-to-project.yml`.
   So this is not two configs disagreeing; it is one repo that lints and one that
   never has. Every file moved here arrives unlinted and lands in a repo whose
   `pre-commit` gate blocks merges.

   This is not hypothetical. The 2026-07-12 console move imported **18 errors**
   and helped keep `main` red for three weeks (cleared in #119), and moving the
   single `/process-feedback` file re-broke the gate on the very next PR (#118),
   caught only because the branch was rebased onto a now-green `main`.

   Measured cost for the remaining 11, linted against this repo's
   `.markdownlint-cli2.yaml` — **10 errors in 3 files**:

   | File | Errors | Rules |
   |---|---|---|
   | `README.md` | 8 | MD032 ×5, MD036 ×3 |
   | `wt/status.md` | 1 | MD040 |
   | `commands.md` | 1 | MD032 |

   Nine of the eleven command files are already clean, and `README.md` is
   rewritten by the move anyway — so the real carry-over is **2 errors**.
   Small, but it must be fixed *in the moving PR*, not after, or `main` goes red
   again and every unrelated PR is blocked behind it.

   **Resolved (2026-07-21): fix-on-arrival, inside the moving PR.** Two errors
   genuinely carry over — not worth standing up a lint toolchain to catch. The
   deciding evidence is behavioural: this class of debt has now broken `main`
   twice (the 2026-07-12 console move, and `/process-feedback` in #118, caught
   only because that branch happened to be rebased onto a freshly-green `main`).
   Fixing inside the moving PR is what prevents a third.

   Follow-up, explicitly **not** a blocker: give `config` its own markdownlint +
   pre-commit once it settles. Under the revised §3 it survives as the partials +
   hooks + bootstrap repo, so it keeps enough markdown to be worth linting — but
   that is hygiene for later.

## Done

`/process-feedback` → `commands/` — landed 2026-07-20 via #118 + config#42. It was
console work, four days old, and correct under every option above.
