# agent-workflow operator console — user-level slash commands

These are **user-level** Claude Code slash commands: symlinked into
`~/.claude/commands/` by [`../setup/link-commands.sh`](../setup/link-commands.sh),
so they work from **any** repo. They are the human-facing front-end of this
pipeline — the issue→PR workflow you drive it with — and are **forge-agnostic**:
GitHub Actions today (`gh:*`), Forgejo Actions later (`fj:*`).

> **Not to be confused with** this repo's project-scoped
> [`.claude/commands/`](../.claude/commands/) (`commit`, `push`, `ui-*`), which
> are active only inside agent-workflow. `commands/` here is user-level and global;
> `.claude/commands/` is project-local. See `docs/DECISIONS.md` (ADR-005).

## Install

`config`'s one-URL bootstrap installs these automatically (it clones this repo and
calls `setup/link-commands.sh`). To install just the console directly:

```bash
curl -fsSL https://raw.githubusercontent.com/freaxnx01/agent-pipeline/main/setup/link-commands.sh | bash
```

Pass `--copy` on filesystems without symlinks; `--no-sync` to relink from the
current working tree without pulling.

## Commands

**Forge routers** (auto-detect GitHub vs Forgejo from the `origin` remote, then
delegate to the matching `gh:`/`fj:` command):
`/issues` · `/prs` · `/parked` · `/triage` · `/done` · `/new` · `/enrich` ·
`/enrich-phased` · `/route` · `/work`

**Idea capture** (forge-agnostic, local — precedes the issue funnel):
`/capture-idea <idea>` — jot an idea into the current repo's `docs/ideas.md`.

**Feedback intake** (forge-agnostic — feeds the issue funnel):
`/process-feedback <notes>` — triage a batch of tester notes into Issue /
`TODO.md` / implement-now, with dedup and a resumable worklog.

**GitHub** (`gh/`): `/gh:new` · `/gh:issues` · `/gh:parked` · `/gh:triage` ·
`/gh:enrich` · `/gh:enrich-phased` · `/gh:route` · `/gh:work` · `/gh:assign` ·
`/gh:implement` · `/gh:prs` · `/gh:review` · `/gh:done`

**Forgejo** (`fj/`): `/fj:new` · `/fj:issues` · `/fj:parked` · `/fj:triage` ·
`/fj:enrich` · `/fj:enrich-phased` · `/fj:route` · `/fj:work` · `/fj:prs` · `/fj:done`

Each `.md` file's `description:` front-matter shows in the `/` autocomplete menu.
