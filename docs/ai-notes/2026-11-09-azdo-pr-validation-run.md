# Azure DevOps PR validation — live proof (2026-11-09)

Gap item c of #573. Spec: `docs/superpowers/specs/2026-11-09-azdo-pr-validation-design.md`.
Run in the personal sandbox project against agent-workflow `3f7ce54`.

**Headline:** a required build-validation policy gates PRs, the validation
pipeline carries no secret, and the pipeline-file guard stops the driver before
the PR. Drafts are not validated until a human publishes them, which matches
the maintainer's accepted fallback.

## Results

- [x] **1. Install.** The template was copied as `azure-pipelines-pr.yml`, with
  `bash ci/check.sh` as the build step (item d's .NET sample has not landed
  yet). The pipeline was created with **0 variables**, and the policy is
  Required, automatic, `validDuration 0` (expires when `main` updates).
  - **Finding:** a new pipeline has to be **authorized on the agent pool**
    before its first run. Until then the build sits at *notStarted*. Added to
    §9.2 of the setup guide.
- [x] **2. Red blocks completion.** The PR broke the check, and the build
  failed in the *Build and test* step (`Bash exited with code '1'`). Completing
  the PR after an approve vote was refused with `PR validation must succeed to
  update main.`
- [x] **3. Green passes.** The fix was pushed and the build succeeded. The
  policy shows *approved*, and only the reviewer vote remained.
- [x] **4. Draft PR.** The agent's draft PR showed the build policy as *queued*
  with **no build**, still after more than 3 minutes. Publishing the PR by hand
  queued the build at once, and it went green. → §9.5 records this. It is
  accepted: validation runs once a human publishes.
- [x] **5. Pipeline-file guard.** A work item asked the agent to edit
  `azure-pipelines-pr.yml`.
  - The agent succeeded (`outcome: success`).
  - The driver logged `the agent changed pipeline files; refusing to push or
    open a PR:` and named the file. The run failed.
  - No PR was opened.
  - **The branch did reach the server.** The agent pushed it itself, which is
    the limitation documented in §9.4. Without a PR, no validation run ever
    executed that YAML.
  - The failure comment was posted on the work item.
- [x] **6. Secret check.** A names-only probe in the validation step found no
  `SYSTEM_ACCESSTOKEN` and no Claude variable in the step environment. The
  only matches were agent feature flags such as `SYSTEM_ENABLEACCESSTOKEN`.
  `.git/config` had **0** `extraheader` entries, and the checkout passed the
  token only through `git --config-env`.
- [x] **7. YAML CI-trigger bypass (found in final review).** Both pipelines in
  the personal sandbox project had their CI trigger set to "from YAML". A probe
  branch whose `azure-pipelines-pr.yml` declared a `trigger` for that branch
  queued the validation pipeline from the push alone, with no PR.
  - After overriding the YAML CI trigger with CI disabled (the
    `continuousIntegration` entry removed from the definition's `triggers`), a
    push to the probe branch queued no run.
  - PR validation still ran normally through the build-validation policy.
  - The override was applied to both sandbox pipelines.

- [x] **8. Build service cannot queue pipelines.** A probe step ran as the
  build service and POSTed a run of the validation pipeline with the job token.
  It was refused: `TF215106: Access denied … needs Queue builds permissions`.
  The CI-trigger override therefore cannot be bypassed by queueing from a
  pushed branch, as long as that permission stays ungranted (setup guide §5).

## Discoveries (not acted on)

- **The service hook fired for most tag changes but missed one.** It
  delivered events for the tag on item 13 (run 29) and for the guard's tag
  removals (runs 26 and 30). It produced **no event** for item 12's first tag,
  which was added one revision after the item was moved into the hook's area
  path. The cause is unknown. Steps 4 and 5 used manual runs with
  `workItemId`, which go through the same guard.
  - A hook run and a manual run on the same tag raced (runs 28 and 29). The
    guard let only one through: the second found the tag already consumed
    (exit 64). One tag gave exactly one agent run.
  - After the CI-trigger override, a direct POST to the Incoming WebHook still
    queued the `ai-implement` pipeline (run 33, guard exit 64 on an untagged
    item). The override does not affect the webhook trigger.
- **Work-item comments posted with `--discussion` read back as plain text,**
  not HTML. Item a's spec (A4a) assumed HTML from a fixture, so verify this
  before stripping.

## Cleanup

- The probe PRs were abandoned and their branches deleted.
- The `ai-implement` pipeline is pinned back to `d563723`.
- The validation pipeline and its policy stay in place for items d, a and b.
