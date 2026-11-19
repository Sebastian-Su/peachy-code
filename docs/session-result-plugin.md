# Session result plugin

Open PeachyPet Settings → General → Tools Integration and choose **Add Hook** or **Edit Hook** next to Claude Code, Codex, or Copilot CLI. Each agent has its own configuration. Click **Save** to apply the whole draft. Closing the editor or clicking **Cancel** discards it. An existing global configuration is copied to each agent during the upgrade.

A new hook defaults to Codex CLI, a new tool conversation for each reply, and a bubble anchored to the PeachyPet mascot.

| Setting | What it controls |
| --- | --- |
| Final reply contains | Matches a literal keyword or phrase in the original reply, ignoring case. An empty field processes every final reply. |
| Skip Chinese replies | Removes code blocks, inline code, links and paths, then skips the reply when Han characters make up at least 30% of the remaining letters. The tool is not launched and no card or history entry appears. |
| Local tool | Codex CLI uses the installed executable and its model configuration. Custom executable accepts an absolute path to a program that implements the input/output contract below. |
| Processing instructions | The tool receives these instructions and the full reply. When the instructions decide there is nothing to show, the tool can output only `PEACHYPET_SKIP`; PeachyPet then shows no card, saves no history and does not continue the source session. Its prompt asks for Simplified Chinese when the resulting prose is entirely in English or Korean and asks to preserve Markdown, code, links, and identifiers. |
| Tool conversation | **Start a new conversation** processes each reply independently. **Reuse for the same source session** keeps processing context separate for each source agent and session. |
| Send result to | **PeachyPet floating bubble** shows a short preview for 30 seconds. Hover pauses the countdown, and **Read report** opens the full Markdown in Result History. **Original Agent session** passes that output back through the pending Stop Hook to continue the source session once. This option waits for the tool before letting the source session finish. |

The plugin uses live completion Hooks from Claude Code, Codex, and Copilot CLI. Claude Code and Codex supply the final reply in the event. Copilot CLI supplies the path to its local session transcript, which PeachyPet reads to find the final reply for the current turn. Codex sessions discovered solely from periodic log polling need the live Hook to use this plugin. The model provider configured in the selected tool receives the reply when the plugin runs.

Hold Cmd while the result bubble is active to reveal shortcuts. Cmd+1 opens the current report, Cmd+2 opens Result History, and Esc dismisses the bubble. The configured focus shortcut (Cmd+M by default) points to the original session when PeachyPet has a way to locate it. Holding Cmd also pauses the countdown.

## Result History

Open **Result History** in the sidebar, select **History** in a result bubble, or press Cmd twice and then Cmd+R. Set the second shortcut in Settings → Shortcuts. The first two Cmd taps still open the session switcher.

Each saved result identifies the original agent, project, session, and time. All results are stored in the local SQLite database, including results returned to their original sessions. Settings → General → Result History controls how many records to retain. The default is 100. Saving a smaller limit removes the oldest records.

## Custom executable contract

- Read the prompt and full source Markdown as UTF-8 from standard input.
- Write the final UTF-8 Markdown to standard output and exit successfully.
- In reuse mode, PeachyPet sets `PEACHYPET_SESSION_ID` to a stable identifier for that source session. Use the identifier to load and save the tool's context. In new-conversation mode, the variable is unset.

The tool runs in PeachyPet's application support directory. The report view supports scrolling and copying the full Markdown. It shows placeholders for embedded images to avoid automatically fetching image URLs.

## Paseo remote sessions

Settings → General → Tools Integration → **Paseo remote sessions** (off by default) shows turns that end on hosts connected to the local Paseo daemon. PeachyPet starts a bundled Node.js script (`tools/paseo-bridge`, built by `scripts/build-app.sh` from Paseo's official SDK) that connects to `ws://127.0.0.1:6767/ws`. Paseo itself is not modified.

When a remote agent goes from running to idle, PeachyPet records a Stop for that session. The session reads "host • Paseo title", shows the Paseo icon, and jumping to it opens that agent on its own host in Paseo (`paseo://h/<serverId>/agent/<agentId>`). Its final reply then goes through the result hook configured for the same agent (Codex or Claude Code). Remote results always go to the PeachyPet bubble, because there is no local Stop Hook to continue. Local agents are not reported by the bridge, since their own hooks already reach PeachyPet. Agents delegated by another agent (`paseo.parent-agent-id`) are not reported either.
