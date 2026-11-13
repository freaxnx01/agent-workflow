# Retry apt and report pre-agent failures on the issue — design (#597)

## Why

On 2026-11-11 two dispatches (bridge#366, bridge#253) died in
`ensure-toolchain.sh` before the agent started: apt could not resolve
`azure.archive.ubuntu.com` while installing ripgrep (exit 100). The job went red
in about 5 minutes, and the issue kept `ai-implement` with no label change, no
comment and no run marker. A consumer reading the issue (bridge's inbox #368,
the planned digest #381) sees "still running". Only the Actions list tells the
truth.

Two separate gaps:

1. **No retry around apt.** `scripts/ensure-toolchain.sh:96` runs
   `apt-get update && apt-get install` once. #598 (merged) already added a
   checksum-pinned release-binary fallback for `rg` (`:53-77`, `:97-101`), but
   `jq` and `gh` have none, and the fallback pays a second network round trip for
   what is usually a blip.
2. **Nothing reports a failure before the agent.** Every reporting path lives in
   `implement_gate`, whose `if:` is
   `!cancelled() && needs.implement.outputs.agent-eligible == 'true'`
   (`.github/workflows/agent-implement.yml:1033`). `agent-eligible` needs
   `steps.agent_reached.outputs.reached == 'true'` (`:438`), and that step is the
   last one before the agent (`:724-728`). A failure at any earlier step of the
   `implement` job (`:448-723`: token mint, checkouts, `Ensure toolchain` at
   `:560`, the classifiers, triage) leaves the gate skipped by design.

## Goal

- A transient apt failure is retried with bounded backoff and does not fail the
  run on its own.
- Any `implement` job failure **before the agent** posts one run report with a
  v1 `ai-run` marker on the issue, names the failed step, stamps `ai:failed`, and
  does not count as an attempt.

## Non-goals

- Auto-redispatching a pre-agent failure (`retry-dispatch.sh`). The retry here is
  inside the step; a persistent failure waits for a human.
- Azure DevOps. Its pipeline has its own report path (ADR-021 item 9); the step
  lookup below is a GitHub Actions API call.
- Skipping `rg` when it cannot be installed (operator decision 2).
- A new label. `ai:failed` already means "the run failed" and is what
  `post-run-report.sh` stamps for every failed run.

## Design

### 1. Apt retry (`scripts/ensure-toolchain.sh`)

Replace the one-shot at `:96` with `apt_install_with_retry`:

- `-o Acquire::Retries=3` on both `apt-get` calls. apt retries each failed fetch
  itself, which covers a flapping mirror inside one invocation.
- An outer loop around the pair `apt-get update` + `apt-get install`, because a
  failed `update` (the 2026-11-11 case) aborts before apt's own retry matters.
  `APT_ATTEMPTS` (default `3`) tries, sleeping `APT_RETRY_DELAY * attempt`
  seconds between them (default delay `5`, so 5 s then 10 s; worst case about
  15 s of sleep). Tests set `APT_RETRY_DELAY=0`.
- Each failed attempt prints one line to stderr
  (`warning: apt attempt 1/3 failed, retrying in 5s`) so the job log shows the
  retry happened.
- Unchanged: the "already present" skip (`:81-85`: nothing is installed unless
  `command -v` fails), the release-binary fallback after the loop is exhausted,
  and exit 1 when a tool is still missing (`:103-108`). Retry comes first,
  fallback second, failure last.

### 2. Pre-agent failure report

A new job `implement_prefail` in `agent-implement.yml`, next to `implement_gate`:

```yaml
implement_prefail:
  needs: implement
  if: ${{ !cancelled() && !inputs.stub-claude
          && needs.implement.result == 'failure'
          && needs.implement.outputs.agent-eligible != 'true' }}
  permissions: { contents: read, issues: write, actions: read }
```

- **A separate job, not an `if: failure()` step in `implement`.** The failure is
  often the runner itself (no `gh`, no network, a bad checkout): a step in the
  same job shares that runner and can fail the same way. It also keeps the agent
  job's token and workspace out of the reporting path (#535, ADR-020: the gate
  already runs "own runner, own fresh checkouts, never an agent").
- **The condition is the exact complement of `implement_gate`'s.** The gate
  reports when `agent-eligible == 'true'`; this job reports when the job failed
  and it is not. So a failure is reported by exactly one of them, never both,
  and an agent-phase failure keeps its existing report. `needs.implement.result
  == 'failure'` (not `!= 'success'`) keeps a parked issue (attempt cap, pause
  gate) silent: those jobs finish green.
- **Steps:** mint the App token the way the gate does (`:1055-1064`), checkout
  and `.claude-pipeline` mirror (`:1065-1100`, copy as-is), then:
  1. *Find the failed step.* `gh api repos/$REPO/actions/runs/$RUN_ID/attempts/$RUN_ATTEMPT/jobs`,
     keep jobs whose `conclusion == "failure"` and whose `name` ends with the
     implement job's name, take the first step with `conclusion == "failure"`.
     On any API error or no match, the step name falls back to `unknown`; the
     report is still posted. Needs `actions: read` (the caller already grants
     `actions: write`, `tests/run-caller-permissions-tests.sh:10`, so no new
     consumer permission).
  2. *Post the report.* Run `scripts/post-run-report.sh` with a synthetic result
     file `{"is_error":true,"subtype":"pre_agent_failure","num_turns":0,
     "total_cost_usd":0,"duration_ms":0}` and the new `PRE_AGENT_STEP` env set to
     the step name. `post-run-report.sh` already posts through the forge adapter,
     stamps the status label, removes `ai:running`, and renders the marker, so
     nothing is duplicated.

### 3. `post-run-report.sh` changes

- New optional env `PRE_AGENT_STEP`. When set, `render_comment` gets
  `**Outcome:** :x: failed: before the agent started (step: <name>)`, the status
  label is `ai:failed`, and the marker carries `subtype: "pre_agent_failure"`,
  `class: "pre_agent"` (operator decision 1), `status: "ai:failed"`.
- `counts` is `false` with no change to `run_counts` (`:477-489`): turns and cost
  are 0, which is the cap's own non-start rule. `attempt` is therefore omitted.
- **Step name is free text.** It is workflow-authored, not agent-authored, but
  the same escaping rule applies: it appears only in the visible comment, never
  in the marker (ADR-021 item 4), and is cut to `[A-Za-z0-9 ._:()#/-]`, 80 chars,
  before rendering.
- With `PRE_AGENT_STEP` unset the output is byte-identical; the golden tests in
  `tests/run-run-report-golden-tests.sh` stay unmodified.

## Interaction with the attempt cap

`check-attempt-cap.sh` treats a report with 0 turns and $0.00 as a non-start,
ceiling `MAX_NON_STARTS` (default 5, `:23-27`). The pre-agent report is exactly
that, so it never consumes one of the `MAX_ATTEMPTS`, and a persistent outage
cannot loop forever: after 5 reports the issue is parked. That is the AC's "does
not consume an attempt" with no cap change.

## Assumptions

- **A1** [high] The report goes through `post-run-report.sh`, not a new script.
  Rejected: a bespoke `comment + label` script, which would re-implement the
  forge adapter calls, the marker builder and the stale-label cleanup.
- **A2** [high] New job rather than a step. Reason above; cost is one more runner
  start (about 30 s) on a failure, which is rare.
- **A3** [med] `needs.implement.result == 'failure'` also fires when the agent
  step itself crashed the runner after `agent_reached` was published. Then
  `agent-eligible` is `true` and the gate reports; this job stays silent. Correct
  by construction of the complement.
- **A4** [med] Retry parameters: 3 attempts, 5 s / 10 s backoff. Enough for a
  DNS blip, small enough not to hide an outage for minutes. Env-overridable.
- **A5** [med] Job lookup by name suffix is brittle if a consumer renames the
  caller job. The fallback `unknown` keeps the report; the failed-step name is a
  convenience, the report and run URL are the substance.

## Consequences

- A cancelled run is still silent (`!cancelled()`, #571), as for the gate.
- If the issue token or API is itself what failed, the report job fails too and
  nothing is posted. It is a best-effort net, not a guarantee; the job goes red.
- A run killed by `timeout-minutes` before `agent_reached` now gets a report; one
  killed during the agent still posts none (#567, unchanged).
- Visible text on every existing report is unchanged.

## Review Focus

1. A failure at `Ensure toolchain` yields exactly one report; an agent-phase
   failure yields exactly one report (gate), never two.
2. A parked or paused run (job green) posts nothing.
3. The report is a non-start: `counts:false`, no `attempt`, cap unchanged.
4. Hostile step names (`-->`, backticks, newlines) stay out of the marker and are
   sanitized in the visible line.
5. `apt-get` failing twice then succeeding leaves exit 0; failing three times
   still reaches the release-binary fallback.

## Decisions (operator, 2026-11-12)

1. **Marker `class` is a new value, `pre_agent`**, not `transient`. A pre-agent
   failure is not always transient, and bridge's retry model (#367) reads
   `transient` as "safe to retry". The new ADR states the additive enum value;
   ADR-021's list is not edited.
2. **No skipping `rg`.** If apt and the release-binary fallback both fail, the
   step fails as today. The report now makes that failure visible, and a silently
   missing `rg` degrades the agent in ways that are harder to see.
3. **A run killed by the implement timeout before the agent** is reported too
   (result `failure`); no exclusion.

## Discovered, not acted on

- `scripts/ensure-toolchain.sh:79-80` declares `MISSING=()` twice (harmless).
