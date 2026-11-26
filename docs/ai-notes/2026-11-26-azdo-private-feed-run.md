# Azure DevOps private-feed pre-restore — Layer-3 run (2026-11-26)

The Layer-3 check for #641 and #682, as `docs/AZDO-PIPELINE-SETUP.md` §14 asks
for. Run in the personal sandbox project, on `<agent-host>`, with the image
rebuilt from `4678110` and the driver pinned to `4678110`.

**Headline:** without the Feed Reader role the run stopped before the agent
started, with the §14 message on the work item. With the role, the seed restore
succeeded and the agent built against a private and a public package in the
same run and opened a draft PR.

## Setup

- A project-scoped feed (`<probe-feed>`) holds one package, `Awf.FeedProbe`
  1.0.0. The package exists on no public source.
- The sandbox repo's `Sample.Lib` references it on `main`.
- Pipeline variables:
  - `AWF_NUGET_FEEDS` holds the feed's v3 index URL.
  - `AWF_NUGET_RESTORE` holds `samples/dotnet/Sample.sln`. The solution is not
    at the repo root, so this also covers #682.
- The work item asked for one method that calls the private package and one
  that uses the public `Humanizer.Core` 2.14.1.

## Results

- [x] **1. Without the role, the run was refused before the agent.** The project
  build service had no entry on the feed.
  - The seed restore got `NU1301` / `403 (Forbidden)` from the feed. The run
    stopped with the following message:
    `private feed restore failed (<feed URL>): check that the build service has
    the Feed Reader role on the feed`
  - The run comment read `Turns: 0`, `Cost: $0.00` and
    `next: stopping, no agent ran (see AZDO-PIPELINE-SETUP.md §14)`.
  - The `ai-implement` tag was removed.

- [x] **2. With the role, the seed restore succeeded.** The build service got
  Feed Reader on the feed, and the tag was added again. Both projects of the
  solution restored from the seed checkout in under 3 seconds each.

- [x] **3. The agent used both packages.**
  - The agent ran 29 of 120 turns, cost $0.41 and finished in 126 s.
  - It added the `Humanizer.Core` reference, routed `Greet` through
    `Awf.FeedProbe`, added tests and pushed. The draft PR was linked to the
    work item.
  - The Claude token secret survived the pipeline-variable `PUT` that set the
    two new variables, because the agent ran.

- [x] **4. The AI review ran.** It asked for changes. Both concerns are about the
  agent's tests and not about the feed:
  - a tautological `Greet` assertion;
  - no singular case for `Items`.

## Findings

- **PR validation cannot restore the private package (#699).** The PR that
  added the `Awf.FeedProbe` reference to `main` failed the required build
  validation with `NU1101`. §9 deliberately gives that pipeline no token.
  - It could only be completed with "Bypass policies when completing pull
    requests" set to Allow, plus an override in the UI.
  - Until #699 is solved, every consumer PR touching a project with a
    private reference has that problem. It blocks a production cutover.

- **Granting Feed Reader needs the UI.** The feed permissions API wants the
  build service's identity descriptor. Reading it needs the identity API, which
  a PAT with only Packaging and Work Items scopes cannot call (401). The §14.3
  UI steps are the documented path. That is fine, but a script can't do it with
  that PAT.

- **Run comment on an early refusal shows placeholders.** With no agent run,
  the comment shows `Duration: s` and `cap: attempt ? of 2`. That is cosmetic,
  and both are filled on a normal run.

- **The hook fired both times.** Twice a manual `workItemId` queue looked
  necessary, but it was not: a poller bug hid the hook's run. The manual
  duplicate was cancelled before it did anything.
