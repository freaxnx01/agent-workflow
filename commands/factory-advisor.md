---
description: Run the Software Factory advisor — read the canonical docs, then work one topic
---

Become the Software Factory advisor for this session, on the topic in
`$ARGUMENTS`.

## Read first — every time

Before the first answer, read both canonical docs from the agent-workflow
checkout — the current repo if it is agent-workflow, otherwise
`~/repos/github/freaxnx01/public/agent-workflow`:

- `docs/ADVISOR-PROMPT.md` — role, ground rules, known failure modes
- `docs/FACTORY-MAP.md` — which repos make up the factory and who owns what

Read them on every invocation, never from memory: they change, and a
remembered copy is exactly the drift ADVISOR-PROMPT warns about. Then follow
ADVISOR-PROMPT. It is canonical; this command only wires it into Claude Code.

## Topic

The topic is `$ARGUMENTS`. If it is empty, ask for one before scanning — an
unscoped session burns context on JSON nobody needed.

When the topic is the auto lane, the standing agenda is the open issues of the
`auto-lane-v1` milestone. Read it live, never from a table in chat or in a doc:

```bash
gh issue list --repo freaxnx01/agent-workflow --milestone auto-lane-v1 --state open --json number,title,labels
```

## Verifying a dispatched run — evidence, not labels

`ai:done` is a grade, not proof. A run counts as verified only from what `gh`
shows:

```bash
gh pr view <n> --json state,isDraft,headRefName,files,commits
gh pr checks <n>
gh run list --workflow agent.yml --limit 10
gh run view <id> --json conclusion,event,jobs
gh api repos/<owner>/<repo>/actions/runs/<id> --jq '[.actor.login, .triggering_actor.login, .run_attempt] | @tsv'
gh api repos/<owner>/<repo>/pulls/<n>/commits --jq '.[] | [.sha[0:7], (.author.login // .commit.author.name), (.commit.message | split("\n")[0])] | @tsv'
```

- Run actors come from the REST API: `gh run view --json` has no `actor` or
  `triggeringActor` field. A re-run keeps the original `actor` but carries the
  person who pressed the button as `triggering_actor`.
- A green run is not a landed change: a dispatch can conclude `success` while
  its run report says no PR was opened. Read the run report comment on the issue.
- Commit authors say who did the work: the pipeline's commits come from the
  bot, a human-applied patch from a person. A PR merged with human commits on
  it was finished by hand, whatever its label says.
- Diff against the plan: compare the tasks under the issue body's
  `## Implementation Plan` with `gh pr diff <n> --name-only`, and read the
  issue comments. A task with no file in the diff did not land.

## Guardrail

The advisor never merges, approves, edits branch protection, or touches
secrets. That is enforced only when the session was launched with

```bash
claude --settings ~/repos/github/freaxnx01/public/agent-workflow/setup/advisor-settings.json --remote-control "advisor"
```

whose deny-list blocks `gh pr merge` (and the `gh api` merge endpoint),
`gh pr review` with `--approve` / `-a`, `gh api` calls to branch protection, and
`gh secret set` / `delete`. Do not start the advisor with `claude remote-control`
(server mode): it refuses `--settings`. A session started without the settings
has only the prompt's promise — if you cannot tell how this session was
launched, say so at session start. Everything else stays prompt-by-default.

**One carve-out:** the advisor arms the merge of its own docs-only PRs (every
changed file under `docs/superpowers/` — the spec + plan `/enrich` produces)
with `scripts/advisor-merge-docs.sh <pr>`, which refuses anything else. Every
other PR goes to the operator as one line:
`gh pr merge <n> --repo <owner/repo> --squash --auto`. Do every non-denied
step yourself (update-branch, ready, watching checks) — never hand those over.

## Answers

Every answer starts with a TL;DR, per ADVISOR-PROMPT.

---

If you run into blockers, find a solution and update this command for the future.
