# Consolidate the personal command surface into one repo

**Status:** Draft — three open decisions block acceptance (§6)
**Date:** 2026-07-20
**Relates to:** ADR-005 (operator console lives here), PR #117 (`--copy` default)

## Problem

The 46 user-level slash commands are split across two repos on a boundary that
does not describe either side.

| Repo | Count | Install | Charter |
|---|---|---|---|
| `agent-pipeline` — `commands/` | 34 | copied (PR #117) | issue-workflow console |
| `config` — `claude/commands/` | 12 | symlinked | "Claude Code configuration **plus other personal config**" |

Three symptoms:

1. **`config` does two unrelated jobs.** Its own README says so: Claude Code
   configuration *"plus other personal config (oh-my-posh, Windows)."* The name
   describes only the second half. Slash commands are not configuration at all —
   they are tooling that happens to install by copying files, which is what made
   `config` look like a plausible home in the first place.
2. **The mis-file is ongoing, not historical.** `/process-feedback` landed in
   `config` on 2026-07-16 — six commits after the batch that moved the console
   *out*. It triages notes into tracker Issues and `TODO.md`: console work by any
   reading. `config` is still the default gravity well for anything Claude-shaped.
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

## The 12 in question

| Group | Commands | Assessment |
|---|---|---|
| Worktree | `/wt:status` `/wt:finish` | generic git; no pipeline tie, no config tie — homeless either way |
| Phase handoff | `/handoff` `/pickup` | **coupled**: paired with `config/claude/hooks/handoff-resume.sh` (`SessionStart(clear)`) |
| Session hygiene | `/loose-ends` `/clear-check` `/todo` `/wrap-up` | Claude Code behaviour, forge-agnostic |
| Meta | `/commands` `/update-commands` | manage the install itself |
| Superpowers | `/subagent-driven` | pairs with a `config` CLAUDE.md partial |
| Feedback | `/process-feedback` | **mis-filed**: console work, belongs here regardless of this spec |

Only `/handoff`+`/pickup` and `/subagent-driven` need more than a file move —
their other halves (a hook, a partial) live in `config` and are installed by its
`setup/00-*` and `setup/02-*` steps.

## Design

### Option A — consolidate all 46 into `agent-pipeline` (proposed)

Move the 12 into `commands/`. `config` retains partials, hooks, `oh-my-posh/`,
`windows/`, and the bootstrap. `setup/01-claude-commands.sh` keeps its clone +
delegate step and stops installing commands of its own.

The `/handoff` hook moves too — a command and its hook must not be split across
repos. That means `agent-pipeline` grows a hooks surface, and `config`'s
`setup/02-claude-hooks.sh` delegates the same way `01` already does.

- **For:** one home, one lookup, no recurring placement debate; the mis-file
  problem cannot recur.
- **Against:** `agent-pipeline`'s name then covers worktree helpers and session
  hygiene, which are not a pipeline. Trades `config`'s naming lie for a new one.
  `config` also becomes a thin shim whose only Claude content is partials.

### Option B — drain `config` into the existing `dotfiles` repo

`freaxnx01/dotfiles` exists and is **empty**. Move `oh-my-posh/` and `windows/`
there; `config` keeps only Claude Code material and its README loses the "plus"
clause. The command split stays as ADR-005 left it, but now sits on a boundary
that honestly describes both sides: *pipeline console* vs *Claude Code
configuration*.

- **For:** fixes the root cause (`config` doing two jobs) rather than relocating
  a symptom; no new repo; smallest diff; both names become honest.
- **Against:** does **not** deliver the stated goal of one repo. Two lookups
  remain.

### Option C — status quo plus cross-references

One pointer line in each README naming the other surface. Near-zero cost, fixes
only discoverability.

### Recommendation

**A, preceded by B's cheap half.** The stated goal is one repo, and #117 cleared
the blocking objection — but `config` should shed `oh-my-posh/` and `windows/`
into `dotfiles` either way, since that content is unrelated to both candidates
and its presence is what made `config` incoherent to begin with. Doing B's drain
first makes A a clean two-repo end state (`agent-pipeline` = all workflow +
commands + hooks; `dotfiles` = machine setup + bootstrap) rather than leaving a
`config` shim behind.

Sequence: drain `dotfiles` → move the 12 + the hook → collapse or rename what
remains of `config`.

## Blast radius / risks

- **Bootstrap is load-bearing.** `curl | bash` on a fresh machine must still
  work. `config` is public specifically to allow no-auth clone; if it stops
  being the entry point, the documented bootstrap URL changes and any machine
  following the old README breaks. Mitigate: keep `config`'s bootstrap as a
  redirecting shim for one cycle, and verify on a scratch container before
  retiring it.
- **Hook migration is the risky step**, not the command moves. `handoff-resume.sh`
  is wired into `settings.json` by `setup/02-claude-hooks.sh` and needs `jq` at
  runtime. A half-migrated state breaks `SessionStart(clear)` silently.
- **Changelog noise.** `agent-pipeline` is SemVer-tagged with a moving `v1` that
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

## Open decisions

These block acceptance:

1. **Name.** Does `agent-pipeline` become the home for non-pipeline commands
   under its current name, or is a rename part of this work? Renaming has a
   consumer-visible cost (§ blast radius) and must be settled first.
2. **Hook ownership.** Confirm the `SessionStart` hook moves with `/handoff`.
   If hooks stay in `config`, Option A is off the table — splitting a command
   from its hook is worse than today's split.
3. **Scope order.** Drain `dotfiles` first (recommended), or move the 12 first
   and treat the drain as follow-up?
4. **Markdownlint reconciliation.** `config` has **no** markdownlint config, no
   pre-commit hook, and no lint workflow — its only CI is `add-to-project.yml`.
   So this is not two configs disagreeing; it is one repo that lints and one that
   never has. Every file moved here arrives unlinted and lands in a repo whose
   `pre-commit` gate blocks merges.

   This is not hypothetical. The 2026-07-12 console move imported **18 errors**
   and helped keep `main` red for three weeks (cleared in #119), and moving the
   single `/process-feedback` file re-broke the gate on the very next PR (#118),
   caught only because the branch was rebased onto a now-green `main`.

   Measured cost for the remaining 12, linted against this repo's
   `.markdownlint-cli2.yaml` — **10 errors in 3 files**:

   | File | Errors | Rules |
   |---|---|---|
   | `README.md` | 8 | MD032 ×5, MD036 ×3 |
   | `wt/status.md` | 1 | MD040 |
   | `commands.md` | 1 | MD032 |

   Nine of the twelve command files are already clean, and `README.md` is
   rewritten by the move anyway — so the real carry-over is **2 errors**.
   Small, but it must be fixed *in the moving PR*, not after, or `main` goes red
   again and every unrelated PR is blocked behind it.

   Decide: fix-on-arrival (fold into the move PR, recommended), or give `config`
   its own markdownlint + pre-commit setup first so files are clean before they
   travel? The latter is more correct and more work; it only pays off if `config`
   survives this consolidation as a going concern, which under Option A it
   largely does not.

## Immediate, decision-independent

`/process-feedback` → `commands/`. It is console work, four days old, and
correct under every option above.
