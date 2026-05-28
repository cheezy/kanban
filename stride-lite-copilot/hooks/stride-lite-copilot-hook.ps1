param(
    [Parameter(Position = 0)]
    [string]$Phase = ''
)

# stride-lite-copilot-hook.ps1 — Bridges harness hooks to stride-lite-copilot .stride_lite.md hook execution.
#
# PowerShell companion to stride-lite-copilot-hook.sh for Windows compatibility.
# Called by the harness's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives the hook JSON on stdin, determines whether the tool call is one of the
# three stride-lite-copilot trigger conditions, and if so executes the corresponding
# `## before_task` / `## after_task` / `## after_goal` section from .stride_lite.md.
#
# Trigger conditions (identical to stride-lite-copilot-hook.sh):
#   pre  + Agent + subagent_type == "stride-lite-copilot:task-explorer" → before_task  (blocking)
#   pre  + Agent + subagent_type == "stride-lite-copilot:task-reviewer" → after_task   (blocking)
#   post + (Edit|edit|Write|create) + file_path ~ */goal.md + body contains
#                                                 "## Completion Summary"  → after_goal  (advisory)
#
# Harness compatibility: handles both Claude Code (PascalCase tool_name; tool_input as
# object) and GitHub Copilot CLI (camelCase toolName; toolArgs as JSON-encoded string).
# Copilot CLI does not currently emit a skill/agent dispatch event, so before_task and
# after_task are dormant under Copilot today; the after_goal hook fires correctly on
# both runtimes via the Edit|edit / Write|create matchers in hooks.json.
#
# Usage: echo '<hook-json>' | pwsh stride-lite-copilot-hook.ps1 <pre|post>
#
# Exit codes:
#   0 — success, no-op, or non-trigger
#   2 — blocking PreToolUse failure (only meaningful for pre + before_task/after_task)
#
# Cross-platform parity contract: this script and stride-lite-copilot-hook.sh MUST detect
# the same three trigger conditions, produce equivalent single-line JSON results
# for the same input, and apply the same exit-code contract.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { '.' }
$StrideLiteMd = Join-Path $ProjectDir '.stride_lite.md'

if (-not $Phase) { exit 0 }
if (-not (Test-Path $StrideLiteMd)) { exit 0 }

# Read Claude Code hook input from stdin
$InputJson = @($input) -join "`n"
if (-not $InputJson) { exit 0 }

# --- Pure JSON parsing via built-in ConvertFrom-Json (no module installs) ---
$ToolName = ''
$SubagentType = ''
$FilePath = ''
try {
    $parsed = $InputJson | ConvertFrom-Json
    # Claude Code uses tool_name + tool_input (object). Copilot CLI uses toolName + toolArgs
    # (JSON-encoded string). Try both.
    if ($parsed.PSObject.Properties.Name -contains 'tool_name') {
        $ToolName = [string]$parsed.tool_name
    }
    if (-not $ToolName -and $parsed.PSObject.Properties.Name -contains 'toolName') {
        $ToolName = [string]$parsed.toolName
    }
    if ($parsed.PSObject.Properties.Name -contains 'tool_input' -and $parsed.tool_input) {
        $ti = $parsed.tool_input
        if ($ti.PSObject.Properties.Name -contains 'subagent_type') {
            $SubagentType = [string]$ti.subagent_type
        }
        if ($ti.PSObject.Properties.Name -contains 'file_path') {
            $FilePath = [string]$ti.file_path
        }
    }
    if (-not $FilePath -and $parsed.PSObject.Properties.Name -contains 'toolArgs' -and $parsed.toolArgs) {
        # Copilot CLI: toolArgs is a JSON-encoded string. Decode once more.
        try {
            $tArgs = $parsed.toolArgs | ConvertFrom-Json
            if ($tArgs.PSObject.Properties.Name -contains 'file_path') {
                $FilePath = [string]$tArgs.file_path
            }
        } catch {
            # toolArgs not parseable as JSON — leave $FilePath empty.
        }
    }
} catch {
    # Malformed JSON — silent no-op.
    exit 0
}

# --- Determine which stride-lite hook to run ---
$HookName = ''
$Blocking = $false

switch ($Phase) {
    'pre' {
        # Agent is Claude Code's subagent-dispatch tool name. Copilot CLI has no
        # equivalent event yet; this branch fires only under Claude Code today.
        if ($ToolName -eq 'Agent') {
            switch ($SubagentType) {
                'stride-lite-copilot:task-explorer' { $HookName = 'before_task'; $Blocking = $true }
                'stride-lite-copilot:task-reviewer' { $HookName = 'after_task';  $Blocking = $true }
            }
        }
    }
    'post' {
        if ($ToolName -eq 'Edit' -or $ToolName -eq 'Write' -or $ToolName -eq 'edit' -or $ToolName -eq 'create') {
            if ($FilePath -match '(^|[/\\])goal\.md$') {
                # "## Completion Summary" detection — scan the entire hook JSON.
                # In goal.md edits, this string only appears in the Edit new_string
                # or Write content body, so a substring match is reliable.
                if ($InputJson -match '## Completion Summary') {
                    $HookName = 'after_goal'
                    $Blocking = $false
                }
            }
        }
    }
}

if (-not $HookName) { exit 0 }

# --- Parse and execute one .stride_lite.md hook section ---
# Returns:
#   0 — section missing OR empty fenced block OR all commands succeeded
#   2 — first command failed; structured failure JSON emitted on stdout
function Invoke-StrideLiteSection {
    param([string]$Section)

    $raw = Get-Content $StrideLiteMd -Raw -Encoding UTF8
    $raw = $raw -replace "`r`n", "`n"
    $lines = $raw -split "`n"

    $commandsText = ''
    $found = $false
    $capture = $false

    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd("`r")

        if ($line -match '^## (.+)$') {
            if ($found) { break }
            $heading = $Matches[1].TrimEnd()
            if ($heading -eq $Section) { $found = $true }
            continue
        }

        if ($found) {
            if ($line -match '^```bash') {
                $capture = $true
                continue
            }
            if ($line -match '^```') {
                if ($capture) { break }
                continue
            }
            if ($capture) {
                $commandsText += $line + "`n"
            }
        }
    }

    if (-not $commandsText.Trim()) {
        return 0
    }

    $cmdList = @()
    foreach ($cmd in ($commandsText -split "`n")) {
        $trimmedCmd = $cmd.TrimStart()
        if (-not $trimmedCmd) { continue }
        if ($trimmedCmd.StartsWith('#')) { continue }
        $cmdList += $trimmedCmd
    }

    if ($cmdList.Count -eq 0) {
        return 0
    }

    Set-Location $ProjectDir
    $completedCmds = @()
    $startTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cmdIndex = 0
    $cmdTotal = $cmdList.Count

    foreach ($execTrimmed in $cmdList) {
        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()

        try {
            # Delegate user command execution to bash so .stride_lite.md content
            # stays POSIX-portable (git-bash on Windows ships bash.exe; WSL also
            # provides one). Users who want native PowerShell can wrap their line
            # with `pwsh -c '...'` inside their bash block.
            $proc = Start-Process -FilePath 'bash' -ArgumentList '-c', $execTrimmed `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError $stderrFile `
                -NoNewWindow -Wait -PassThru

            if ($proc.ExitCode -eq 0) {
                $completedCmds += $execTrimmed
                if (Test-Path $stdoutFile) {
                    $stdoutText = Get-Content $stdoutFile -Raw -Encoding UTF8
                    if ($stdoutText) { [Console]::Error.Write($stdoutText) }
                }
                if (Test-Path $stderrFile) {
                    $stderrText = Get-Content $stderrFile -Raw -Encoding UTF8
                    if ($stderrText) { [Console]::Error.Write($stderrText) }
                }
            } else {
                $cmdExit = $proc.ExitCode
                $cmdStdout = ''
                $cmdStderr = ''
                if (Test-Path $stdoutFile) {
                    $allLines = @(Get-Content $stdoutFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $cmdStdout = $allLines -join "`n"
                }
                if (Test-Path $stderrFile) {
                    $allLines = @(Get-Content $stderrFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $cmdStderr = $allLines -join "`n"
                }
                Remove-Item -Force $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

                $remainingCmds = @()
                if (($cmdIndex + 1) -lt $cmdTotal) {
                    $remainingCmds = $cmdList[($cmdIndex + 1)..($cmdTotal - 1)]
                }

                $failureResult = [ordered]@{
                    hook               = $Section
                    status             = 'failed'
                    failed_command     = $execTrimmed
                    command_index      = $cmdIndex
                    exit_code          = $cmdExit
                    stdout             = $cmdStdout
                    stderr             = $cmdStderr
                    commands_completed = @($completedCmds)
                    commands_remaining = @($remainingCmds)
                }
                # Write JSON directly to the host stdout stream to avoid
                # capturing it in the caller's `$rc = Invoke-StrideLiteSection`
                # assignment.
                [Console]::Out.WriteLine(($failureResult | ConvertTo-Json -Depth 5 -Compress))
                [Console]::Error.WriteLine("stride-lite-copilot $Section hook failed on command $($cmdIndex + 1)/$($cmdTotal): $execTrimmed")
                if ($cmdStderr) { [Console]::Error.WriteLine($cmdStderr) }

                return 2
            }
        } finally {
            Remove-Item -Force $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
        }

        $cmdIndex++
    }

    $endTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $duration = $endTime - $startTime

    $successResult = [ordered]@{
        hook               = $Section
        status             = 'success'
        commands_completed = @($completedCmds)
        duration_seconds   = $duration
    }
    [Console]::Out.WriteLine(($successResult | ConvertTo-Json -Depth 5 -Compress))

    return 0
}

$rc = Invoke-StrideLiteSection -Section $HookName

# PostToolUse cannot roll back the tool call — never block with exit 2 there.
# PreToolUse blocking failures propagate as exit 2 so the dispatch is aborted.
if ($Blocking -and $rc -ne 0) {
    exit $rc
}

exit 0
