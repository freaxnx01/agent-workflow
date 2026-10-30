# Self-hosted Azure Pipelines agent image. Build context is the repo root:
#   docker build -f docker/azp-agent/Dockerfile -t azp-agent:poc .
# Run with AZP_URL, AZP_TOKEN and AZP_POOL set at `docker run` time; the
# credential is never baked in (no ENV/ARG holds it).
FROM debian:13-slim

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
 && mkdir -p /azp/agent \
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
