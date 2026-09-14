# Cheat Sheet — Setting a repo's default model

Quick reference for changing which model `ai-implement` uses on a consumer repo
by default. For the full picture (agent opt-in, per-issue labels, security
notes) see [`CONSUMER-SETUP.md`](CONSUMER-SETUP.md#3-using-opencode-via-openrouter-optional).

## Where it lives

The default model is the `default-model` workflow input in the repo's own
`.github/workflows/agent.yml` stub — **not** a setting in `agent-workflow`
itself. Each consumer repo carries its own value.

```yaml
# .github/workflows/agent.yml
    with:
      default-model: claude-sonnet-5    # ← this line
```

A `model:*` issue label overrides this per-issue; the workflow input is only
the fallback when no label is present (`scripts/classify-task.sh`).

## Picking a model id

| Agent | `default-model` value | Example |
|---|---|---|
| `claude` (default, no `agent:` line needed) | Claude model name | `claude-sonnet-5`, `claude-opus-5`, `claude-haiku-4-5-20251001` |
| `opencode` | raw OpenRouter model id, free-form — no allowlist enforced | `z-ai/glm-5.2`, `qwen/qwen3.6-27b` |

### Cost-guarded models

`scripts/lib/blocked-models.sh` guards models whose cost and rate limit make an
*unattended* run expensive. The rule is **who chose the model**, not which model
it is:

| Route | Fable |
|---|---|
| `model:fable` label on one issue | **runs** — a per-issue decision, see [DESIGN.md](DESIGN.md#triage-step) |
| `default-model` / `escalate-model` in `agent.yml` | substituted + warned — repo-wide, no decision about this issue |
| `review-model` (drives review and the self-fix loop) | substituted + warned |
| retry of a `model:fable` run (attempt 2+) | escalates off Fable — the first attempt was chosen, the repeat is not |
| keyword heuristic | never picks it, and never did |

So a Fable id typed into `default-model` does not silently become every
dispatch's model; you get `claude-sonnet-5` and an annotation saying why. To run
Fable, label the issue.

Guarding another model means adding a glob to `BLOCKED_MODEL_PATTERNS`; every
call site picks it up.

The one route a substitution cannot reach is `review-model: ''`, which omits
`--model` entirely and inherits the `claude` CLI's own default. The input
defaults to `claude-opus-5`, so it is pinned out of the box; setting it empty is
a deliberate choice to hand model selection to the CLI.

**Before picking an OpenCode/OpenRouter model, verify it supports tool use** —
OpenCode drives edits through function/tool calls; a model that doesn't
advertise `tools` fails with *"No endpoints found that support tool use"*, and
some advertise it but emit malformed calls and silently no-op:

```bash
curl -s https://openrouter.ai/api/v1/models \
  | jq -r '.data[] | select(.id=="z-ai/glm-5.2") | .supported_parameters[]' \
  | grep -x tools && echo "tool-use OK"
```

Known-good models with measured results: see the living
[model-comparison report](model-comparison.md) and the
[per-issue label roster](CONSUMER-SETUP.md#per-issue-model-labels).

## Set it — one repo

### Option A: edit `agent.yml` directly (preserves repo-specific stub customizations)

Preferred if the repo has hand-edits beyond the base stub (e.g. `max-turns`,
`pre-preview: true`, `chain-dispatch.yml`) — regenerating via
`onboard-consumer.sh` overwrites the whole file and drops anything the script
doesn't know how to re-emit.

```bash
# 1. If switching to a non-Claude model, first ensure the agent + secret are wired:
#    agent: opencode
#    secrets:
#      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
#
# 2. Change the default-model line, then commit as usual (PR or direct-to-main
#    per the repo's own branch protection).
```

### Option B: regenerate the stub via `onboard-consumer.sh`

Only for a repo still on the plain base stub (no custom `with:` fields beyond
what the script emits) — check first with `git diff` against a known-plain repo,
or diff the file's content hash against a sibling that has no customizations.

```bash
cd agent-workflow
./scripts/onboard-consumer.sh -R freaxnx01/<repo> \
  --no-secret \
  --agent opencode --model z-ai/glm-5.2
```

`--no-secret` skips resetting `CLAUDE_CODE_OAUTH_TOKEN` (leave it if already
set). Commits directly to the repo's default branch by default — pass `--pr`
for the branch+PR flow instead.

## The `OPENROUTER_API_KEY` secret

Required once `agent: opencode` is set, regardless of which model. Declared
`required: false` at the workflow boundary, so Claude-only repos never need it.

**Org secrets don't work if the GitHub account is a personal user, not an
Organization** — `gh secret set --org` 404s with `freaxnx01` (confirmed
2026-07-29). Set it **per repo**:

```bash
echo "$OPENROUTER_KEY" | gh secret set OPENROUTER_API_KEY --repo freaxnx01/<repo>
```

Or via `onboard-consumer.sh --openrouter-cmd '<command that prints the key>'`
(never pass the key as a literal argument — it'd land in shell history/logs).

Verify: `gh secret list -R freaxnx01/<repo>` (lists names + set date only,
never the value).

## Set it across many repos (e.g. all `game-*`)

No batch/pattern mechanism exists in `agent-workflow` — no org variable, no
wildcard input. Loop over the repo list yourself:

```bash
KEY="$(passbolt get resource --id <id> --json | jq -r .password)"

for r in $(gh repo list freaxnx01 --limit 200 --json name -q '.[].name' | grep -i '^game'); do
  echo "$KEY" | gh secret set OPENROUTER_API_KEY --repo "freaxnx01/$r"
done
```

Then patch each `agent.yml` (Option A or B above). **Check for divergence
first** — hash each repo's `agent.yml` before batch-editing; don't assume they're
identical:

```bash
for r in $(gh repo list freaxnx01 --limit 200 --json name -q '.[].name' | grep -i '^game'); do
  gh api repos/freaxnx01/$r/contents/.github/workflows/agent.yml --jq '.content' \
    | base64 -d | md5sum | sed "s/-/$r/"
done
```

Repos sharing a hash can be patched with one templated `content=` blob via
`gh api -X PUT repos/<owner>/<repo>/contents/.github/workflows/agent.yml -f message=... -f content=<base64> -f sha=<current-sha>`
in a loop; outliers (different hash) need their own hand-merged version.

## Troubleshooting

- **`ProviderModelNotFoundError` / "Model not found: openrouter/…"** — almost
  always a missing `OPENROUTER_API_KEY`, not a bad model id. See
  [`CONSUMER-SETUP.md`](CONSUMER-SETUP.md#security-notes).
- **"No endpoints found that support tool use"** — the model doesn't advertise
  `tools`; pick a different one (see the `supported_parameters` check above).
- **Edits silently don't happen, no error** — model advertises `tools` but
  emits malformed tool calls (e.g. `codestral`). Swap models.

---

If you run into a gap this cheat sheet doesn't cover, fix it and add the fix
here for the next person.
