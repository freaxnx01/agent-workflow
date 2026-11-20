# Assign the `backlog` milestone to issues opened without one (#646)

## Problem

freaxnx01/ai-instructions#61 sets the rule that every open issue carries a
milestone, with a standing `backlog` milestone for unscheduled work. Several
paths create issues without going through `/new`, and none of them set a
milestone. Examples are the pipeline alarm issues from
`scripts/pipeline-pause.sh:203` and agent-filed follow-up batches such as
#627–#630 and #637–#639. Patching every creator is fragile. One event-driven
guard covers every creator whose event starts a workflow.

Correction to the issue text: `scripts/issue-intake.sh` does not create issues.
It labels them (`scripts/issue-intake.sh:1-10`). It is not a creation path.

## Design

Five pieces follow the shape of the issue-intake guard (#549): one script, one
reusable workflow, a Layer-2 test, a consumer stub and docs.

### 1. Shared library: `scripts/lib/backlog-milestone.sh`

The guard and the backfill both source this file, so the two can't drift.

- `BACKLOG_MILESTONE='backlog'`.
- `backlog_milestone_number <repo>`: a query.
  - Reads `repos/<repo>/milestones?state=open&per_page=100` with `--paginate`
    and slurps every page with `jq -s`. Without the slurp, jq runs once per
    page.
  - Prints the number of the milestone whose title is exactly `backlog`, or
    nothing when there is none.
  - Returns 1 when the list cannot be read.
- `assign_milestone <repo> <issue> <number>`: a command.
  - Runs `gh api -X PATCH repos/<repo>/issues/<issue> -F milestone=<number>`.
  - Sends only the milestone field, so it cannot clobber the label that
    issue-intake writes on the same `opened` event.

### 2. Guard script: `scripts/assign-backlog-milestone.sh`

The script is env-driven, as a CI script should be. Inputs are `REPO`,
`ISSUE_NUMBER` and optionally `DRY_RUN=1`. It mirrors `issue-intake.sh`.

1. Shape-check `REPO` (`owner/name`) and `ISSUE_NUMBER` (a positive integer).
   Anything else exits 2.
2. Re-read the issue as the REST object (`gh api repos/$REPO/issues/$N`). The
   event payload is not trusted, because a milestone can be set between the
   event and the run.
3. `milestone_decision` is a jq query on that object:
   - `skip issue is closed` when it is not open.
   - `skip is a pull request` when it is a pull request.
   - `skip has milestone <title>` when it already has a milestone.
   - `assign` otherwise.
4. On `assign`, look up `backlog`.
   - If it is missing, print `::warning::` and `milestone: #N skipped (no
     backlog milestone)`, then exit 0. The script never POSTs to
     `/milestones`.
   - If it is present: under `DRY_RUN=1`, print what would happen. Otherwise
     call `assign_milestone` and print `milestone: #N assigned backlog`.
5. Append `decision=assigned|skipped` and `reason=` to `$GITHUB_OUTPUT` when it
   is set.

Exit codes:

- 0: assigned, or skipped by rule. A missing `backlog` counts as a skip.
- 1: the issue or the milestone list could not be read, or the write failed.
- 2: usage error.

### 3. Backfill script: `scripts/backfill-backlog-milestone.sh`

This script is operator-invoked, so it is flag-driven:
`-R owner/repo [--apply]`. It does a dry run unless `--apply` is passed.

- Lists `repos/R/issues?state=open&milestone=none&per_page=100` with
  `--paginate`, slurps every page and drops entries that carry
  `pull_request`.
- Prints `backfill: <n> open issues without a milestone in <repo>`, then the
  issue numbers.
- Dry run: `DRY_RUN: would assign backlog (#<m>) to <n> issues — re-run with
  --apply`. It writes nothing.
- `--apply` assigns each issue and prints `backfill: assigned <k> of <n>`. It
  exits 1 if any single write failed and keeps going past a failure.
- Missing `backlog` exits 64 with an error. The script never creates the
  milestone.

The pipeline agent does **not** run this script. See *Post-merge steps*.

### 4. Workflows

- `.github/workflows/backlog-milestone.yml` is the reusable workflow.
  - Inputs: `issue-number`, `pipeline-repo`, `pipeline-ref`, `local-scripts`,
    `stub-mode`, `stub-issue-fixture`, `stub-milestones-fixture` and
    `timeout-minutes`.
  - Outputs: `decision` and `reason`.
  - Permissions: `contents: read` at the top, `issues: write` on the job only.
  - The job has a `concurrency` group keyed on repo and issue, with
    `cancel-in-progress: false`.
  - Every action is pinned by full SHA.
  - The script runs with only `REPO`, `ISSUE_NUMBER` and `GH_TOKEN` in `env:`.
  - **No user-controlled field reaches a `run:`.** No title, body or user
    login, only the number.
- `.github/workflows/backlog-milestone.test.yml` is the Layer-2 test. It
  covers three cases through `stub-mode`:
  - assigned
  - has milestone
  - no backlog
- `.github/workflows/issue-milestone.yml` is agent-workflow's own dogfood
  caller.
  - It triggers on `issues: [opened, reopened]` and calls
    `uses: ./.github/workflows/backlog-milestone.yml` with
    `local-scripts: true`, the same pattern as `agent.yml`.
  - This repo is the one that filed #627–#639, so it needs the guard itself.

### 5. Onboarding and docs

- `scripts/onboard-consumer.sh` gains `build_milestone_yml`. It writes
  `.github/workflows/issue-milestone.yml` in both the direct-to-main path and
  the PR path, the same way the intake stub is written
  (`scripts/onboard-consumer.sh:500-521`).
- `docs/CONSUMER-SETUP.md` gains §3d "Backlog milestone guard". It covers:
  - the stub
  - the rules
  - the warn-and-skip behaviour when `backlog` is missing
  - the GitHub-only gap
  - the GITHUB_TOKEN gap
- `CHANGELOG.md` gets an entry under `[Unreleased]` → `### Added`.

## Assumptions

- **A1** [confirmed] The `backlog` milestone exists. Answer: "Create in both
  now": it exists in freaxnx01/agent-workflow (#7) and freaxnx01/ai-instructions
  (#2). The workflow still warns and skips (never creates) when backlog is
  missing.
- **A2** [confirmed] The backfill and the test issue happen after merge.
  Answer: "Script + dry-run; session runs after merge": the PR ships a backfill
  script with a dry-run mode that prints the count. The implementing pipeline
  agent must NOT run the backfill or open a test issue. After merge, an
  interactive session runs the dry-run, shows the count, and does the real run
  and the test issue on the user's yes. The issue's "backfill done" and
  "verified on a test issue" criteria are therefore post-merge manual steps.
- **A3** [confirmed] Forgejo is out of scope. Answer: "GitHub-only, cite
  ADR-017": no Forgejo workflow; document the gap and cite ADR-017 (verify
  ADR-017 actually says the pipeline is GitHub-only before citing it).
  - **Verification result: ADR-017 does not say this, so it is not cited.**
    ADR-017 (`docs/DECISIONS.md:1607-1646`) is about the shape of an Azure
    DevOps work item's description and never mentions Forgejo. Its 2026-11-02
    amendment says a pipeline does run on Azure DevOps. #616 exists to remove
    the stale "GitHub-only (ADR-017)" wording.
  - The docs cite what does say it: ADR-005 (`docs/DECISIONS.md:799,826`:
    "Forgejo Actions later"), `docs/DESIGN.md:24` and `docs/FACTORY-MAP.md:128`
    ("The CI path is GitHub-only. Most Forgejo repos have no runner").
  - The decision itself, GitHub-only, is unchanged.
- **A4** [confirmed] `next` is deprecated, not kept. Coordinator correction,
  confirmed by the user: "ai-instructions#61 merged as ai-instructions PR #62
  (conventions/milestones.md): every open issue has a milestone; `backlog` is
  the default; `next` is renamed to `backlog` (agent-workflow `next` #4 is
  closed, its 35 issues already moved to `backlog` #7); `general-<month>-<year>`
  issues move to `backlog` and that milestone is closed."
  - The guard needs no special case for this. It leaves alone an issue that
    already has any milestone, and it assigns only the open `backlog`
    milestone.
  - No fixture uses `next` as a milestone title.
- **A5** [high] The guard is a separate reusable workflow with a separate
  consumer stub. Rejected: adding a second job to the issue-intake stub.
  - Intake triggers on `[opened]` only (`scripts/onboard-consumer.sh:413`).
  - Intake is fail-closed on the author (`scripts/issue-intake.sh:41-49`).
  - The milestone guard needs `reopened` and no author gate.
- **A6** [high] There is no author gate and no bot skip. Rejected: reusing
  intake's gate.
  - Intake gates on the author because `needs-enrichment` is the ticket into a
    paid lane (`scripts/issue-intake.sh:41-49`). A milestone spends nothing.
  - Agent- and bot-filed issues are exactly the target.
- **A7** [high] The guard re-reads the issue over REST and writes with a
  PATCH that carries only `milestone`. Rejected: trusting the event payload,
  and `gh issue edit --milestone`.
  - The re-read follows `scripts/issue-intake.sh:128-136`.
  - The single-field write leaves intake's label write on the same event
    alone.
- **A8** [high] Only an **open** milestone titled exactly `backlog` counts. A
  closed `backlog` is treated as missing, which gives a warning. The
  convention says `backlog` is "never closed" (milestone #7's description), so
  a closed one is an anomaly a human should see.
- **A9** [high] The backfill is flag-driven and does a dry run unless
  `--apply` is passed. It assigns parked and roadmap issues too.
  - Precedent: `scripts/migrate-consumers.sh:19-20` ("Dry-run unless
    --apply").
  - Milestone #7's description makes `backlog` the collector "for unscheduled,
    parked and roadmap issues".
- **A10** [high] The guard triggers on `opened` and `reopened` only, as the
  issue specifies. Rejected: also triggering on `demilestoned`. Until #644
  lands, `/parked repark` and `/roadmap defer` strip the milestone on purpose
  (`commands/parked.md:130-140`), and the guard would fight them.
- **A11** [med] The guard cannot see alarm issues that
  `pipeline-health.yml` raises.
  - That workflow runs `pipeline-pause.sh` with `github.token`
    (`.github/workflows/pipeline-health.yml:139,143`). The issue it creates
    (`scripts/pipeline-pause.sh:203`) starts no workflow.
  - This is documented as a gap. `pipeline-pause.sh` is not patched.
  - Alarms raised from `agent-implement.yml:1402-1408` use the App token when
    one is configured, so they do fire.
  - Rejected: a post-create milestone edit in `pipeline-pause.sh`. The issue
    itself calls per-script patching fragile, and an alarm is short-lived
    because resume closes it. The backfill picks up any alarm that is still
    open.
- **A12** [med] Existing consumers are not rolled out automatically.
  - New and re-onboarded repos get the stub from `onboard-consumer.sh`.
  - agent-workflow gets its dogfood caller in this PR.
  - ai-instructions gets its stub as a post-merge step.
  - The rest of the fleet is a follow-up.
  - Rejected: teaching `migrate-consumers.sh` to add files, because it
    rewrites pins only (`scripts/migrate-consumers.sh:3-21`).
  - Rejected: re-running `onboard-consumer.sh` on every consumer, because it
    regenerates `agent.yml` from flags
    (`scripts/onboard-consumer.sh:500-521`).
- **A13** [high] The guard script takes `DRY_RUN=1` from the environment, the
  same way `scripts/issue-intake.sh:16-17` does. The backfill takes `--apply`
  instead.

## Consequences

- An issue opened in any wired repo now costs one short Actions job, about
  10 s. It runs alongside issue-intake, and the two write different fields.
- Issues created through `github.token` never fire the guard. These include
  `pipeline-health.yml` alarms and anything else a workflow files with the
  default token. Only the backfill catches them.
- Until #644 merges:
  - `/parked repark` and `/roadmap defer` still strip milestones, and nothing
    puts `backlog` back until the next backfill.
  - `/milestone triage` still walks only the no-milestone gap. A backfill run
    before #644 would empty that gap and hide un-triaged issues inside
    `backlog`.
  - The post-merge backfill should therefore run after #644 has merged.
- The consumer stub pins `backlog-milestone.yml@v2`. It resolves only once a
  release has moved the `v2` tag past this change (ADR-013). Until then a
  consumer onboarded with the new stub gets a `startup_failure` on that one
  workflow. agent-workflow's own caller uses `./` and is unaffected.
- Every issue a repo opens before its stub is merged stays without a milestone
  until a backfill run.

## Acceptance criteria

These are for the implementing agent and must be verifiable by tests.

- [ ] `scripts/assign-backlog-milestone.sh` assigns `backlog` to an open issue
  with no milestone, through a PATCH carrying only `milestone`. A fixture
  test proves it.
- [ ] An issue that already has a milestone is left untouched: no PATCH, and
  it reports `skipped (has milestone <title>)`.
- [ ] Missing `backlog` gives a `::warning::` and exit 0, with no POST to
  `/milestones` in the mock log.
- [ ] `scripts/backfill-backlog-milestone.sh`:
  - [ ] In a dry run, it prints the count across every page with pull
    requests excluded, and writes nothing.
  - [ ] `--apply` assigns each issue.
  - [ ] Missing `backlog` exits 64.
- [ ] The workflow files exist and pass actionlint: the reusable
  `backlog-milestone.yml`, the Layer-2 `backlog-milestone.test.yml` and the
  dogfood caller `issue-milestone.yml`. In each one:
  - [ ] every action is pinned by full SHA
  - [ ] `contents: read` is set at the top and `issues: write` only on the job
  - [ ] there is a timeout and concurrency
  - [ ] no `github.event.issue.title`, `.body` or `.user` appears anywhere
- [ ] `onboard-consumer.sh` writes `.github/workflows/issue-milestone.yml` on
  both onboarding paths.
- [ ] `docs/CONSUMER-SETUP.md` §3d documents:
  - [ ] the guard
  - [ ] the warn-and-skip rule
  - [ ] the GitHub-only gap, citing ADR-005 and `FACTORY-MAP.md`, not ADR-017
  - [ ] the `github.token` gap
- [ ] A CHANGELOG entry is added under `[Unreleased]`.
- [ ] `bash tests/run-all.sh` passes, and actionlint and shellcheck are clean.

## Post-merge steps

How many issues the backfill will touch was measured during enrichment on
2026-11-19 with `--paginate | jq -s`, pull requests excluded:

- agent-workflow: **126** of 161 open issues have no milestone.
- ai-instructions: 2 of 5.

Moving `next`'s 35 issues did not shrink the agent-workflow gap below the
issue's "~66": those issues already had a milestone. The 126 are the issues
that never had one. The dry run is the authoritative count.

These are manual, for an interactive session. They are not for the pipeline.

1. After #644 has merged (see Consequences), run
   `scripts/backfill-backlog-milestone.sh -R freaxnx01/agent-workflow` and
   `-R freaxnx01/ai-instructions` as dry runs, and show the counts. Run
   `--apply` on the user's yes and report the counts.
2. Open a public test issue in agent-workflow with no milestone. Confirm it
   lands in `backlog`, then close it.
3. Once a release has moved `v2`, commit the `issue-milestone.yml` stub to
   ai-instructions.
