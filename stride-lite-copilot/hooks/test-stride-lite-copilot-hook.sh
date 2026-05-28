#!/usr/bin/env bash
# test-stride-lite-copilot-hook.sh — Smoke test for the bash hook executor.
#
# Exercises the three .stride_lite.md trigger conditions plus the env-var
# defaulted-fallback and the cross-runtime field-name handling
# (Claude Code snake_case `tool_name` vs Copilot CLI camelCase `toolName`).
#
# Not a full test suite — intentionally compact for the v0.1.0 release.
# The stride-copilot/hooks/test-stride-hook.sh harness (60k lines, ~100 cases)
# is the heavier reference if we need expanded coverage later.
#
# Usage: bash test-stride-lite-copilot-hook.sh
# Exit:  0 = all assertions passed; 1 = one or more failed.

set -u  # NOT set -e — keep running after a failure to surface all problems

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/stride-lite-copilot-hook.sh"

if [ ! -x "$HOOK_SCRIPT" ]; then
  echo "test-stride-lite-copilot-hook.sh: $HOOK_SCRIPT not executable" >&2
  exit 1
fi

PASS=0
FAIL=0

ok() {
  PASS=$(( PASS + 1 ))
  echo "  PASS  $1"
}

nope() {
  FAIL=$(( FAIL + 1 ))
  echo "  FAIL  $1" >&2
  [ -n "${2:-}" ] && echo "        $2" >&2
}

# --- Setup: scratch project dir with a working .stride_lite.md ---
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

cat > "$SCRATCH/.stride_lite.md" <<'EOF'
## before_task

```bash
echo "before_task fired"
```

## after_task

```bash
echo "after_task fired"
```

## after_goal

```bash
echo "after_goal fired"
```
EOF

run_hook() {
  local phase="$1"
  local stdin_json="$2"
  printf '%s' "$stdin_json" | CLAUDE_PROJECT_DIR="$SCRATCH" "$HOOK_SCRIPT" "$phase" 2>/dev/null
}

# --- Case 1: missing .stride_lite.md → silent no-op (exit 0, no stdout) ---
echo "Case 1: missing .stride_lite.md"
EMPTY_SCRATCH=$(mktemp -d)
out=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite-copilot:task-explorer"}}' \
  | CLAUDE_PROJECT_DIR="$EMPTY_SCRATCH" "$HOOK_SCRIPT" pre 2>/dev/null)
rc=$?
rm -rf "$EMPTY_SCRATCH"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "missing .stride_lite.md → exit 0 + no stdout"
else
  nope "missing .stride_lite.md" "rc=$rc, stdout='$out'"
fi

# --- Case 2: Claude Code snake_case + Agent + task-explorer → fires before_task ---
echo "Case 2: Claude Code snake_case payload triggers before_task"
out=$(run_hook pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite-copilot:task-explorer"}}')
if echo "$out" | grep -q '"hook":"before_task"' && echo "$out" | grep -q '"status":"success"'; then
  ok "Claude Code snake_case → before_task fires"
else
  nope "Claude Code snake_case → before_task" "stdout='$out'"
fi

# --- Case 3: Claude Code snake_case + Agent + task-reviewer → fires after_task ---
echo "Case 3: Claude Code snake_case payload triggers after_task"
out=$(run_hook pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite-copilot:task-reviewer"}}')
if echo "$out" | grep -q '"hook":"after_task"' && echo "$out" | grep -q '"status":"success"'; then
  ok "Claude Code snake_case → after_task fires"
else
  nope "Claude Code snake_case → after_task" "stdout='$out'"
fi

# --- Case 4: Copilot camelCase toolName fallback → fires before_task ---
echo "Case 4: Copilot camelCase toolName triggers before_task via fallback"
out=$(run_hook pre '{"toolName":"Agent","tool_input":{"subagent_type":"stride-lite-copilot:task-explorer"}}')
if echo "$out" | grep -q '"hook":"before_task"'; then
  ok "Copilot camelCase toolName → before_task fires"
else
  nope "Copilot camelCase toolName" "stdout='$out'"
fi

# --- Case 5: post + Edit + goal.md + Completion Summary → fires after_goal ---
echo "Case 5: PostToolUse Edit on goal.md with Completion Summary → after_goal"
out=$(run_hook post '{"tool_name":"Edit","tool_input":{"file_path":"docs/implementation/PENDING/some-goal/goal.md","new_string":"... ## Completion Summary ..."}}')
if echo "$out" | grep -q '"hook":"after_goal"'; then
  ok "Edit + goal.md + Completion Summary → after_goal fires"
else
  nope "Edit + goal.md + Completion Summary" "stdout='$out'"
fi

# --- Case 6: Copilot lowercase 'edit' + goal.md + Completion Summary → fires after_goal ---
echo "Case 6: Copilot lowercase 'edit' triggers after_goal"
out=$(run_hook post '{"toolName":"edit","tool_input":{"file_path":"goal.md","new_string":"## Completion Summary"}}')
if echo "$out" | grep -q '"hook":"after_goal"'; then
  ok "Copilot 'edit' + goal.md + Completion Summary → after_goal fires"
else
  nope "Copilot 'edit'" "stdout='$out'"
fi

# --- Case 7: post + Edit on goal.md WITHOUT Completion Summary → no-op ---
echo "Case 7: PostToolUse Edit on goal.md WITHOUT Completion Summary → no-op"
out=$(run_hook post '{"tool_name":"Edit","tool_input":{"file_path":"goal.md","new_string":"some other change"}}')
if [ -z "$out" ]; then
  ok "Edit + goal.md WITHOUT Completion Summary → no-op (no stdout)"
else
  nope "Edit + goal.md WITHOUT Completion Summary should no-op" "stdout='$out'"
fi

# --- Case 8: env-var fallback (CLAUDE_PROJECT_DIR unset) → uses cwd ---
echo "Case 8: env-var defaulted-fallback when CLAUDE_PROJECT_DIR unset"
out=$(cd "$SCRATCH" && unset CLAUDE_PROJECT_DIR && \
  printf '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite-copilot:task-explorer"}}' \
  | "$HOOK_SCRIPT" pre 2>/dev/null)
if echo "$out" | grep -q '"hook":"before_task"'; then
  ok "Unset CLAUDE_PROJECT_DIR + cwd .stride_lite.md → before_task fires"
else
  nope "Unset CLAUDE_PROJECT_DIR fallback" "stdout='$out'"
fi

# --- Case 9: non-matching tool (e.g., Bash) → no-op ---
echo "Case 9: non-matching tool name (Bash) → no-op"
out=$(run_hook pre '{"tool_name":"Bash","tool_input":{"command":"ls"}}')
if [ -z "$out" ]; then
  ok "Bash tool name → no-op (no stdout)"
else
  nope "Bash tool name should no-op" "stdout='$out'"
fi

# --- Case 10: subagent dispatch to a NON-stride-lite-copilot subagent → no-op ---
echo "Case 10: Agent with other subagent_type → no-op"
out=$(run_hook pre '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}')
if [ -z "$out" ]; then
  ok "Agent + non-matching subagent_type → no-op"
else
  nope "Agent + non-matching subagent_type should no-op" "stdout='$out'"
fi

# --- Summary ---
echo ""
echo "------------------------------------------------------------------"
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
