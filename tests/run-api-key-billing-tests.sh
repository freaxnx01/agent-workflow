#!/usr/bin/env bash
#
# run-api-key-billing-tests.sh — structural guard for #540: the optional
# ANTHROPIC_API_KEY bills only the Claude implement step to the API credit.
#
#   1. agent-implement.yml declares the secret, required: false;
#   2. the claude-implement.yml shim declares it, required: false;
#   3. "Run Claude Code" passes anthropic_api_key from it and passes the OAuth
#      token only when the key is empty — exactly one credential reaches the CLI;
#   4. nothing else (no review, no self-fix, no job-level env) references it —
#      the CLI prefers ANTHROPIC_API_KEY whenever it is in its environment, so a
#      leak would silently move the review onto the API credit.
#
# Every assertion is also driven against a deliberately broken copy (the
# mutations below): a guard that no longer looks at anything must fail here,
# not pass silently.
#
# Usage: tests/run-api-key-billing-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/agent-implement.yml"
SHIM="$ROOT/.github/workflows/claude-implement.yml"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAIL_NAMES=()
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1"); printf '  ✗ %s\n' "$1"; [[ $# -gt 1 ]] && printf '%s\n' "$2" | sed 's/^/      /'; return 0; }

# check_workflows <agent-implement.yml> <claude-implement.yml> — one problem per line.
check_workflows() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
wf_path, shim_path = sys.argv[1], sys.argv[2]
KEY_REF = "secrets.ANTHROPIC_API_KEY"
WANT_KEY = "${{ secrets.ANTHROPIC_API_KEY }}"
WANT_OAUTH = "${{ secrets.ANTHROPIC_API_KEY == '' && secrets.CLAUDE_CODE_OAUTH_TOKEN || '' }}"
problems = []

def load(path):
    return yaml.safe_load(open(path))

def call_secrets(doc):
    on = doc.get("on", doc.get(True)) or {}   # PyYAML reads the key `on` as True
    return (on.get("workflow_call") or {}).get("secrets") or {}

wf, shim = load(wf_path), load(shim_path)
for label, doc in (("agent-implement.yml", wf), ("claude-implement.yml", shim)):
    decl = call_secrets(doc).get("ANTHROPIC_API_KEY")
    if decl is None:
        problems.append(f"{label}: does not declare secret ANTHROPIC_API_KEY")
    elif decl.get("required") is not False:
        problems.append(f"{label}: ANTHROPIC_API_KEY must be required: false, got {decl.get('required')!r}")

run_step = None
for job_name, job in (wf.get("jobs") or {}).items():
    job_rest = {k: v for k, v in job.items() if k != "steps"}
    if KEY_REF in str(job_rest):
        problems.append(f"{job_name}: job-level keys reference {KEY_REF}")
    for step in job.get("steps") or []:
        if job_name == "implement" and step.get("name") == "Run Claude Code":
            run_step = step
            continue
        if KEY_REF in str(step):
            problems.append(f"{job_name}: step '{step.get('name')}' references {KEY_REF}")

if run_step is None:
    problems.append("implement: no step named 'Run Claude Code'")
else:
    with_ = run_step.get("with") or {}
    if str(with_.get("anthropic_api_key", "")).strip() != WANT_KEY:
        problems.append(f"Run Claude Code: anthropic_api_key is {with_.get('anthropic_api_key')!r}, want {WANT_KEY!r}")
    if str(with_.get("claude_code_oauth_token", "")).strip() != WANT_OAUTH:
        problems.append(f"Run Claude Code: claude_code_oauth_token is {with_.get('claude_code_oauth_token')!r}, want {WANT_OAUTH!r}")
    if KEY_REF in str(run_step.get("env") or {}):
        problems.append("Run Claude Code: the key must go through with:, not env:")

print("\n".join(problems))
PY
}

# mutate <kind> — writes broken copies to $T/wf.yml and $T/shim.yml.
mutate() {
  python3 - "$1" "$WF" "$SHIM" "$T/wf.yml" "$T/shim.yml" <<'PY'
import sys, yaml
kind, wf_in, shim_in, wf_out, shim_out = sys.argv[1:6]
wf, shim = yaml.safe_load(open(wf_in)), yaml.safe_load(open(shim_in))
def secrets(doc):
    return doc.get("on", doc.get(True))["workflow_call"]["secrets"]
def step(doc, job, pred):
    return next(s for s in doc["jobs"][job]["steps"] if pred(s))
run = lambda: step(wf, "implement", lambda s: s.get("name") == "Run Claude Code")
if kind == "drop-wf-secret":
    secrets(wf).pop("ANTHROPIC_API_KEY", None)
elif kind == "shim-required-true":
    secrets(shim)["ANTHROPIC_API_KEY"] = {"required": True}
elif kind == "drop-api-key-input":
    run()["with"].pop("anthropic_api_key", None)
elif kind == "unconditional-oauth":
    run()["with"]["claude_code_oauth_token"] = "${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}"
elif kind == "leak-review":
    s = step(wf, "ai_review_ai_merge", lambda s: s.get("name") == "Run agent review")
    s.setdefault("env", {})["ANTHROPIC_API_KEY"] = "${{ secrets.ANTHROPIC_API_KEY }}"
elif kind == "leak-selffix":
    s = step(wf, "ai_review_human_merge", lambda s: "self-fix-loop.sh" in str(s.get("run", "")))
    s.setdefault("env", {})["ANTHROPIC_API_KEY"] = "${{ secrets.ANTHROPIC_API_KEY }}"
elif kind == "leak-job-env":
    wf["jobs"]["implement"].setdefault("env", {})["ANTHROPIC_API_KEY"] = "${{ secrets.ANTHROPIC_API_KEY }}"
else:
    sys.exit(f"unknown mutation {kind}")
yaml.safe_dump(wf, open(wf_out, "w"), sort_keys=False)
yaml.safe_dump(shim, open(shim_out, "w"), sort_keys=False)
PY
}

printf '\n── #540 ANTHROPIC_API_KEY: shipped workflows are clean ──\n'
out="$(check_workflows "$WF" "$SHIM")"
if [[ -z "$out" ]]; then pass "agent-implement.yml + shim satisfy #540"; else fail "agent-implement.yml + shim satisfy #540" "$out"; fi

printf '\n── #540 guard catches each broken copy ──\n'
# kind:expected-substring-in-the-problem-report
for spec in \
  "drop-wf-secret:agent-implement.yml: does not declare" \
  "shim-required-true:claude-implement.yml: ANTHROPIC_API_KEY must be required: false" \
  "drop-api-key-input:anthropic_api_key is" \
  "unconditional-oauth:claude_code_oauth_token is" \
  "leak-review:ai_review_ai_merge: step 'Run agent review'" \
  "leak-selffix:ai_review_human_merge: step 'Self-fix loop" \
  "leak-job-env:implement: job-level keys"; do
  kind="${spec%%:*}"; want="${spec#*:}"
  mutate "$kind"
  got="$(check_workflows "$T/wf.yml" "$T/shim.yml")"
  if [[ "$got" == *"$want"* ]]; then pass "flags $kind"; else fail "flags $kind" "want: $want"$'\n'"got: ${got:-<clean>}"; fi
done

printf '\n── #540 this repo'\''s own caller forwards the key ──\n'
# shellcheck disable=SC2016  # literal Actions expression, not shell
if grep -qF 'ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}' "$ROOT/.github/workflows/agent.yml"; then
  pass "agent.yml forwards ANTHROPIC_API_KEY"
else
  fail "agent.yml forwards ANTHROPIC_API_KEY" "missing in .github/workflows/agent.yml"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then printf '  - %s\n' "${FAIL_NAMES[@]}"; exit 1; fi
