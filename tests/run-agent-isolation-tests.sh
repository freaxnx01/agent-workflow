#!/usr/bin/env bash
#
# run-agent-isolation-tests.sh — structural guard for ADR-020 (#535): in any job
# of agent-implement.yml, no step after the first agent step runs a decision
# script; every job that runs a decision script after an agent ran upstream has
# its own pipeline-ref checkout and no agent step; and no run: block
# interpolates another job's outputs.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/agent-implement.yml"
# Jobs not yet split. Task 6 removes ai_review_ai_merge, Task 7 ai_review_human_merge.
PENDING_JOBS=(ai_review_ai_merge ai_review_human_merge)

out="$(python3 - "$WF" "${PENDING_JOBS[@]}" <<'PY'
import sys, yaml
wf, pending = sys.argv[1], set(sys.argv[2:])
jobs = yaml.safe_load(open(wf))["jobs"]
AGENT = ("anthropics/claude-code-base-action", "opencode run", "review-pr.sh", "self-fix-loop.sh")
DECIDE = ("classify-failure.sh", "pipeline-pause.sh", "notify-ntfy.sh", "retry-dispatch.sh",
          "post-run-report.sh", "plan-coverage-step.sh", "check-pr-checks-runnable.sh",
          "ensure-issue-labels.sh", "check-merge-envelope.sh", "post-auto-review-block.sh",
          "check-verdict-binding.sh", "gh pr merge", "gh pr ready", "outcome=")
def text(step): return f'{step.get("uses","")}\n{step.get("run","")}'
problems = []
for name, job in jobs.items():
    steps = job.get("steps") or []
    agent_at = next((i for i, s in enumerate(steps) if any(m in text(s) for m in AGENT)), None)
    for s in steps:
        if "${{ needs." in (s.get("run") or ""):
            problems.append(f"{name}: run: interpolates needs.* in '{s.get('name')}'")
    if name in pending or agent_at is None:
        continue
    for s in steps[agent_at + 1:]:
        hit = [m for m in DECIDE if m in text(s)]
        if hit:
            problems.append(f"{name}: '{s.get('name')}' runs {hit[0]} after an agent step")
for name, job in jobs.items():
    steps = job.get("steps") or []
    if any(any(m in text(s) for m in AGENT) for s in steps):
        continue
    if any(any(m in text(s) for m in DECIDE) for s in steps):
        refs = [s for s in steps if (s.get("with") or {}).get("ref") == "${{ inputs.pipeline-ref }}"]
        if not refs:
            problems.append(f"{name}: decides but has no pipeline-ref checkout of its own")
print("\n".join(problems))
PY
)"

if [[ -z "$out" ]]; then
  printf '  ✓ no decision runs after an agent step, gates check out their own pipeline\n'
  exit 0
fi
printf '  ✗ agent isolation (ADR-020):\n%s\n' "$out" | sed 's/^/      /'
exit 1
