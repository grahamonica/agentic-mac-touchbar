# AgentBar

AgentBar is a native macOS companion for the physical MacBook Pro Touch Bar. It puts Codex and Claude in one compact control surface without OpenAI or Anthropic API keys.

The expanded Touch Bar contains:

- Codex/Claude app switching
- live working, completion, and error states
- one-tap Allow/Deny controls for agent permission requests
- built-in subscription usage for both providers
- a labeled **Mic** control with a reviewable transcript and Send button

One `AI` button stays in the Control Strip. Tap it to open the full-width controls for Codex, Claude, notifications, usage, Mic, and Send. A menu-bar item provides the same actions when you are using an external keyboard or display.

While AgentBar runs, it selects macOS's **App Controls with Control Strip** presentation so the compact system controls and the persistent **AI** launcher can coexist. It restores the prior Touch Bar presentation when it quits.

Opening AgentBar uses the full-width app region, so the expanded volume and brightness Control Strip does not cover the provider, status, usage, permission, microphone, or Send controls. **Exit** is the first AgentBar control, and macOS also supplies its native close button. Either returns to the normal Touch Bar and the persistent **AI** launcher.

Selecting Codex or Claude activates that desktop app and then re-presents AgentBar, keeping the labeled **Mic** and **Send** controls visible after the app switch.

## Subscription connections

Codex connects through the official local `codex app-server` protocol. It inherits the existing `Logged in using ChatGPT` session, exposes approvals and streamed completion events, and reads plan rate limits directly from the account session.

Completion state is status-aware: successful turns play the completion cue, while failed or interrupted turns surface an error instead. Resolved or timed-out permission requests automatically clear their Touch Bar buttons. Managed network prompts show their destination rather than an unrelated command preview.

AgentBar retains the persistent thread identifier for a Touch Bar-created Codex chat. Switching back to Codex or tapping its status uses Codex Desktop's `codex://threads/<thread-id>` handler to open that exact chat.

AgentBar also watches only the event-type field in recent local Codex rollout files. This lets a task started directly in Codex Desktop surface working, completion, and interruption notifications on the Touch Bar. It deliberately ignores prompt, response, reasoning, and tool content. Cross-client approval responses are not available in Codex's protocol, so Allow/Deny is actionable for AgentBar-started chats; a permission owned by an existing Codex window remains answered in that window.

Claude uses the Claude Code executable that ships inside Claude Desktop. Select Claude and tap its **Connect Claude** Touch Bar status, or click **Connect Claude Subscription…** in the menu, once to refresh Claude Code's OAuth session. AgentBar brings Terminal forward and explicitly runs the Claude.ai subscription login—not Console/API billing—then the browser handles authentication. Claude usage is read from the live subscription control payload with Claude Desktop's local plan-usage history as a fallback.

After opening the browser login, AgentBar checks the local Claude subscription session for up to ten minutes and switches to Ready automatically when OAuth finishes. It also detects a login completed outside AgentBar during its normal refresh cycle.

AgentBar captures the persisted Claude Code session identifier for a Touch Bar-created chat. Switching back to Claude or tapping its status then uses Claude Desktop's `claude://resume?session=…` handler to import and open that exact conversation.

When Claude is connected, AgentBar requests the live subscription `get_usage` control payload (5-hour and 7-day windows). The local desktop history is only a fallback and is visibly marked as needing a refresh when it is more than six hours old.

No API key is read, stored, or requested by AgentBar.

## Build and install

Requirements:

- a Touch Bar MacBook Pro
- macOS 13 or newer
- ChatGPT/Codex and Claude Desktop installed
- the macOS Command Line Tools

```sh
./scripts/smoke_test.sh
./scripts/install_app.sh
```

The installed app lives at `/Applications/AgentBar.app`. On first microphone use, macOS asks for Microphone and Speech Recognition access.

**Connection Diagnostics…** shows the current runtime status. The same non-sensitive health record is written to `~/Library/Application Support/AgentBar/status.json`; dictated text and chat content are never included.

Use the menu-bar sparkle to choose the working folder used by new coding chats. The build injects this repository as the initial default.

## Touch Bar implementation note

Apple never offered a public API for a third-party item that remains permanently in the Control Strip. AgentBar uses the same private AppKit/DFRFoundation mechanism used by personal Touch Bar tools such as Pock and MTMR. This is appropriate for a personal, locally built app, but it is not Mac App Store compatible and may need adjustment after a future macOS update.

The bridge is isolated in `Sources/TouchBarPrivateBridge`; all agent, speech, and UI code uses public frameworks and documented local protocols.

## Privacy and permissions

- audio is transcribed through Apple's Speech framework; AgentBar does not upload audio itself
- agent prompts go only to the selected installed agent through its subscription session
- approvals default to one action/turn and are never silently accepted
- Claude actions that require a rich interaction card open Claude instead of reducing the decision to an unsafe binary choice
- launch at login is opt-in from the menu
