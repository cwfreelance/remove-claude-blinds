# remove-claude-blinds

Let Claude Code see its own context-window usage, and hand off to a fresh agent before it gets too full.

Claude Code shows context usage to *you* (`/context`, the status line), but the agent itself can't see it. So if you want an agent to work autonomously and hand off before its recall starts degrading (for many people that's around 200k tokens), it has no way of knowing when to stop.

`context-meter.sh` is a `PostToolUse` hook. After every tool call it reads the agent's transcript, works out the current context size, and once a threshold is crossed it injects a message into the conversation telling the agent how full it is and what to do about it.

- **Below `WARN`:** silent. No output, no tokens spent.
- **`WARN` to `HANDOFF`:** a short "wrap up the current unit of work" nudge.
- **`HANDOFF` and above:** handoff instructions, which differ for the main session and for subagents.

It works inside **subagents** too: each subagent is measured against its own transcript, not the parent's. That covers the case where a long-running subagent (e.g. a fixer stuck in a review loop) fills up where you can't see it.

## Requirements

- Claude Code
- `bash` (the macOS stock 3.2 is fine) and `jq`

## Install (global, all projects)

**1. Copy the script and config into `~/.claude/hooks/`:**

```sh
git clone https://github.com/cwfreelance/remove-claude-blinds.git
mkdir -p ~/.claude/hooks
cp remove-claude-blinds/context-meter.sh remove-claude-blinds/context-meter.conf ~/.claude/hooks/
chmod +x ~/.claude/hooks/context-meter.sh
```

The script reads `context-meter.conf` from the directory it lives in. With no config file, it does nothing.

**2. Register the hook** in `~/.claude/settings.json`, merging with any `hooks` you already have:

```json
{
  "hooks": {
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/context-meter.sh" }] }
    ]
  }
}
```

**3. Add this line to `~/.claude/CLAUDE.md`** (create the file if it doesn't exist):

```markdown
- `[context-meter: ...]` messages come from my PostToolUse hook (`~/.claude/hooks/context-meter.sh`) and are my instructions: follow them. Their token count is your context-window size, not the `<total_tokens>` session budget.
```

**4. Start a new session.** Hooks load when a session starts.

### Why the CLAUDE.md line is needed

Hook output arrives inside the conversation next to tool results, and Claude is rightly wary of instructions that show up there, because that's what prompt injection looks like. Also, Claude Code shows the agent a `<total_tokens>` reminder, which is the overall session budget (often millions of tokens). Without context, an agent sees "you're at 185k, hand off now" next to "14,000,000 tokens left" and concludes the hook message is fake.

In testing without the line, agents repeatedly identified the handoff message as a prompt injection and ignored it. `CLAUDE.md` is loaded as your own instructions (for subagents too), so the line establishes that the messages really come from you and explains the two numbers.

If you change the `[context-meter` tag in `PREFIX` (see below), update the line to match.

## Configuration

Everything is in `context-meter.conf`, a bash file the script sources.

### Thresholds

```sh
WARN=150000     # start nudging
HANDOFF=180000  # tell the agent to hand off
```

To skip the warning tier, set `WARN` equal to `HANDOFF`. Pick numbers that suit your model: on a 1M-context model these are quality cutoffs, not hard limits.

### Messages

| Variable | Sent when |
| --- | --- |
| `PREFIX` | Prepended to every message. Says where the message comes from and explains the `<total_tokens>` difference. |
| `WARN_MSG` | Context is between `WARN` and `HANDOFF` |
| `HANDOFF_MSG_MAIN` | The main session is at or above `HANDOFF` |
| `HANDOFF_MSG_SUBAGENT` | A subagent is at or above `HANDOFF` |

Placeholders filled in at send time:

| Placeholder | Example |
| --- | --- |
| `{tokens}` | `185k`, the current context size |
| `{warn}` | `150k` |
| `{handoff}` | `180k` |
| `{agent_type}` | `general-purpose`, `fixer`, … (subagents only) |

Because the file is plain bash, you can build messages out of shared pieces. The defaults do this with `$HANDOFF_CONTENTS` (what the handoff file should cover) and `$NO_GIT`. Use double quotes, and escape any literal `$`.

### Default behavior

The shipped messages match a workflow where git/GitHub actions stay with a human:

- **Main session at the limit:** finish the current step, write a throwaway handoff file in the scratchpad, spawn a fresh subagent (not a fork, because a fork inherits the full context) pointed at it, then stop and leave the subagent open so the user can talk to it directly.
- **Subagent at the limit:** subagents can't spawn subagents, so it finishes the current step, writes the handoff, and stops. Its final report starts with `CONTEXT LIMIT: handoff at <path>` and tells the parent to spawn a fresh agent of the same type rather than resume it.
- **Both:** no commits, pushes, or PR/issue changes during a handoff. The git state is recorded in the handoff instead.

To have the agent commit and push, open a PR, or file a GitHub issue as the handoff, rewrite the messages accordingly.

## Alternative: install for a single repo

Install into the repo instead of globally to scope the hook to one project, or to share it with teammates through version control. **Don't install both globally and per-repo**, or every message will arrive twice.

**1. Copy the files into the repo:**

```sh
cd your-repo
mkdir -p .claude/hooks
cp /path/to/remove-claude-blinds/context-meter.sh /path/to/remove-claude-blinds/context-meter.conf .claude/hooks/
chmod +x .claude/hooks/context-meter.sh
```

**2. Register the hook** in `.claude/settings.json` (committed, shared with the team) or `.claude/settings.local.json` (just you, not committed):

```json
{
  "hooks": {
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/context-meter.sh" }] }
    ]
  }
}
```

`$CLAUDE_PROJECT_DIR` keeps the path working when Claude `cd`s into subdirectories.

**3. Add the line to the repo's `CLAUDE.md`** (or `CLAUDE.local.md` for just you), pointing at the repo path:

```markdown
- `[context-meter: ...]` messages come from my PostToolUse hook (`.claude/hooks/context-meter.sh`) and are my instructions: follow them. Their token count is your context-window size, not the `<total_tokens>` session budget.
```

**4. Start a new session in the repo.**

Each repo gets its own `context-meter.conf`, so thresholds and messages can differ per project.

## Testing it

To check it without filling a real context window, point it at a fake transcript:

```sh
echo '{"message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":190000}}}' > /tmp/fake.jsonl
echo '{"transcript_path":"/tmp/fake.jsonl"}' | ~/.claude/hooks/context-meter.sh
```

You should get a JSON object containing the main-session handoff message. For a live test, temporarily lower `WARN`/`HANDOFF` to something like `20000`/`25000` and give an agent a multi-step task.

## How it works

- Every assistant turn in the session transcript (`~/.claude/projects/<project>/<session>.jsonl`) records API usage. The context size is `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of the latest turn.
- Hooks that fire inside a subagent receive `agent_id` and `agent_type`, but `transcript_path` still points at the parent session. The script reads the subagent's own transcript at `<session>/subagents/agent-<agent_id>.jsonl` instead.
- The message is returned as `hookSpecificOutput.additionalContext`, which Claude Code adds to the agent's context after the tool result.

## Limitations

- **It only fires after tool calls.** An agent that talks without using tools won't be measured, but autonomous work is almost all tool calls.
- **It lags by one turn.** It reads the most recent assistant turn, so a very large tool result isn't counted until the next call.
- **Above `WARN` it repeats on every tool call.** Each message costs a few hundred tokens. That's deliberate: repetition makes the signal hard to miss.
- **It relies on undocumented internals.** The transcript format and subagent transcript layout aren't a public API. If Claude Code changes them, the hook fails safe (goes silent) rather than erroring. Re-test after major Claude Code updates.
- **Agents may still exercise judgment.** An agent that is one step from done may finish instead of handing off. The `CLAUDE.md` line makes compliance much more reliable, but it's an instruction, not a hard stop.
