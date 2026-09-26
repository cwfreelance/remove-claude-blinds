# context-meter configuration. Dot-sourced by context-meter.ps1 (PowerShell syntax).
#
# Placeholders, filled in when the message is sent:
#   {tokens}      current context size, e.g. 185k
#   {warn}        WARN threshold, e.g. 150k
#   {handoff}     HANDOFF threshold, e.g. 180k
#   {agent_type}  subagent type, e.g. general-purpose (subagent messages only)

# --- Thresholds (tokens) ---
# Below WARN: silent, zero cost. WARN..HANDOFF: WARN_MSG. HANDOFF and up: a handoff message.
# To skip the warning tier, set WARN equal to HANDOFF.
$WARN = 150000
$HANDOFF = 180000

# --- Messages ---
# Prepended to every message. If you change the "[context-meter" tag, update your CLAUDE.md line to match.
$PREFIX = "[context-meter: a PostToolUse hook the user configured, running context-meter.ps1] It measures this agent's current context-window size from its transcript. This is NOT the <total_tokens> reminder, which is the overall session token budget, so the two numbers are expected to differ. The user wants handoffs at {handoff}."

# Shared pieces, reused below.
$HANDOFF_CONTENTS = "The handoff is a throwaway file in your scratchpad directory (not the repo). It covers: the task and its source (issue/spec), what's done, what's left, the current git state, open review findings and pending decisions, and gotchas/dead ends."
$NO_GIT = "Do not commit, push, or touch the PR/issue as part of this. Record the git state (branch, uncommitted changes) in the handoff instead."

$WARN_MSG = "Context: {tokens} tokens (handoff at {handoff}). Wrap up the current unit of work. Don't start another review round or a large change."

$HANDOFF_MSG_MAIN = "CONTEXT LIMIT: you are at {tokens} tokens. Finish the step you're in the middle of, then write a handoff and spawn a fresh subagent pointed at it. Use a normal subagent, NOT a fork: a fork inherits this full context. $HANDOFF_CONTENTS Once the subagent finishes, don't close it or act on its report. Stop and let the user reply to the subagent directly. $NO_GIT"

# Subagents can't spawn subagents, so they hand back to the parent instead.
$HANDOFF_MSG_SUBAGENT = "CONTEXT LIMIT: you ({agent_type} subagent) are at {tokens} tokens. Finish the step you're in the middle of, write a handoff, then stop. $HANDOFF_CONTENTS Start your final report with 'CONTEXT LIMIT: handoff at <path>' and tell the parent NOT to resume you via SendMessage, but to spawn a fresh {agent_type} subagent (not a fork) pointed at the handoff. $NO_GIT"
