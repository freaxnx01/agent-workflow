# Auto lane — sandbox end-to-end run for #373 (advisor session, 2026-10-04 → 06)

State of the `auto-lane-v1` milestone work and the exact next step. Written as a
`/handoff` artifact so a cold `/factory-advisor auto lane` session can resume.

## Where the milestone stands (verified live 2026-10-06)

`auto-lane-v1` (due 2026-10-11): 4 closed / 2 open.

| Issue | State | Landed by |
|---|---|---|
| #458 headless escalation fails closed | closed | PR #471 (pipeline Tasks 1–2 + local Task 3 after review: never escalate over a held lock) |
| #457 grade a run against its plan | closed | PR #473 (pipeline Tasks 1–3 + local amendment `b6b2fa4`: per-task grading, step `continue-on-error`, `Rename:`, `Files: none`) |
| #474 review job's 10-min cap cancels self-fix | closed | PR #476 (self-fix step 30 min + continue-on-error, jobs 45 min, reason in block comment) |
| #433 consumer stub permissions | closed | earlier |
| **#373 `/autopilot`** | open | only the sandbox end-to-end run remains |
| #462 consumer `actions: write` sweep | open | only the spot-check dispatch remains |

Also decided/done:

- **Lane kept** (operator, 2026-10-06). Draft PR #466 (remove autopilot) closed with
  the decision; branch `chore/remove-autopilot` kept — it preserves 47 files once
  found uncommitted on `main`.
- **Advisor carve-out** (PR #475, merged): `scripts/advisor-merge-docs.sh <pr>`
  arms `--squash --auto` for the advisor's own docs-only PRs (every path, rename
  sources included, under `docs/superpowers/`; head re-read and pinned). Every
  other PR goes to the operator as one `gh pr merge <n> --squash --auto` line.

## Sandbox setup — done

- `freaxnx01/agent-action-sandbox` PR #15 merged (`6b6d68f`): `.github/workflows/ci.yml`,
  job `ci`, on `pull_request` + push to `main`. Ran green on the PR and on `main`.
- Classic branch protection on sandbox `main` with required check `ci`
  (rulesets would NOT work — the lane reads the classic protection API only).
- Sandbox settings: allow squash merging + allow auto-merge = true.
- Candidate issue: **sandbox #16** "docs: add a CHANGELOG.md with an Unreleased
  section", label `needs-enrichment`.
- Host-local `~/.config/agent-workflow/autopilot.conf`: gate is now
  `repo=freaxnx01/agent-action-sandbox:ci.yml` (backup: `autopilot.conf.bak-2026-10-06`).
- Sandbox `agent.yml` calls `agent-implement.yml@main`, so today's fixes are under test.
- Dry run (2026-10-06 17:37 UTC): `freaxnx01/agent-action-sandbox#16 would: enrich headless, then dispatch`.

## Next step — the paid run

Blocked only on auth, being fixed by the operator:

- `GH_TOKEN` in the old session's environment was invalid (401). The PAT was
  rotated in Passbolt; a **new Claude Code session** picks up the new value.
  Check first: `gh auth status` must show no "GH_TOKEN is invalid". If it still
  does, keep using `env -u GH_TOKEN` (also for `git push` — gh is git's credential
  helper).
- The nested enrich session needs `CLAUDE_CODE_OAUTH_TOKEN`. Plan: operator puts it
  in `~/.config/agent-workflow/autopilot.env` (0600, the file the systemd unit
  already reads), created via `claude setup-token`, outside the transcript. The
  session's `ANTHROPIC_API_KEY` must be unset for the run, or the enrich bills it.

Operator starts the run (≤30 min, holds the prompt):

```bash
bash -c 'set -a; . ~/.config/agent-workflow/autopilot.env; set +a; exec env -u ANTHROPIC_API_KEY bash ~/repos/github/freaxnx01/public/agent-workflow/.worktrees/advisor/scripts/autopilot.sh --max 1'
```

Run it from a checkout at current `origin/main` (the advisor worktree: `git -C ~/repos/github/freaxnx01/public/agent-workflow/.worktrees/advisor switch --detach origin/main` after a fetch) — the primary checkout has lagged `main` before. Add `-u GH_TOKEN` to the `env` if the rotated token is still not live.

Then the advisor verifies every stage **from evidence, not labels**:

1. Headless enrich on sandbox #16: spec + plan pushed, body rewritten, `needs-enrichment` gone, or `needs-human` with a reason.
2. Dispatch: `ai-implement` + `ai-review-ai-merge` applied in one edit; driver log line `enriched`.
3. Implement run: PR opened, diff vs the plan's tasks (`gh pr diff --name-only`), bot-authored commits, run report outcome **and** the new plan-coverage grade.
4. AI review + AI merge: verdict, envelope gates, `plan-coverage == complete`, auto-merge after `ci`.
5. Record the result on #373 (stage table, as in its 2026-09-22 comment) and tick its last AC only if the chain merged.

## Parked (not in scope, write down only)

- The lane reads classic branch protection only; repos on **rulesets** are refused as unprotected. Candidate issue.
- Stale sandbox #13 / draft PR #14 from the 2026-09-22 run — operator may close.
- #462: spot-check dispatch on one swept game repo.
