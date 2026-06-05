# Contributing

Thanks for helping improve `agent-pipeline`. This repo ships reusable GitHub Actions
workflows and supporting bash scripts, so changes are small, focused, and lint-clean.

## Running the checks

Before opening a PR, run the same checks CI runs:

```bash
bash tests/run-script-tests.sh
actionlint
shellcheck -x -e SC1091 scripts/**/*.sh
```

All three must pass.

## Branches & commits

- Branch from `main` using `feature/<issue-id>-...`, `fix/<issue-id>-...`,
  `chore/<...>`, or `docs/<issue-id>-...`.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat`, `fix`, `docs`, `chore`, `ci`, `refactor`, `test`, `perf`).
- Full conventions — including the bump mapping, PR template, and house rules —
  live in [`CLAUDE.md`](CLAUDE.md). Read it before your first PR.

## Pull requests

- Keep PRs small and focused — one concern per PR.
- Lint and tests must be green before requesting review.
- Reference the issue in the PR body with `Closes #<id>` so the pipeline can
  link the PR back to its issue.
- PRs to `main` require review; do not push directly to `main`.
