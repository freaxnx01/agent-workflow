# Self-hosted Azure Pipelines agent image. Build context is the repo root:
#   docker build -f docker/azp-agent/Dockerfile -t azp-agent:poc .
# Targets: `base` (shared layers), `dotnet` (base + a pinned .NET SDK, advertises
# AWF_TOOLCHAIN=dotnet) and `default` (= base, the last stage, so a build with no
# --target is the plain image). Build the variant with `--target dotnet`.
# Bump DOTNET_SDK_VERSION and DOTNET_SDK_SHA512 together.
# The agent version and its SHA-256 are pinned below: bump both together. The
# base-image digest is bumped by hand (keep the tag for readability). Register
# once with AZP_URL, AZP_TOKEN and AZP_POOL at `docker run` time (see
# docs/AZDO-PIPELINE-SETUP.md); the credential is never baked in.
FROM debian:13-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS base

ENV AZP_AGENT_VERSION=5.281.1 \
    AZP_AGENT_SHA256=c9579f76fd71a013e3b9010155454e20592d935134e4fcd04adc5283a820167e

# bash/git/jq/python3/curl run the pipeline scripts; the lib* packages are the
# .NET runtime dependencies of the agent itself; nodejs is for pipeline tasks.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq nodejs python3 python3-venv \
      libicu76 libssl3t64 libkrb5-3 zlib1g \
 && rm -rf /var/lib/apt/lists/*

# Azure CLI in its own venv (PEP 668 forbids a system-wide pip install).
RUN python3 -m venv /opt/az \
 && /opt/az/bin/pip install --no-cache-dir azure-cli==2.91.0 \
 && ln -s /opt/az/bin/az /usr/local/bin/az

RUN useradd --create-home --uid 1000 --shell /bin/bash azp \
 && mkdir -p /azp/agent /azp/work \
 && chown -R azp:azp /azp

# The installer sources scripts/lib/ relative to itself, so keep the layout.
COPY scripts/install-claude-cli.sh /opt/agent-workflow/scripts/install-claude-cli.sh
COPY scripts/lib/fetch-verified-installer.sh /opt/agent-workflow/scripts/lib/fetch-verified-installer.sh
COPY --chmod=0755 scripts/azp-agent-start.sh /usr/local/bin/azp-agent-start.sh

USER 1000
ENV PATH="/home/azp/.local/bin:${PATH}"
RUN az extension add --name azure-devops --yes \
 && bash /opt/agent-workflow/scripts/install-claude-cli.sh

WORKDIR /azp
ENTRYPOINT ["/usr/local/bin/azp-agent-start.sh"]

# .NET SDK variant. The pin comes from the official release metadata
# (https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json,
# read 2026-11-09, SDK 10.0.403 of release 10.0.14); the SHA-512 is that file's
# `hash` for dotnet-sdk-linux-x64.tar.gz and matched a fresh download.
FROM base AS dotnet
ARG DOTNET_SDK_VERSION=10.0.403
ARG DOTNET_SDK_SHA512=b7b3d8461cf98b07d2552ce9199702fa3ad010ac2671a5f8cd5136f7534e50f6855ba7bbb02b11494563f1d04156276a31cda1103b900e5eecd0d9473dc7b9c5
USER 0
# The checksum is verified, with no pipe and no `|| true`, before the tarball is
# extracted: a mismatch fails the build.
RUN curl -fsSL -o /tmp/dotnet-sdk.tar.gz "https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK_VERSION}/dotnet-sdk-${DOTNET_SDK_VERSION}-linux-x64.tar.gz" \
 && printf '%s  %s\n' "${DOTNET_SDK_SHA512}" /tmp/dotnet-sdk.tar.gz > /tmp/dotnet-sdk.sha512 \
 && sha512sum -c /tmp/dotnet-sdk.sha512 \
 && mkdir -p /usr/share/dotnet \
 && tar -xzf /tmp/dotnet-sdk.tar.gz -C /usr/share/dotnet \
 && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
 && rm -f /tmp/dotnet-sdk.tar.gz /tmp/dotnet-sdk.sha512
ENV DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    AWF_TOOLCHAIN=dotnet
USER 1000

# Last stage, so a build with no --target is the plain image.
FROM base AS default
