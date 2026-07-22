# Session state — skills delivery + `/process-feedback` merge (2026-07-21)

Companion to `2026-07-21-session-state.md`, which belongs to the **#133 provisioning
consolidation** session. This file covers a *different* session running concurrently in
the same clone. Both were live at once — see Collisions below.

## Status: work is merged. No in-flight implementation phase.

Everything this session designed is on `main`. What remains are two follow-ups, neither
started.

## Landed on `main`

| Commit | What |
|---|---|
| `aa9af72` | Root `README.md` — the repo had none. Documents the four slash-command delivery paths (agent-workflow copies → `~/.claude/commands/`; `agent-skills` plugins; `/sync-ai-instructions`; project-scoped). Also corrected `commands/README.md`, which claimed `link-commands.sh` symlinks and had `--copy`/`--link` backwards. |
| `ba32d8e` | Reordered the source map so `/sync-ai-instructions` (#3) precedes project-scoped (#4) — sync *produces* project-scoped files. Expanded `ui-*` into its gated four-phase table. |
| `92bebcd` | Linked the `config` repo in the related-repos table. |
| `f40ab6d` | `AGENT-NOTES.md` — records that `main`'s protection is real but `enforce_admins: false` exempts the owner, that the "Bypassed rule violations" notice is **not** a failed gate, and the direnv `GH_TOKEN` → `GITHUB_TOKEN` push bridge. |
| `437f721` (#135) | `link-skills.sh` now prunes. |
| `ca85e70` (#137) | `/process-feedback` merged into the `processing-test-feedback` skill. |

### Why `link-skills.sh` prunes (the load-bearing decision)

A stale slash command lies dormant until typed. A stale `SKILL.md` keeps matching on its
`description` and firing forever, with no upstream file left to edit. So the installer
removes what it orphans — deliberately diverging from `link-commands.sh`, which never
prunes.

Bounded by a manifest at `~/.claude/skills/.agent-workflow-skills`. **Only names recorded
there are ever removed**, so a hand-written skill is never collateral. There is a test
asserting exactly that.

Also refreshes each skill directory from scratch, so a retired `references/*.md` cannot
linger inside a surviving skill.

`tests/run-link-skills-tests.sh` is new: sandboxed `$HOME` + throwaway repo via
`--no-sync`, no network. Written test-first — 6/8 passing before the change, 8/8 after.

### Why the command was deleted, not kept as a wrapper

`commands/process-feedback.md` was a shim whose entire body was "use the
`processing-test-feedback` skill". The skill already covered resume-on-start, attachments
(incl. the pasted-image caveat), the approval gate, and dedup grounding. Only the
no-notes entry behaviour was implicit — now explicit in *When to use*.

Deleting it gains reach: a command runs only when typed; a skill also self-triggers on
its description.

## Follow-ups — not started

1. **`link-commands.sh` has no pruning.** `/process-feedback` was deleted upstream, so
   every machine that already installed it keeps a zombie command pointing at a deleted
   source. Removed by hand on this host; other machines still have it. The #135 manifest
   approach ports over directly. This is the strongest argument for doing it.

2. **#132 vs #133 are unreconciled.** #132 wired `commands/update-commands.md` to
   `config/setup/01-` and `03-claude-skills.sh`. Spec #133 **deletes** those and moves
   `bootstrap.sh` into agent-workflow. Whoever lands second must fix the other's wiring.

## Collisions observed (worth avoiding next time)

- Two sessions shared this clone. The #133 session switched the working tree to its
  branch mid-session; later this session switched it back to `main` while that branch
  held an unpushed commit. Use `.worktrees/` per `CLAUDE.md`, not a shared checkout.
- Merging #135 with `--delete-branch` while #136 was **stacked on it** caused GitHub to
  permanently close #136 — a closed PR whose base branch is gone cannot be reopened or
  retargeted. Recovered by rebasing onto `main` and opening #137. Merge stacks top-down,
  or omit `--delete-branch` until the stack drains.

## Environment

- Pushes to `freaxnx01/*` need the direnv token; the ambient credential resolves to
  `anim-bossinfo-ch` and 403s:
  `direnv exec ~/repos/github/freaxnx01 bash -c 'GITHUB_TOKEN="$GH_TOKEN" git push …'`
- `shellcheck` **is** available. No `npx`/`pre-commit`/`markdownlint` — CI's `pre-commit`
  job is the first Markdown lint gate (it passed on #135 and #137).
- No clipboard tool on this host.
- Skill tests: `tests/run-link-skills-tests.sh` from the repo root.
