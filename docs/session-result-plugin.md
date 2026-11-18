# Session result plugin

Open PeachyPet Settings → General → Session result plugin and enable **Process completed Agent replies**. Select a local tool and optionally add processing instructions. The default is Codex CLI, a new tool conversation for each reply, and a scrollable Markdown panel in PeachyPet.

| Setting | What it controls |
| --- | --- |
| Local tool | Codex CLI uses the installed executable and its model configuration. Custom executable accepts an absolute path to a program that implements the input/output contract below. |
| Processing instructions | The tool receives these instructions and the full reply. Its prompt asks for Simplified Chinese when the resulting prose is entirely in English or Korean and asks to preserve Markdown, code, links, and identifiers. |
| Tool conversation | **Start a new conversation** processes each reply independently. **Reuse for the same source session** keeps processing context separate for each source agent and session. |
| Send result to | **PeachyPet Markdown panel** displays the tool output. **Original Agent session** passes that output back through the pending Stop Hook to continue the source session once. This option waits for the tool before letting the source session finish. |

The plugin uses live completion Hooks from Claude Code, Codex, and Copilot CLI. Claude Code and Codex supply the final reply in the event. Copilot CLI supplies the path to its local session transcript, which PeachyPet reads to find the final reply for the current turn. Codex sessions discovered solely from periodic log polling need the live Hook to use this plugin. The model provider configured in the selected tool receives the reply when the plugin runs.

## Custom executable contract

- Read the prompt and full source Markdown as UTF-8 from standard input.
- Write the final UTF-8 Markdown to standard output and exit successfully.
- In reuse mode, PeachyPet sets `PEACHYPET_SESSION_ID` to a stable identifier for that source session. Use the identifier to load and save the tool's context. In new-conversation mode, the variable is unset.

The tool runs in PeachyPet's application support directory. The panel lets you scroll and copy the Markdown. It displays a placeholder for embedded images so opening a report does not automatically fetch image URLs.
