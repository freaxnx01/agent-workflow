# Azure Pipelines agent .NET variant — live proof (2026-11-09)

Gap item d of #573. Spec: `docs/superpowers/specs/2026-11-09-azdo-agent-toolchain-design.md`.
Run in the personal sandbox project, on `<agent-host>`, from branch commit `21d287f`.

**Headline:** the `dotnet` image builds from a pinned, hash-checked SDK and
advertises `AWF_TOOLCHAIN=dotnet` as an agent capability. A .NET work item went
end to end: the agent added the code and a test, and the PR's validation build
ran `dotnet test` green on the variant.

## Results

- [x] **1. Build both targets.**
  - Default image `awf-azp-agent:21d287f`: image id `9f4f120ead99`, 9 layers,
    the same layer count as the previous image. The same-inputs layer and
    config comparison was done in Task 1 (identical image id before and after
    the split). The id here differs from the old `d4812c2` image only because
    the build inputs differ: a newer commit, and Claude Code installed at build
    time.
  - Variant image `awf-azp-agent:21d287f-dotnet`.
- [x] **2. Negative pin.** A `--target dotnet` build with an all-zero
  `DOTNET_SDK_SHA512` **failed** at `sha512sum -c` (G3).
- [x] **3. Variant smoke test.** `id -u` → `1000`. `dotnet --version` →
  `10.0.403`. `AWF_TOOLCHAIN` → `dotnet`. The Azure CLI and Claude Code are
  present. The pin was checked against the channel's `releases.json`: 10.0.403
  is `latest-sdk`, support phase `active`, and the hash matches.
- [x] **4. Sample.** The sample `samples/dotnet` (class library and xUnit
  test, `net10.0`) was scaffolded and tested inside the variant (1 passed), then
  merged through a sandbox PR. A root `CLAUDE.md` tells the agent to run
  `dotnet test samples/dotnet/Sample.sln` before committing. Both sandbox
  pipelines got the demand `AWF_TOOLCHAIN -equals dotnet`. The PR's own
  validation build ran `dotnet test` on the variant (1 passed).
- [x] **5. Switch the sandbox agent (D4).**
  - The unit now runs `awf-azp-agent:21d287f-dotnet`. A backup of the unit
    file and the previous image `d4812c2` stay on the host, so rolling back is
    a one-line change.
  - After the restart the agent reconnected once the stale session expired
    (about 2 min).
  - The pool shows the agent online with capabilities `AWF_TOOLCHAIN=dotnet`
    and `DOTNET_ROOT=/usr/share/dotnet`. This confirms that environment
    variables are advertised as capabilities (D3), and the demand matched it.
- [x] **6. Live `ai-implement` (G5).** A work item asked for
  `Greeter.Farewell(name)` with a test.
  - The run succeeded and opened a draft PR that adds the method and an xUnit
    test.
  - Publishing the PR queued validation, which ran `dotnet test` on the
    variant: **2 passed**.
  - **Deviation:** that the agent itself ran `dotnet test` before committing
    is **not observable**. The driver does not log the agent's tool calls, and
    its result file is deleted with the job. The evidence that the code builds
    and passes is the PR's validation build.

## Discoveries (not acted on)

- The service hook again produced **no event** for a freshly created work item
  tagged in its second revision, this time created directly in the hook's area
  path. This adds to the TODO from the item-c run. The run used a manual
  `workItemId` run, which goes through the same guard.
- G4 with a mixed pool (one default and one dotnet agent) is not shown live,
  because the sandbox has a single agent. It is covered by documentation and
  the Layer-1 check that only the `dotnet` stage sets `AWF_TOOLCHAIN`.

## Cleanup

- The probe PR was abandoned and its branch deleted.
- The local scaffold image was removed.
- The sandbox agent **stays on the dotnet image**, as D4 expects.
