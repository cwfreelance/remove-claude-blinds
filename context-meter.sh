#!/bin/bash
# context-meter: Claude Code PostToolUse hook that tells the agent (main session or subagent)
# its own context-window size once it crosses a threshold.
# Thresholds and messages live in context-meter.conf next to this script.
conf="$(dirname "$0")/context-meter.conf"
[ -f "$conf" ] || exit 0
. "$conf"

# `context-meter.sh handoff <file> <project-dir>` is run by the main agent (not as a hook) once it has
# written its handoff. It starts the next session per HANDOFF_MODE and prints what to tell the user.
if [ "$1" = handoff ]; then
  f=$2 dir=${3:-$PWD}
  # terminal: a new Terminal window running a fresh session. Launched through Terminal rather than
  # directly, because a claude started from the agent's shell inherits a marker that turns off
  # transcript saving (and with it this meter). --add-dir lets it read the handoff without a prompt;
  # it goes after the prompt because it takes several directories and would swallow the prompt.
  if [ "$HANDOFF_MODE" = terminal ] && osascript -e 'on run argv' \
    -e 'tell application "Terminal" to do script "cd " & quoted form of item 1 of argv & " && claude " & quoted form of item 3 of argv & " --add-dir " & quoted form of item 2 of argv' \
    -e 'end run' "$dir" "$(dirname "$f")" "Read the handoff at $f and continue from it." >/dev/null 2>&1; then
    echo "Opened a new Terminal window running a fresh Claude Code session that starts from the handoff. Tell the user to continue there and close this one."
    exit 0
  fi
  # clear, or terminal without osascript (Linux): the user runs /clear and pastes.
  if { printf 'Continue from this handoff:\n\n'; cat "$f"; } | { pbcopy || wl-copy || xclip -selection clipboard; } 2>/dev/null; then
    echo "Copied the handoff to the clipboard. Tell the user to run /clear, then paste."
  else
    echo "No clipboard tool found. Tell the user to run /clear, then paste the contents of $f."
  fi
  exit 0
fi

in=$(cat)
t=$(jq -r '.transcript_path // empty' <<<"$in")
agent_id=$(jq -r '.agent_id // empty' <<<"$in")
agent_type=$(jq -r '.agent_type // "subagent"' <<<"$in")
# Only subagents and teammates have an agent_id. The main session is measured only with MAIN_SESSION=on,
# and never in the cloud (CLAUDE_CODE_REMOTE), where neither handoff mode can reach the user.
if [ -z "$agent_id" ]; then
  [ "$MAIN_SESSION" = on ] && [ "$CLAUDE_CODE_REMOTE" != true ] || exit 0
fi
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
msg=${msg//\{script\}/$0}
msg=${msg//\{project_dir\}/${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // empty' <<<"$in")}}

jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
