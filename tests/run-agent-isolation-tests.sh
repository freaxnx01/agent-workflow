#!/usr/bin/env bash
#
# run-agent-isolation-tests.sh — structural guard for ADR-020 (#535) and the
# gate-isolation gaps closed in #592:
#   - in any job of agent-implement.yml, no step after the first agent step runs
#     a decision script; every job that runs a decision script after an agent
#     ran upstream has its own pipeline-ref checkout and no agent step; and no
#     run: block interpolates another job's outputs;
#   - the implement job refuses a shared self-hosted gate runner before the
#     agent starts (#592 F7);
#   - the shim forwards the inputs that refusal and its opt-out need.
#
# Structural assertions rot silently: a check that passes because it no longer
# looks at anything is indistinguishable from a check that passes. So every
# assertion added here is also driven against a deliberately broken copy of the
# workflow (the `mutate_*` functions), and the suite fails if the guard still
# reports that copy as clean.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/agent-implement.yml"
SHIM="$ROOT/.github/workflows/claude-implement.yml"
# Jobs not yet split. Task 6 removes ai_review_ai_merge, Task 7 ai_review_human_merge.
PENDING_JOBS=(ai_review_ai_merge ai_review_human_merge)
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAIL_NAMES=()
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1"); printf '  ✗ %s\n' "$1"; [[ $# -gt 1 ]] && printf '%s\n' "$2" | sed 's/^/      /'; return 0; }

# check_workflow <path> — every structural problem found in one agent-implement.yml.
check_workflow() {
  python3 - "$1" "${PENDING_JOBS[@]}" <<'PY'
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
# F5 (#571): the agent's job must not be able to cancel its own run.
perms = (jobs["implement"].get("permissions") or {})
if perms.get("actions"):
    problems.append("implement: holds actions: permission, the agent could cancel its own run")
# N2 (#571): the gate skips a cancelled run. With always(), a run superseded
# through the per-issue concurrency group (cancel-in-progress) would still be
# judged: empty evidence -> ai:failed stamped while the newer run is active,
# and a retryable class would dispatch a run that cancels the newer one.
gate_if = str(jobs["implement_gate"].get("if", ""))
if "!cancelled()" not in gate_if or "agent-eligible" not in gate_if or "always()" in gate_if:
    problems.append("implement_gate: if: must be !cancelled() keyed on agent-eligible, got: " + gate_if)

# F7 (#592): a self-hosted run whose gate would share the agent's machine is
# refused before the agent starts, so the check has to sit before the first
# agent step and read the three inputs the decision depends on.
impl_steps = jobs["implement"].get("steps") or []
impl_agent_at = next((i for i, s in enumerate(impl_steps)
                      if any(m in text(s) for m in AGENT)), None)
check_at = next((i for i, s in enumerate(impl_steps)
                 if "check-gate-runner-isolation.sh" in (s.get("run") or "")), None)
if check_at is None:
    problems.append("implement: no step runs check-gate-runner-isolation.sh (#592 F7)")
elif impl_agent_at is not None and check_at > impl_agent_at:
    problems.append("implement: check-gate-runner-isolation.sh runs after an agent step (#592 F7)")
else:
    want_env = {"RUNNER_LABELS": "${{ inputs.runner-labels }}",
                "GATE_RUNNER_LABELS": "${{ inputs.gate-runner-labels }}",
                "ALLOW_SHARED_GATE_RUNNER": "${{ inputs.allow-shared-gate-runner }}"}
    got_env = impl_steps[check_at].get("env") or {}
    for key, value in want_env.items():
        if str(got_env.get(key, "")).strip() != value:
            problems.append(f"implement: F7 step env {key} is {got_env.get(key)!r}, want {value!r}")

# F8 (#592): each App token carries only what its job uses. An unscoped mint
# gives the agent's job every permission the installation holds — including
# Actions, which would let it cancel its own run and skip the gate's verdict.
WANT_MINTS = {
    "implement": {
        "permission-contents": "write",
        "permission-pull-requests": "write",
        "permission-issues": "write",
        "permission-workflows": "${{ inputs.app-token-workflows-write && 'write' || '' }}",
    },
    "implement_gate": {
        "permission-contents": "read",
        "permission-issues": "write",
        "permission-pull-requests": "read",
        "permission-checks": "read",
        "permission-statuses": "read",
    },
}
for job_name, want in WANT_MINTS.items():
    steps = jobs[job_name].get("steps") or []
    mint = next((s for s in steps if "create-github-app-token" in (s.get("uses") or "")), None)
    if mint is None:
        problems.append(f"{job_name}: no create-github-app-token step (#592 F8)")
        continue
    got = {key: str(value).strip() for key, value in (mint.get("with") or {}).items()
           if key.startswith("permission-")}
    if not got:
        problems.append(f"{job_name}: mint is unscoped (#592 F8)")
    elif got != want:
        problems.append(f"{job_name}: mint scope is {got}, want {want} (#592 F8)")
print("\n".join(problems))
PY
}

# check_shim <path> — the shim declares and forwards the #592 inputs verbatim.
check_shim() {
  python3 - "$1" <<'PY'
import sys, yaml
shim = yaml.safe_load(open(sys.argv[1]))
# PyYAML reads the bare `on:` key as the boolean True.
declared = shim[True]["workflow_call"]["inputs"]
forwarded = shim["jobs"]["forward"]["with"]
problems = []
for name in ("gate-runner-labels", "allow-shared-gate-runner", "app-token-workflows-write"):
    if name not in declared:
        problems.append(f"claude-implement.yml: input '{name}' is not declared (#592)")
    if str(forwarded.get(name, "")).strip() != "${{ inputs.%s }}" % name:
        problems.append(f"claude-implement.yml: input '{name}' is not forwarded verbatim (#592)")
print("\n".join(problems))
PY
}

# ─── positive: the real workflows are clean ──────────────────────────────────
out="$(check_workflow "$WF")"
if [[ -z "$out" ]]; then
  pass "agent-implement.yml: no decision after an agent step, gates own their checkout, F7 refuses a shared gate runner"
else
  fail "agent-implement.yml is structurally sound (ADR-020, #592)" "$out"
fi
out="$(check_shim "$SHIM")"
if [[ -z "$out" ]]; then
  pass "claude-implement.yml forwards the #592 inputs"
else
  fail "claude-implement.yml forwards the #592 inputs" "$out"
fi

# ─── negative: a broken copy must not pass ───────────────────────────────────
# Each mutator edits a copy at $1 to break exactly one assertion above.
mutate_drop_runner_check() {
  sed -i '/check-gate-runner-isolation\.sh/d' "$1"
}
mutate_unscope_gate_mint() {
  sed -i '/^  implement_gate:/,/^  ai_review_ai_merge:/{/permission-/d}' "$1"
}
mutate_implement_mint_actions() {
  # The implement mint is the first in the file, so bound the substitution to it.
  sed -i '0,/^ *permission-issues: write$/s//&\n          permission-actions: write/' "$1"
}
mutate_workflows_always() {
  sed -i 's|^\( *permission-workflows:\).*|\1 write|' "$1"
}

for mutator in mutate_drop_runner_check mutate_unscope_gate_mint \
               mutate_implement_mint_actions mutate_workflows_always; do
  cp "$WF" "$T/mutated.yml"
  "$mutator" "$T/mutated.yml"
  if out="$(check_workflow "$T/mutated.yml" 2>&1)" && [[ -z "$out" ]]; then
    fail "$mutator is caught by the guard" "the mutated workflow passed the check"
  else
    pass "$mutator is caught by the guard"
  fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf '  - %s\n' "${FAIL_NAMES[@]}"; exit 1; fi
