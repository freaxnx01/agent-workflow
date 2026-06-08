# Implementation Checklist

Mirrors the implementation order in [DESIGN.md](DESIGN.md). Strict order — don't skip ahead.

## Phase 1: Foundations (Layer 0/1 testing)

- [x] 1. Create `agent-pipeline` repo (private at first; flip public when stable)
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
