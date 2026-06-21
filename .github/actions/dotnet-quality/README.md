# `dotnet-quality` composite action

Runs the .NET quality gate as a single reusable step. It bundles **four
independent quality signals** plus two supply-chain/scope guards. The action is
the *mechanism*; thresholds and analyzer configuration are supplied by the
consumer repo (seeded from `ai-instructions/templates/dotnet/`).

> The companion `gate-selftest` workflow in this repo proves every one of these
> gates can actually fail — see [`../../../gate-tests/`](../../../gate-tests/).
> A gate that has never been seen to go red is indistinguishable from a no-op.

## The four signals (+ two guards)

| Signal | Tool | What it catches | Default threshold |
|---|---|---|---|
| Cyclomatic complexity | analyzer **CA1502** | over-branchy methods that are hard to test | `10` (`CodeMetricsConfig.txt`) |
| Class coupling | analyzer **CA1506** | types/methods wired to too many other types | `20` (`CodeMetricsConfig.txt`) |
| Method length | `check-method-size.py` over Code Metrics XML | sprawling methods (no analyzer rule for raw LOC) | `40` executable lines |
| Mutation score | **Stryker.NET** | tests that run code but assert nothing meaningful | `break = 60` (`stryker-config.json`) |
| Vulnerable packages | `dotnet list package --vulnerable` + `check-vulnerable.sh` | known-CVE dependencies | any vulnerable package fails |
| Diff scope | `check-diff-scope.sh` over `git diff --numstat` | oversized agent PRs | `800` added C# lines |

The first two thresholds come from the consumer's `.editorconfig` +
`CodeMetricsConfig.txt`; method length and diff scope are passed as inputs;
mutation `break` comes from the consumer's `stryker-config.json`.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `solution` | yes | — | Solution/project to restore, build (with analyzers) and scan. |
| `test-project` | yes | — | Test project/solution run with `dotnet test`. |
| `configuration` | no | `Release` | Build configuration. |
| `max-added-cs-lines` | no | `800` | Max added C# lines allowed in the PR diff. |
| `max-method-lines` | no | `40` | Max executable lines per method. |
| `base-ref` | no | `""` | Base ref for the diff-scope guard. Falls back to `origin/$GITHUB_BASE_REF` on PRs; the guard is skipped when no base is resolvable. |
| `stryker-config-dir` | no | `.` | Directory containing `stryker-config.json`. |
| `run-mutation` | no | `true` | Set `false` to skip the (slow) mutation signal. |
| `run-method-size` | no | `true` | Set `false` to skip the method-size step (its metrics generator is Windows-only and fails on Linux — see issue #91). |

## Consumer requirements

- Projects reference the **Microsoft.CodeAnalysis.Metrics** package (wired via
  `templates/dotnet/Directory.Build.props`) so the method-size metrics report
  can be generated.
- `.editorconfig` promotes **CA1502**/**CA1506** to `error` and
  `CodeMetricsConfig.txt` is registered as an `AdditionalFiles` (otherwise the
  rules are silently inactive).
- A `stryker-config.json` with a `break` threshold (unless `run-mutation: false`).

## Caller snippet

```yaml
name: quality
on:
  pull_request:
permissions:
  contents: read
jobs:
  quality:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
        with:
          fetch-depth: 0          # diff-scope guard needs history
      - uses: actions/setup-dotnet@9a946fdbd5fb07b82b2f5a4466058b876ab72bb2  # v5.3.0
        with:
          dotnet-version: 10.0.x
      - uses: freaxnx01/agent-pipeline/.github/actions/dotnet-quality@v1
        with:
          solution: MyApp.sln
          test-project: tests/MyApp.Tests/MyApp.Tests.csproj
          max-added-cs-lines: "800"
          max-method-lines: "40"
```

## Bundled scripts

All are referenced from the action via `${{ github.action_path }}`, so the
action is self-contained:

- `check-method-size.py` — parses Code Metrics XML; fails on over-limit methods
  **and** on a zero-methods report (the silent-no-op guard).
- `check-diff-scope.sh` — sums added `*.cs` lines from numstat; fails over limit.
- `check-vulnerable.sh` — greps `dotnet list package --vulnerable` output (which
  exits 0 even when vulnerabilities exist).
- `gen-metrics.sh` — generates the Code Metrics XML, failing if none is produced.
- `scope-from-git.sh` — resolves the base ref and drives the diff-scope guard.
- `run-stryker.sh` — installs and runs Stryker from the config directory.
