# context-meter (PowerShell): Claude Code PostToolUse hook that tells the agent (main session or subagent)
# its own context-window size once it crosses a threshold.
# Thresholds and messages live in context-meter.config.ps1 next to this script.
# Works on Windows PowerShell 5.1 and PowerShell 7+. No jq needed.
$conf = Join-Path $PSScriptRoot 'context-meter.config.ps1'
if (-not (Test-Path -LiteralPath $conf)) { exit 0 }
. $conf

# `context-meter.ps1 handoff <file> <project-dir>` is run by the main agent (not as a hook) once it has
# written its handoff. It starts the next session per $HANDOFF_MODE and prints what to tell the user.
if ($args[0] -eq 'handoff') {
    $f = $args[1]
    $dir = if ($args[2]) { $args[2] } else { $PWD.Path }
    if ($HANDOFF_MODE -eq 'terminal') {
        # A new PowerShell window running a fresh session. It inherits this environment, so drop the parent
        # session's CLAUDE* markers first (CLAUDE_CODE_CHILD_SESSION turns off transcript saving, and with it
        # this meter), keeping any you set yourself. --add-dir lets it read the handoff without a prompt; it
        # goes after the prompt because it takes several directories and would swallow the prompt.
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE*' -and -not [Environment]::GetEnvironmentVariable($_.Name, 'User') -and -not [Environment]::GetEnvironmentVariable($_.Name, 'Machine') } | ForEach-Object { Remove-Item -LiteralPath "Env:$($_.Name)" }
        $prompt = "Read the handoff at $f and continue from it." -replace "'", "''"
        $addDir = (Split-Path -Parent $f) -replace "'", "''"
        try {
            Start-Process (Get-Process -Id $PID).Path -WorkingDirectory $dir -ErrorAction Stop -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', "claude '$prompt' --add-dir '$addDir'"
            'Opened a new PowerShell window running a fresh Claude Code session that starts from the handoff. Tell the user to continue there and close this one.'
            exit 0
        } catch {}
    }
    # clear, or the new window failed: the user runs /clear and pastes.
    try {
        "Continue from this handoff:`n`n" + (Get-Content -Raw -LiteralPath $f) | Set-Clipboard -ErrorAction Stop
        'Copied the handoff to the clipboard. Tell the user to run /clear, then paste.'
    } catch {
        "No clipboard available. Tell the user to run /clear, then paste the contents of $f."
    }
    exit 0
}

$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
$t = $in.transcript_path
if (-not $t) { exit 0 }
# Only subagents and teammates have an agent_id. The main session is measured only with $MAIN_SESSION = 'on'.
if (-not $in.agent_id -and $MAIN_SESSION -ne 'on') { exit 0 }
$agentType = if ($in.agent_type) { $in.agent_type } else { 'subagent' }
# Subagent hooks receive the parent's transcript_path; the subagent's own transcript
# lives at <session>/subagents/agent-<id>.jsonl
if ($in.agent_id) { $t = Join-Path ($t -replace '\.jsonl$', '') "subagents/agent-$($in.agent_id).jsonl" }
if (-not (Test-Path -LiteralPath $t)) { exit 0 }

# Context size = input + cache_creation + cache_read of the latest assistant turn
$line = Select-String -LiteralPath $t -Pattern '"cache_read_input_tokens"' -SimpleMatch | Select-Object -Last 1
if (-not $line) { exit 0 }
$u = ($line.Line | ConvertFrom-Json).message.usage
if (-not $u) { exit 0 }
$n = [int64]$u.input_tokens + [int64]$u.cache_creation_input_tokens + [int64]$u.cache_read_input_tokens
if ($n -lt $WARN) { exit 0 }

$msg = if ($n -lt $HANDOFF) { $WARN_MSG } elseif ($in.agent_id) { $HANDOFF_MSG_SUBAGENT } else { $HANDOFF_MSG_MAIN }
$msg = "$PREFIX $msg"
$msg = $msg.Replace('{tokens}', "$([math]::Floor($n / 1000))k")
$msg = $msg.Replace('{warn}', "$([math]::Floor($WARN / 1000))k")
$msg = $msg.Replace('{handoff}', "$([math]::Floor($HANDOFF / 1000))k")
$msg = $msg.Replace('{agent_type}', $agentType)
$msg = $msg.Replace('{script}', $PSCommandPath)
$msg = $msg.Replace('{project_dir}', $(if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { "$($in.cwd)" }))

@{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $msg } } | ConvertTo-Json -Compress
