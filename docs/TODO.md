# Implementation Checklist

Mirrors the implementation order in [DESIGN.md](DESIGN.md). Strict order — don't skip ahead.

## Phase 1: Foundations (Layer 0/1 testing)

- [ ] 1. Create `claude-pipeline` repo (private at first; flip public when stable)
- [ ] 2. Set up `actionlint` + `shellcheck` lint workflow
- [ ] 3. Build `scripts/post-run-report.sh` with extracted bash, env-driven
- [ ] 4. Build fixture set (~6 JSON files covering success/failure/edge cases)
- [ ] 5. Build `tests/run-script-tests.sh` that runs scripts against fixtures with mocked `gh`
- [ ] 6. Verify locally — should run in <5 seconds, exercise all branches

## Phase 2: Workflow assembly

- [ ] 7. Build `claude-implement.yml` reusable workflow with stubbed Claude step
- [ ] 8. Add `ensure-toolchain.sh` step that installs ripgrep et al. on hosted runners (idempotent, conditional, cheap)
- [ ] 9. Build `claude-implement.test.yml` for `act`-based local runs
- [ ] 10. Verify with `act` — workflow logic correct end-to-end

## Phase 3: First consumer integration

- [ ] 11. Create `claude-action-sandbox` repo (private, throwaway)
- [ ] 12. Add CLAUDE.md and the consumer stub workflow
- [ ] 13. Generate `CLAUDE_CODE_OAUTH_TOKEN` via `claude setup-token`
- [ ] 14. Add token as repo secret
- [ ] 15. Run a real `ai-implement` task on a trivial issue (e.g., "add a hello.md file")
- [ ] 16. Iterate until clean

## Phase 4: Triage + retry

- [ ] 17. Add the Haiku `classify-task.sh` step for model selection
- [ ] 18. Add `classify-failure.sh` and `retry-dispatch.sh`
- [ ] 19. Test rate-limit path with fixtures + act (real rate limits are too slow to wait for)

## Phase 5: FlowHub integration

- [ ] 20. Add consumer stub to FlowHub
- [ ] 21. Configure FlowHub-specific settings (concurrency, timeout, fork-PR protection)
- [ ] 22. Run a real task end-to-end

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
