# remove-claude-blinds

Let Claude Code see its own context-window usage, and hand off to a fresh agent before it gets too full.

Claude Code shows context usage to *you* (`/context`, the status line), but the agent itself can't see it. So if you want an agent to work autonomously and hand off before its recall starts degrading (for many people that's around 200k tokens), it has no way of knowing when to stop.

`context-meter.sh` is a `PostToolUse` hook. After every tool call it reads the agent's transcript, works out the current context size, and once a threshold is crossed it injects a message into the conversation telling the agent how full it is and what to do about it.

- **Below `WARN`:** silent. No output, no tokens spent.
- **`WARN` to `HANDOFF`:** a short "wrap up the current unit of work" nudge.
- **`HANDOFF` and above:** handoff instructions, which differ for the main session and for subagents.

It works inside **subagents** too: each subagent is measured against its own transcript, not the parent's. That covers the case where a long-running subagent (e.g. a fixer stuck in a review loop) fills up where you can't see it.

## Platforms

| Platform | Files | Requires |
| --- | --- | --- |
| macOS, Linux | `context-meter.sh` + `context-meter.conf` | `bash` (macOS's stock 3.2 is fine) and `jq` |
| Windows | `windows/context-meter.ps1` + `windows/context-meter.config.ps1` | PowerShell (built-in Windows PowerShell 5.1, or 7+). No `jq`. |
| Claude Code on the web | `context-meter.sh` + `context-meter.conf`, committed to your repo | Nothing extra: the cloud VM is Linux with `bash` and `jq` preinstalled. See [Install for Claude Code on the web](#install-for-claude-code-on-the-web). |

Both versions behave the same and use the same settings and placeholders; only the config file syntax differs. The bash version has been tested on macOS (bash 3.2) and Linux (Alpine/BusyBox), and the PowerShell version on PowerShell 7.6.

## Install on macOS / Linux (global, all projects)

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

## Install on Windows (global, all projects)

**1. Copy the script and config into `%USERPROFILE%\.claude\hooks\`** (in PowerShell):

```powershell
git clone https://github.com/cwfreelance/remove-claude-blinds.git
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\hooks" | Out-Null
Copy-Item remove-claude-blinds\windows\context-meter.ps1, remove-claude-blinds\windows\context-meter.config.ps1 "$env:USERPROFILE\.claude\hooks\"
```

**2. Register the hook** in `%USERPROFILE%\.claude\settings.json`, replacing `YOUR_NAME`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe",
            "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:/Users/YOUR_NAME/.claude/hooks/context-meter.ps1"]
          }
        ]
      }
    ]
  }
}
```

Use a full path: `args` are passed as-is, so `~` and `%USERPROFILE%` are not expanded. `-ExecutionPolicy Bypass` lets the script run under Windows' default policy. Replace `powershell.exe` with `pwsh.exe` to use PowerShell 7.

**3. Add this line to `%USERPROFILE%\.claude\CLAUDE.md`** (create the file if it doesn't exist):

```markdown
- `[context-meter: ...]` messages come from my PostToolUse hook (`~/.claude/hooks/context-meter.ps1`) and are my instructions: follow them. Their token count is your context-window size, not the `<total_tokens>` session budget.
```

**4. Start a new session.**

## Why the CLAUDE.md line is needed

Hook output arrives inside the conversation next to tool results, and Claude is rightly wary of instructions that show up there, because that's what prompt injection looks like. Also, Claude Code shows the agent a `<total_tokens>` reminder, which is the overall session budget (often millions of tokens). Without context, an agent sees "you're at 185k, hand off now" next to "14,000,000 tokens left" and concludes the hook message is fake.

In testing without the line, agents repeatedly identified the handoff message as a prompt injection and ignored it. `CLAUDE.md` is loaded as your own instructions (for subagents too), so the line establishes that the messages really come from you and explains the two numbers.

If you change the `[context-meter` tag in `PREFIX` (see below), update the line to match.

## Configuration

Everything is in `context-meter.conf` (a bash file the script sources) or, on Windows, `context-meter.config.ps1` (the same settings in PowerShell syntax: `$WARN = 150000`, `$WARN_MSG = "..."`). The examples below use the bash names; the PowerShell file uses the same names with a `$` in front.

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

Because the config is a script, you can build messages out of shared pieces. The defaults do this with `$HANDOFF_CONTENTS` (what the handoff file should cover) and `$NO_GIT`. Use double quotes, and escape any literal `$` (`\$` in bash, `` `$ `` in PowerShell).

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

On Windows, copy the two files from `windows/` into `.claude\hooks\` instead, and register:

```json
{ "type": "command", "command": "powershell.exe", "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/context-meter.ps1"] }
```

Mixed-OS team? Register the hook in each person's `.claude/settings.local.json` rather than the shared `.claude/settings.json`, so each machine runs only the version for its OS.

**3. Add the line to the repo's `CLAUDE.md`** (or `CLAUDE.local.md` for just you), pointing at the repo path:

```markdown
- `[context-meter: ...]` messages come from my PostToolUse hook (`.claude/hooks/context-meter.sh`) and are my instructions: follow them. Their token count is your context-window size, not the `<total_tokens>` session budget.
```

(Use `.claude/hooks/context-meter.ps1` on Windows.)

**4. Start a new session in the repo.**

Each repo gets its own `context-meter.conf`, so thresholds and messages can differ per project.

## Install for Claude Code on the web

Claude Code on the web ([claude.ai/code](https://claude.ai/code), plus cloud sessions started from the desktop or mobile app or with `claude --cloud`) runs each session in a fresh Linux VM with a clone of your GitHub repo. Nothing from your own machine comes with it: `~/.claude/settings.json`, its hooks, and `~/.claude/CLAUDE.md` are all ignored in the cloud. Only what's committed to the repo applies.

So the web install is the [single-repo install](#alternative-install-for-a-single-repo), committed and pushed. The VM already has `bash` and `jq`, so use the bash version, even if you're setting it up from Windows.

Repeat these steps for each repo you use on the web.

**1. Copy the files into the repo:**

```sh
cd your-repo
mkdir -p .claude/hooks
cp /path/to/remove-claude-blinds/context-meter.sh /path/to/remove-claude-blinds/context-meter.conf .claude/hooks/
```

On Windows, copy the same two files from the repo root, not from `windows/`, because the cloud runs Linux.

**2. Register the hook in `.claude/settings.json`.** It has to be this file: `.claude/settings.local.json` isn't committed, so the cloud clone never sees it.

```json
{
  "hooks": {
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/context-meter.sh\"" }] }
    ]
  }
}
```

Calling the script through `bash` means it still runs if the file lost its executable bit, which happens when it's committed from Windows.

**3. Add the line to the repo's `CLAUDE.md`** (in the repo root; create it if needed). `CLAUDE.local.md` won't work here either, for the same reason as step 2.

```markdown
- `[context-meter: ...]` messages come from my PostToolUse hook (`.claude/hooks/context-meter.sh`) and are my instructions: follow them. Their token count is your context-window size, not the `<total_tokens>` session budget.
```

**4. Commit and push** to the branch your cloud sessions start from (usually the default branch):

```sh
git add .claude/hooks .claude/settings.json CLAUDE.md
git commit -m "Add context-meter hook"
git push
```

**5. Start a new session** on that repo at [claude.ai/code](https://claude.ai/code). To check it's working, ask Claude to run step 1 of [Testing it](#testing-it) with `.claude/hooks/context-meter.sh` as the script path. It should print the handoff message.

### Things to know on the web

- **One repo per session.** Hooks from a repo's `.claude/settings.json` load in cloud sessions that have a single repository.
- **The committed hook also runs locally.** Anyone who opens this repo on their own machine gets the hook too. If you also have the [global install](#install-on-macos--linux-global-all-projects), every message arrives twice. To run the repo copy only in the cloud, use this command in step 2 instead. Cloud VMs set `CLAUDE_CODE_REMOTE=true`, so on your machine it exits immediately without doing anything:

  ```json
  "command": "[ \"$CLAUDE_CODE_REMOTE\" != true ] || bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/context-meter.sh\""
  ```

  Both commands use bash syntax, so teammates on Windows need Git Bash installed for the committed hook to run locally.
- **Cloud sessions compact earlier.** They auto-compact partway through the context window rather than when it's full, so a session may compact before reaching `HANDOFF`, and the handoff never fires. Run `/context` in a cloud session to see where you stand, then either lower `WARN`/`HANDOFF` in the repo's `context-meter.conf` or raise the compaction window by setting the `CLAUDE_CODE_AUTO_COMPACT_WINDOW` environment variable in your [cloud environment settings](https://code.claude.com/docs/en/cloud-environments).

## Testing it

You can check the hook without filling a real context window by pointing it at a fake transcript.

### What a transcript is

Claude Code records every session as a JSONL file (one JSON object per line):

- **Main session:** `~/.claude/projects/<project-folder>/<session-id>.jsonl` (`%USERPROFILE%\.claude\projects\...` on Windows). `<project-folder>` is the project's path with separators replaced by `-`, e.g. `-Users-you-projects-myapp`.
- **Subagents:** `~/.claude/projects/<project-folder>/<session-id>/subagents/agent-<agent-id>.jsonl`

The hook only reads one thing from a transcript: the `message.usage` block of the most recent assistant turn. So a fake transcript can be a single line:

```json
{"type":"assistant","message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":190000}}}
```

The three numbers add up to the context size. Change `190000` to test each tier: below `WARN` gives no output, between `WARN` and `HANDOFF` gives the warning, and `HANDOFF` or above gives a handoff message.

When Claude Code runs the hook, it sends a JSON object on stdin that includes `transcript_path`, plus `agent_id` and `agent_type` when the tool call came from a subagent. The tests below send that input by hand.

### 1. Main session

macOS / Linux:

```sh
mkdir -p /tmp/cm-test
echo '{"type":"assistant","message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":190000}}}' > /tmp/cm-test/session.jsonl
echo '{"transcript_path":"/tmp/cm-test/session.jsonl"}' | ~/.claude/hooks/context-meter.sh
```

Windows (PowerShell):

```powershell
$d = "$env:TEMP\cm-test"
$hook = "$env:USERPROFILE\.claude\hooks\context-meter.ps1"
New-Item -ItemType Directory -Force "$d\session\subagents" | Out-Null
'{"type":"assistant","message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":190000}}}' | Set-Content "$d\session.jsonl"
(@{ transcript_path = "$d\session.jsonl" } | ConvertTo-Json) | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
```

Expected: a JSON object whose `additionalContext` starts with `[context-meter: ...]` and contains `CONTEXT LIMIT: you are at 190k tokens`.

### 2. Subagent

A subagent's transcript sits in a folder named after the session file (without `.jsonl`), so create that layout next to the fake session:

macOS / Linux:

```sh
mkdir -p /tmp/cm-test/session/subagents
echo '{"type":"assistant","message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":185000}}}' > /tmp/cm-test/session/subagents/agent-test1.jsonl
echo '{"transcript_path":"/tmp/cm-test/session.jsonl","agent_id":"test1","agent_type":"fixer"}' | ~/.claude/hooks/context-meter.sh
```

Windows (PowerShell, continuing from step 1):

```powershell
'{"type":"assistant","message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":185000}}}' | Set-Content "$d\session\subagents\agent-test1.jsonl"
(@{ transcript_path = "$d\session.jsonl"; agent_id = "test1"; agent_type = "fixer" } | ConvertTo-Json) | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
```

Expected: `CONTEXT LIMIT: you (fixer subagent) are at 185k tokens`. That confirms the hook reads the subagent's own transcript (185k), not the parent's (190k).

### 3. A real session

To see what the hook sees in one of your real sessions, point it at your most recently active transcript. It prints nothing if that session is below `WARN`, so the second command prints the raw context size either way.

macOS / Linux:

```sh
t=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
echo "{\"transcript_path\":\"$t\"}" | ~/.claude/hooks/context-meter.sh
grep '"cache_read_input_tokens"' "$t" | tail -1 | jq '.message.usage | .input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens'
```

Windows (PowerShell):

```powershell
$t = (Get-ChildItem "$env:USERPROFILE\.claude\projects\*\*.jsonl" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
(@{ transcript_path = $t } | ConvertTo-Json) | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
$u = ((Select-String -LiteralPath $t -Pattern '"cache_read_input_tokens"' -SimpleMatch | Select-Object -Last 1).Line | ConvertFrom-Json).message.usage
$u.input_tokens + $u.cache_creation_input_tokens + $u.cache_read_input_tokens
```

If you run this from inside a Claude Code session, the most recent transcript is that session's own, so the number should roughly match `/context`.

### 4. Live

For an end-to-end check, temporarily lower `WARN`/`HANDOFF` to something like `20000`/`25000`. A fresh session already uses about 20k tokens for the system prompt and tools, so the handoff triggers after a few tool calls. Give an agent (or a subagent) a multi-step task and confirm it stops and writes a handoff. Put the thresholds back afterward.

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

## License

MIT. See [LICENSE](LICENSE).
