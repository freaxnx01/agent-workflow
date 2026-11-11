#!/usr/bin/env bash
#
#
# run-azdo-templates-tests.sh — Layer-1 tests for templates/azdo/pr-validation.yml.
# A Python checker (PyYAML) walks the parsed YAML and reports one violation id per
# line; the template must be clean and every bad-*.yml fixture must trip its own id.
#
# Usage: tests/run-azdo-templates-tests.sh
# Exit codes: 0 all pass (or PyYAML missing: skipped); 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/templates/azdo/pr-validation.yml"
FIXTURES="$ROOT/tests/fixtures/azdo-templates"

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "SKIP: PyYAML not available"
  exit 0
fi

PASS=0
FAIL=0
FAIL_NAMES=()

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_OFF=''
fi

section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else fail "$name" "expected: $expected | actual: $actual"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else fail "$name" "missing: $needle | in: $haystack"; fi
}

CHECKER="$(mktemp)"
trap 'rm -f "$CHECKER"' EXIT
cat > "$CHECKER" <<'PY'
import re
import sys
import yaml

TOKEN = re.compile(r"System\.AccessToken|SYSTEM_ACCESSTOKEN")
SECRET_VALUE = re.compile(r"System\.AccessToken|SYSTEM_ACCESSTOKEN|CLAUDE", re.I)
SECRET_KEY = re.compile(r"CLAUDE|SYSTEM_ACCESSTOKEN", re.I)
found = []


def walk(node):
    if isinstance(node, dict):
        if "checkout" in node and node.get("persistCredentials"):
            found.append("persist_credentials")
        env = node.get("env")
        if isinstance(env, dict):
            for key, value in env.items():
                if SECRET_KEY.search(str(key)) or SECRET_VALUE.search(str(value)):
                    found.append("env_secret")
        variables = node.get("variables")
        if isinstance(variables, list):
            for item in variables:
                if isinstance(item, dict) and "group" in item:
                    found.append("variable_group")
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)
    elif isinstance(node, str) and TOKEN.search(node):
        found.append("access_token_anywhere")


with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)
if doc.get("trigger") != "none":
    found.append("trigger_not_none")
if doc.get("pr") != "none":
    found.append("pr_not_none")
walk(doc)
for violation in dict.fromkeys(found):
    print(violation)
sys.exit(1 if found else 0)
PY

RC=0
OUT=""
# check_template <file> — sets RC and OUT from the checker.
check_template() {
  RC=0
  OUT="$(python3 -I "$CHECKER" "$1" 2>&1)" || RC=$?
}

section "template"
check_template "$TEMPLATE"
assert_eq "template_is_clean: rc" 0 "$RC"
assert_eq "template_is_clean: output" "" "$OUT"

TEXT="$(cat "$TEMPLATE" 2>/dev/null || true)"
assert_contains "template_has_pool_placeholder" "pool: <pool>" "$TEXT"
assert_contains "template_header_names_target" "azure-pipelines-pr.yml" "$TEXT"
assert_contains "template_persist_credentials_false" "persistCredentials: false" "$TEXT"

section "bad fixtures"
detects() { # <fixture-name> <violation-id>
  check_template "$FIXTURES/$1.yml"
  assert_eq "detects_$1: rc" 1 "$RC"
  assert_contains "detects_$1: id" "$2" "$OUT"
}
detects bad-trigger trigger_not_none
detects bad-pr pr_not_none
detects bad-persist-credentials persist_credentials
detects bad-env-access-token env_secret
detects bad-env-system-accesstoken env_secret
detects bad-env-claude env_secret
detects bad-script-macro access_token_anywhere
detects bad-variable-group variable_group
detects bad-nested-variable-group variable_group

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'Failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
