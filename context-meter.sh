#!/bin/bash
# context-meter: Claude Code PostToolUse hook that tells the agent (main session or subagent)
# its own context-window size once it crosses a threshold.
# Thresholds and messages live in context-meter.conf next to this script.
conf="$(dirname "$0")/context-meter.conf"
[ -f "$conf" ] || exit 0
. "$conf"

in=$(cat)
t=$(jq -r '.transcript_path // empty' <<<"$in")
agent_id=$(jq -r '.agent_id // empty' <<<"$in")
agent_type=$(jq -r '.agent_type // "subagent"' <<<"$in")
# Subagent hooks receive the parent's transcript_path; the subagent's own transcript
# lives at <session>/subagents/agent-<id>.jsonl
[ -n "$agent_id" ] && t="${t%.jsonl}/subagents/agent-$agent_id.jsonl"
[ -f "$t" ] || exit 0

# Context size = input + cache_creation + cache_read of the latest assistant turn
n=$(grep '"cache_read_input_tokens"' "$t" | tail -1 | jq '.message.usage | .input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens' 2>/dev/null)
[ -n "$n" ] && [ "$n" -ge "$WARN" ] || exit 0

if [ "$n" -lt "$HANDOFF" ]; then
  msg=$WARN_MSG
elif [ -n "$agent_id" ]; then
  msg=$HANDOFF_MSG_SUBAGENT
else
  msg=$HANDOFF_MSG_MAIN
fi
msg="$PREFIX $msg"
msg=${msg//\{tokens\}/$((n / 1000))k}
msg=${msg//\{warn\}/$((WARN / 1000))k}
msg=${msg//\{handoff\}/$((HANDOFF / 1000))k}
msg=${msg//\{agent_type\}/$agent_type}

jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
