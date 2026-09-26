# context-meter (PowerShell): Claude Code PostToolUse hook that tells the agent (main session or subagent)
# its own context-window size once it crosses a threshold.
# Thresholds and messages live in context-meter.config.ps1 next to this script.
# Works on Windows PowerShell 5.1 and PowerShell 7+. No jq needed.
$conf = Join-Path $PSScriptRoot 'context-meter.config.ps1'
if (-not (Test-Path -LiteralPath $conf)) { exit 0 }
. $conf

$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
$t = $in.transcript_path
if (-not $t) { exit 0 }
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

@{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $msg } } | ConvertTo-Json -Compress
