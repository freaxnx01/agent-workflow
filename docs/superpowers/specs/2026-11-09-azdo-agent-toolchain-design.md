# Azure Pipelines agent tool-chain variant (.NET) — Design (gap item d)

**Issue:** #573 · **Date:** 2026-11-09 · **Status:** draft, written unattended under
the maintainer's go-ahead of 2026-11-06. Calls marked *(my call)* were made by the
author, not the maintainer.

## Intent

The agent image (`docker/azp-agent/Dockerfile`) carries bash, git, jq, python3,
Node, the Azure CLI and Claude Code. It does not carry a project tool chain. So
on a .NET repo the agent cannot run `dotnet build` or `dotnet test`, and it
opens a PR it never compiled. On GitHub the runner has the project's tool
chain. This item adds an **opt-in .NET variant** of the image, built the same
pinned-and-verified way, so the agent can build and test what it writes.

## Goals

1. **G1:** `docker build --target dotnet …` produces the image with a pinned
   .NET SDK.
2. **G2:** `docker build` with no target produces the **unchanged default
   image**, with the same layers and contents as today.
3. **G3:** the SDK tarball is pinned by version and **SHA-512**, verified at
   build time. A mismatch fails the build.
4. **G4:** a pipeline can require the variant through a pool **demand**, so
   .NET jobs never land on a default agent.
5. **G5:** proven live. An `ai-implement` run on a small synthetic .NET sample
   in `practice` runs `dotnet test` and the PR contains a passing test.

## Non-goals

- Other tool chains (Node versions, Java, Bruno). The stage pattern makes them
  easy later. Not now.
- Private NuGet feeds and their credentials. The real work repo needs them.
  The pilot with that repo is parked.
- Caching NuGet packages across jobs. Fresh container per job is a hardening
  goal (#577 G1), and a cache volume would undo it.

## Anti-goals

- Installing the SDK at job time (`UseDotNet@2`, `dotnet-install.sh` per run).
  That is an unpinned download inside a job that holds secrets.
- Making the default image bigger for everyone.

## Decisions

### D1 — Multi-stage Dockerfile, default stage last *(my call)*

Split the current Dockerfile into stages:

- `base`: everything that exists today.
- `dotnet`: `FROM base`, with the SDK added.
- `default`: `FROM base`, the **last** stage, so a bare `docker build` keeps
  producing today's image.

This is one file instead of a second Dockerfile that would drift.

### D2 — SDK pinning

- `ARG DOTNET_SDK_VERSION` and `ARG DOTNET_SDK_SHA512` live in the `dotnet`
  stage.
- The tarball comes from the official Microsoft download URL for that version.
  The SHA-512 comes from the release metadata (`releases.json` for the
  channel).
- The build verifies with `sha512sum -c`, then extracts to `/usr/share/dotnet`,
  symlinks `dotnet`, and sets these environment variables:
  - `DOTNET_ROOT`
  - `DOTNET_CLI_TELEMETRY_OPTOUT=1`
  - `DOTNET_NOLOGO=1`
- Version: the current .NET **LTS** SDK patch at build time *(my call)*. Bump
  the version and the SHA together, as with the agent tarball.
- Run the install as root, then switch back to `USER 1000`.
- Add the SDK's native dependencies only if `dotnet --info` fails without
  them. `libicu76`, `libssl3t64` and `zlib1g` are already in `base`.

### D3 — Routing by capability, not by pool *(my call)*

An agent advertises its environment variables as capabilities. The `dotnet`
stage sets `AWF_TOOLCHAIN=dotnet`, and a .NET pipeline adds:

```yaml
pool:
  name: <pool>
  demands:
    - AWF_TOOLCHAIN -equals dotnet
```

One pool, mixed agents. The guide documents both ways to run it: a second
agent registration (its own volume and unit), or switching the existing agent
to the variant (a superset of the default).

### D4 — Sandbox setup

In the sandbox the existing single agent is **switched to the `dotnet` image**,
which is a superset of the default. This avoids a second registration, which
would need a new pool-management PAT. The default image is still built and
smoke-tested (`docker run --rm --entrypoint bash <img> -c 'az version && claude --version'`).

### D5 — Synthetic sample

A PR in `practice` adds `samples/dotnet/`:

- a class library with one method;
- an xUnit test project;
- a `.sln`;
- a `CLAUDE.md` saying "run `dotnet test samples/dotnet` before committing".
  The implement prompt already tells the agent to read `CLAUDE.md`, so
  `build-agent-prompt.sh` does not change *(my call)*.

This is not work code; the pilot with the real repo is parked. Merge it
(sandbox merges approved).

**G4 in the sandbox** is shown by documentation plus a Layer-1 check that the
`dotnet` stage sets `AWF_TOOLCHAIN=dotnet`. With a single agent there is no
default agent for a job to land on by mistake. A live mixed-pool test needs a
second registration and is out of scope.

## Tests

- **Layer 1:** a test script asserts on the Dockerfile:
  - the `dotnet` stage exists;
  - the last stage is `default` and is `FROM base`;
  - the SHA-512 ARG is 128 hex characters;
  - a `sha512sum -c` call is present.

  This is a cheap guard against reordering. It is not a substitute for the
  build.
- **Build:** both targets build on the agent host. In the dotnet image,
  `dotnet --info` and `dotnet test samples/dotnet` pass.
- **Live:** a work item on `practice` asks for a small change with a test. The
  run log shows `dotnet test`, and item c's validation is green on the PR.

## Left to the builder

- The exact SDK patch version and its SHA-512, read from the official release
  metadata on the day.
- Whether `hadolint` flags anything new, and fixing it.
- The guide section: §1 (build) gets the `--target dotnet` variant, and the
  demand snippet goes in the pipeline section.
