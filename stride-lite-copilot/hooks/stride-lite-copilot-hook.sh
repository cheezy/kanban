#!/usr/bin/env bash
# stride-lite-copilot-hook.sh — Bridges harness hooks to stride-lite-copilot .stride_lite.md hook execution.
#
# Called by the harness's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives the hook JSON on stdin, determines whether the tool call is one of the
# three stride-lite-copilot trigger conditions, and if so executes the corresponding
# `## before_task` / `## after_task` / `## after_goal` section from .stride_lite.md.
#
# Trigger conditions:
#   pre  + Agent + subagent_type == "stride-lite-copilot:task-explorer" → before_task  (blocking)
#   pre  + Agent + subagent_type == "stride-lite-copilot:task-reviewer" → after_task   (blocking)
#   post + (Edit|edit|Write|create) + file_path ~ */goal.md + body contains
#                                                 "## Completion Summary"  → after_goal  (advisory)
#
# Harness compatibility:
#   - Claude Code (PascalCase tool names: Agent, Edit, Write; stdin field "tool_name").
#   - GitHub Copilot CLI (lowercase tool names: edit, create; stdin field "toolName"; toolArgs
#     is a JSON-encoded string — substring-based field extraction still locates "file_path"
#     and "## Completion Summary" inside the encoded args). Copilot CLI does NOT currently
#     emit a skill/agent dispatch event, so before_task and after_task are dormant there
#     until Copilot adds the equivalent intercept point. The after_goal hook fires correctly
#     on both runtimes via the Edit|edit / Write|create matchers in hooks.json.
#
# Usage: echo '<hook-json>' | stride-lite-copilot-hook.sh <pre|post>
#
# Exit codes:
#   0 — success, no-op, or non-trigger
#   2 — blocking PreToolUse failure (only meaningful for pre + before_task/after_task)
#
# Cross-platform parity contract: this script and stride-lite-copilot-hook.ps1 MUST detect
# the same three trigger conditions, produce equivalent single-line JSON results
# for the same input, and apply the same exit-code contract.

set -uo pipefail

PHASE="${1:-}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
STRIDE_LITE_MD="$PROJECT_DIR/.stride_lite.md"

# --- Platform detection: delegate to PowerShell on native Windows ---
# Git Bash (OSTYPE=msys*) and WSL have full bash — run directly.
# Native Windows without bash (COMSPEC set, no OSTYPE) → delegate to .ps1
_delegate_to_ps1=false
if [ -z "${OSTYPE:-}" ] && [ -n "${COMSPEC:-}" ]; then
  _delegate_to_ps1=true
fi

if [ "$_delegate_to_ps1" = "true" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PS1_SCRIPT="$SCRIPT_DIR/stride-lite-copilot-hook.ps1"
  if [ ! -f "$PS1_SCRIPT" ]; then
    echo "stride-lite-copilot-hook.sh: Windows detected but stride-lite-copilot-hook.ps1 not found at $PS1_SCRIPT" >&2
    exit 2
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    echo "stride-lite-copilot-hook.sh: Windows detected but powershell.exe not found in PATH" >&2
    exit 2
  fi
  exec powershell.exe -ExecutionPolicy Bypass -File "$PS1_SCRIPT" "$PHASE"
fi

# --- Pure-bash JSON value extractor (no jq dependency) ---
# Extracts the first string value for the given key. Handles whitespace between
# colon and value, but does NOT handle escaped quotes inside values — fine for
# our use (tool_name, subagent_type, file_path are all simple identifiers/paths).
# Empty on miss.
_extract_string() {
  local key="$1"
  local input="$2"
  local tmp="${input#*\"$key\"}"
  if [ "$tmp" = "$input" ]; then
    printf ''
    return
  fi
  tmp="${tmp#*:}"
  tmp="${tmp#"${tmp%%[![:space:]]*}"}"
  case "$tmp" in
    \"*)
      tmp="${tmp#\"}"
      # Stop at first unescaped quote — for our keys this is sufficient.
      printf '%s' "${tmp%%\"*}"
      ;;
    *)
      printf ''
      ;;
  esac
}

# --- JSON string escape (no jq) ---
# Escapes backslash, double quote, and common control chars. Sufficient for
# emitting command strings, exit messages, and stdout/stderr tails.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# --- JSON array builder from a newline-delimited list ---
# Reads stdin one line per element, emits a compact JSON array literal.
_json_array_from_lines() {
  local first=1
  local line
  printf '['
  while IFS= read -r line; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ','
    fi
    printf '"%s"' "$(_json_escape "$line")"
  done
  printf ']'
}

# --- Parse and execute one .stride_lite.md hook section ---
# Mirrors stride-hook.sh:run_stride_section but reads .stride_lite.md, dispatches
# on the three stride-lite section names, and emits JSON without jq.
#
# Returns:
#   0 — section missing OR empty fenced block OR all commands succeeded
#   2 — first command failed; structured failure JSON emitted on stdout
run_stride_lite_section() {
  local _section="$1"
  local _commands=""
  local _found=0
  local _capture=0
  local _line _heading

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "## "*)
        [ "$_found" -eq 1 ] && break
        _heading="${_line#\#\# }"
        _heading="${_heading%"${_heading##*[![:space:]]}"}"
        [ "$_heading" = "$_section" ] && _found=1
        continue
        ;;
    esac
    if [ "$_found" -eq 1 ]; then
      case "$_line" in
        '```bash'*) _capture=1; continue ;;
        '```'*)     [ "$_capture" -eq 1 ] && break; continue ;;
      esac
      [ "$_capture" -eq 1 ] && _commands="${_commands}${_line}
"
    fi
  done < "$STRIDE_LITE_MD"

  if [ -z "$_commands" ]; then
    return 0
  fi

  local _cmd _trimmed
  local _cmd_list=()
  while IFS= read -r _cmd; do
    _trimmed="${_cmd#"${_cmd%%[![:space:]]*}"}"
    [ -z "$_trimmed" ] && continue
    case "$_trimmed" in \#*) continue ;; esac
    _cmd_list+=("$_trimmed")
  done <<< "$_commands"

  if [ ${#_cmd_list[@]} -eq 0 ]; then
    return 0
  fi

  cd "$PROJECT_DIR"
  local _completed_file
  _completed_file=$(mktemp)
  local _start_secs
  _start_secs=$(date +%s)
  local _cmd_index=0
  local _cmd_total=${#_cmd_list[@]}
  local _cmd_stdout_file _cmd_stderr_file _cmd_exit _cmd_stdout _cmd_stderr
  local _remaining_file _completed_json _remaining_json _end_secs _duration _i

  for _trimmed in "${_cmd_list[@]}"; do
    _cmd_stdout_file=$(mktemp)
    _cmd_stderr_file=$(mktemp)

    # Relax `set -u` and `pipefail` for the user's command so a reference to an
    # unset env var doesn't silently abort eval before the actual command runs.
    set +uo pipefail
    eval "$_trimmed" > "$_cmd_stdout_file" 2> "$_cmd_stderr_file"
    _cmd_exit=$?
    set -uo pipefail

    if [ "$_cmd_exit" -eq 0 ]; then
      echo "$_trimmed" >> "$_completed_file"
      cat "$_cmd_stdout_file" >&2
      cat "$_cmd_stderr_file" >&2
    else
      _cmd_stdout=$(tail -50 "$_cmd_stdout_file")
      _cmd_stderr=$(tail -50 "$_cmd_stderr_file")
      rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"

      _remaining_file=$(mktemp)
      if [ $((_cmd_index + 1)) -lt $_cmd_total ]; then
        for ((_i = _cmd_index + 1; _i < _cmd_total; _i++)); do
          echo "${_cmd_list[$_i]}" >> "$_remaining_file"
        done
      fi

      _completed_json=$(_json_array_from_lines < "$_completed_file")
      _remaining_json=$(_json_array_from_lines < "$_remaining_file")

      printf '{"hook":"%s","status":"failed","failed_command":"%s","command_index":%d,"exit_code":%d,"stdout":"%s","stderr":"%s","commands_completed":%s,"commands_remaining":%s}\n' \
        "$(_json_escape "$_section")" \
        "$(_json_escape "$_trimmed")" \
        "$_cmd_index" \
        "$_cmd_exit" \
        "$(_json_escape "$_cmd_stdout")" \
        "$(_json_escape "$_cmd_stderr")" \
        "$_completed_json" \
        "$_remaining_json"

      echo "stride-lite-copilot $_section hook failed on command $((_cmd_index + 1))/$_cmd_total: $_trimmed" >&2
      [ -n "$_cmd_stderr" ] && echo "$_cmd_stderr" >&2
      rm -f "$_completed_file" "$_remaining_file"
      return 2
    fi

    rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"
    _cmd_index=$((_cmd_index + 1))
  done

  _end_secs=$(date +%s)
  _duration=$((_end_secs - _start_secs))

  _completed_json=$(_json_array_from_lines < "$_completed_file")

  printf '{"hook":"%s","status":"success","commands_completed":%s,"duration_seconds":%d}\n' \
    "$(_json_escape "$_section")" \
    "$_completed_json" \
    "$_duration"

  rm -f "$_completed_file"
  return 0
}

# --- Main flow ---
# Early exits placed after function definitions so tests can source this script
# and invoke run_stride_lite_section in isolation.

if [ -z "$PHASE" ]; then
  return 0 2>/dev/null || exit 0
fi
if [ ! -f "$STRIDE_LITE_MD" ]; then
  return 0 2>/dev/null || exit 0
fi

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  exit 0
fi

# Try Claude Code's snake_case field first, fall back to Copilot CLI's camelCase.
TOOL_NAME=$(_extract_string "tool_name" "$INPUT")
if [ -z "$TOOL_NAME" ]; then
  TOOL_NAME=$(_extract_string "toolName" "$INPUT")
fi

HOOK_NAME=""
BLOCKING=0

case "$PHASE" in
  pre)
    # Agent is Claude Code's subagent-dispatch tool name. Copilot CLI has no
    # equivalent event yet (HOOK_RESEARCH); this branch fires only under
    # Claude Code today.
    if [ "$TOOL_NAME" = "Agent" ]; then
      SUBAGENT_TYPE=$(_extract_string "subagent_type" "$INPUT")
      case "$SUBAGENT_TYPE" in
        stride-lite-copilot:task-explorer) HOOK_NAME="before_task"; BLOCKING=1 ;;
        stride-lite-copilot:task-reviewer) HOOK_NAME="after_task";  BLOCKING=1 ;;
      esac
    fi
    ;;
  post)
    case "$TOOL_NAME" in
      Edit|Write|edit|create)
        FILE_PATH=$(_extract_string "file_path" "$INPUT")
        case "$FILE_PATH" in
          */goal.md|goal.md)
            # "## Completion Summary" detection — scan the entire hook JSON.
            # In goal.md edits, this string only appears in the Edit new_string
            # or Write content body, so a substring grep is reliable across
            # Claude Code's tool_input.new_string and Copilot CLI's toolArgs
            # JSON-encoded string.
            if printf '%s' "$INPUT" | grep -q '## Completion Summary'; then
              HOOK_NAME="after_goal"
              BLOCKING=0
            fi
            ;;
        esac
        ;;
    esac
    ;;
esac

if [ -z "$HOOK_NAME" ]; then
  exit 0
fi

run_stride_lite_section "$HOOK_NAME"
RC=$?

# PostToolUse cannot roll back the tool call — never block with exit 2 there.
# PreToolUse blocking failures propagate as exit 2 so the dispatch is aborted.
if [ "$BLOCKING" -eq 1 ] && [ "$RC" -ne 0 ]; then
  exit "$RC"
fi

exit 0
