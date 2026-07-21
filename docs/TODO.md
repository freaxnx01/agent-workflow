# Implementation Checklist

Mirrors the implementation order in [DESIGN.md](DESIGN.md). Strict order — don't skip ahead.

## Phase 1: Foundations (Layer 0/1 testing)

- [x] 1. Create `agent-workflow` repo (private at first; flip public when stable)
- [x] 2. Set up `actionlint` + `shellcheck` lint workflow
- [x] 3. Build `scripts/post-run-report.sh` with extracted bash, env-driven
- [x] 4. Build fixture set (~6 JSON files covering success/failure/edge cases)
- [x] 5. Build `tests/run-script-tests.sh` that runs scripts against fixtures with mocked `gh`
- [x] 6. Verify locally — should run in <5 seconds, exercise all branches

## Phase 2: Workflow assembly

- [x] 7. Build `agent-implement.yml` reusable workflow with stubbed Claude step
- [x] 8. Add `ensure-toolchain.sh` step that installs ripgrep et al. on hosted runners (idempotent, conditional, cheap)
- [x] 9. Build `agent-implement.test.yml` for `act`-based local runs
- [x] 10. Verify with `act` — workflow logic correct end-to-end

## Phase 3: First consumer integration

- [x] 11. Create `claude-action-sandbox` repo (private, throwaway)
- [x] 12. Add CLAUDE.md and the consumer stub workflow
- [x] 13. Generate `CLAUDE_CODE_OAUTH_TOKEN` via `claude setup-token`
- [x] 14. Add token as repo secret
- [x] 15. Run a real `ai-implement` task on a trivial issue (e.g., "add a hello.md file")
- [x] 16. Iterate until clean

## Phase 4: Triage + retry

- [x] 17. Add the Haiku `classify-task.sh` step for model selection
- [x] 18. Add `classify-failure.sh` and `retry-dispatch.sh`
- [x] 19. Test rate-limit path with fixtures + act (real rate limits are too slow to wait for)

## Phase 5: FlowHub integration

- [x] 20. Add consumer stub to FlowHub
- [x] 21. Configure FlowHub-specific settings (concurrency, timeout, fork-PR protection)
- [x] 22. Run a real task end-to-end

## Phase 6: Self-hosted runner (later, only for private repos)

- [ ] 23. Add Ansible role for `github-actions-runner` LXC in homelab repo
- [ ] 24. Bake toolchain (ripgrep, gh, jq, fd, formatters) into the LXC image
- [ ] 25. Provision LXC, register as runner with labels `[self-hosted, homelab]`
- [ ] 26. Test with a private homelab repo (NOT FlowHub)

## Phase 7: delegate-to-gh skill (only after Phases 1–5 manually for ~2 weeks)

- [ ] 27. Build the local skill once you've written ~20 issue specs by hand
- [ ] 28. Implement skill-assisted path discovery (Grep/Glob/Read/LSP orchestration)
- [ ] 29. Skill enforces spec template
- [ ] 30. Skill supports Mode #0 ("don't delegate, do it now") as valid outcome
- [ ] 31. Skill surfaces negative findings explicitly in generated specs

## Documentation

- [ ] 32. Explain in README how the GH Action Claude step (using the GH Claude secret from Subscription) works technically
- [ ] 33. Describe all skills in README
- [ ] 34. Show/describe relations to ai-instructions and bridge repos — Mermaid diagram in README showing the workflow

## Slash commands — bootstrap UX

Exists: `/sync-ai-instructions` (agent-skills plugin — bootstraps/refreshes `CLAUDE.md` + `.ai/*` in a project from `ai-instructions`).

- [ ] 35. `/init-agent-workflow` — bootstrap slash command that wires a project into agent-workflow (consumer stub workflow, secrets checklist, `CLAUDE.md` note)
- [ ] 36. `/init-all` — combines `/sync-ai-instructions` + `/init-agent-workflow` into one bootstrap for a brand-new project
- [ ] 37. more? — survey what else a new project needs bootstrapped before these two are considered complete
- [ ] 38. Ensure the Superpowers spec/impl plan is copied into the issue body, not left as a file reference — if work spans different machines, the spec doc / impl plan file may not be committed and the referenced path is dead elsewhere
- [ ] 39. Specs & impl docs: always commit them (don't leave as local-only working files)
- [ ] 40. New skill: turn a workflow idea into a new repo/project (scaffold + bootstrap in one step)

## Skill surface — session 2026-07-21

Landed this session: `skills/` as a third artifact type alongside `commands/` and
`hooks/`, via #132 (`setup/link-skills.sh`, `processing-test-feedback`) and
freaxnx01/config#46 (`setup/03-claude-skills.sh` delegator + `bootstrap.sh` wiring).
Both merged (`ba94ff4`, `eedc366`) and verified end-to-end by deleting the installed
copy and reinstalling from `main`.

- [ ] **Verify the other machine's `processing-test-feedback`.** The `SKILL.md` now on
  `main` was committed from the WSL box; another machine may carry a newer draft that
  would be silently overwritten by the installer. Diff it against
  `skills/processing-test-feedback/SKILL.md` before running the installer there — if
  it is newer, it needs a follow-up commit, not a clobber.

- [ ] **Run `config/setup/bootstrap.sh` on that machine** so it picks up the skill.
  Until then the `processing-test-feedback` skill is missing there — the exact failure #132
  fixed here.

- [ ] **First solo `/update-commands` run still unexercised.** The copy that ran this
  session was stale and knew only step `01`, so `03-claude-skills.sh` had to be invoked
  by hand. `commands/update-commands.md` now carries both steps; the next run is the
  first to exercise the skills step unaided. Confirm it does before trusting it on a
  fresh machine.

- [ ] **Fetch gotcha is documented only in `~/.claude/CLAUDE.md`** (unversioned — that
  path is not a git repo, so it exists on the WSL box alone). A plain `git fetch`
  against a *public* repo hangs until timeout when a credential helper is inherited in
  a non-TTY subshell; `git -c credential.helper= fetch` fixes it. The user declined
  promoting this to a `config/claude/` partial (2026-07-21), so it will not reach other
  machines — revisit only if it bites somewhere else.

## Deferred — decide with the user before starting

- [ ] **`config` still does two jobs.** Its README describes "Claude Code
  configuration **plus other personal config** (oh-my-posh, Windows)". After the
  2026-07-21 consolidation it holds only CLAUDE.md partials + the bootstrap, so
  `oh-my-posh/` and `windows/` are the odd ones out. Decoupled from the command
  surface by decision §3 of
  `docs/superpowers/specs/2026-07-20-consolidate-command-surface-design.md` —
  independent cleanup, not a prerequisite for anything.

  **The user asked to be consulted on how to proceed before this is started**
  (2026-07-21). `dotfiles` is no longer a candidate destination — it was archived
  the same day. So the open question is where that content goes: a new repo, a
  subdirectory rename inside `config`, or leave it and fix the README instead.

- [ ] **`FlowHub-CAS-AISE` #186** — last `agent-pipeline` reference in any repo.
  Blocked on its own `AngleSharp 1.2.0` advisory, not on us. The user will
  handle that repo manually; no action needed here.

- [ ] **Optional hygiene** (spec-recorded, non-blocking): give `config` its own
  markdownlint + pre-commit; scope `cliff.toml` so `commands/` edits don't churn
  a consumer-facing changelog.
