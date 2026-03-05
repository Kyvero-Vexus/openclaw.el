# OpenClaw TUI Feature Parity Specification for openclaw.el

## Overview

This document specifies the behavior of the OpenClaw TUI that `openclaw.el` must replicate
to achieve feature parity. Each section has a spec ID for test traceability.

## SPEC-01: Connection/Auth/Handshake Lifecycle

### SPEC-01.1: WebSocket Connection
- Connect to gateway via WebSocket at configurable URL (default `ws://127.0.0.1:18789`)
- Support `--url`, `--token`, `--password` equivalents via Emacs customization variables

### SPEC-01.2: Handshake Protocol
1. Client opens WebSocket connection
2. Gateway sends `connect.challenge` event with `nonce` and `ts`
3. Client sends `connect` request with:
   - `minProtocol: 3, maxProtocol: 3`
   - `client.id`, `client.displayName`, `client.version`, `client.platform`, `client.mode`
   - `role: "operator"`, `scopes: ["operator.admin"]`
   - `auth.token` (when token auth configured)
   - `auth.password` (when password auth configured)
4. Gateway responds with `hello-ok` payload containing `protocol` and `policy`
5. Connection is now ready for RPC calls

### SPEC-01.3: Connection States
- `disconnected` → `connecting` → `awaiting-challenge` → `handshaking` → `connected`
- Display connection state in mode-line or status area
- On close: transition to `disconnected`, show message

### SPEC-01.4: Auto-read Token from Config
- Read gateway token from `~/.openclaw/openclaw.json` at `gateway.auth.token` if not explicitly set

## SPEC-02: Session List/Switch/Create Semantics

### SPEC-02.1: Session List
- RPC method: `sessions.list` with `(limit . 50)`
- Display sessions with: key, label/displayName, agentId, model, token counts
- Sessions clickable/selectable to switch

### SPEC-02.2: Session Switch
- RPC method: `chat.history` with `(sessionKey . KEY) (limit . 100)`
- Create or reuse buffer named `*openclaw:LABEL*`
- Load and render message history
- Set buffer-local session key and label

### SPEC-02.3: New Session / Reset
- `/new` or `/reset` command resets the current session
- Sent as `chat.send` with message `/new`

### SPEC-02.4: Default Session
- Default session key: `main` (or configurable)
- Auto-connect to default session on first connect

## SPEC-03: Message Rendering

### SPEC-03.1: Message Roles
- `user` messages: prefixed with role indicator, distinct face/color
- `assistant` messages: prefixed with role indicator, distinct face/color
- `system` messages: prefixed with role indicator, distinct face/color
- `tool` messages: rendered as tool output cards

### SPEC-03.2: Content Types
- Plain text: rendered directly
- Multi-part content (vector of parts): concatenated with type-appropriate rendering
- Each part may have `type` ("text") and `text` fields

### SPEC-03.3: Timestamps
- Messages include timestamps from gateway
- Display in `[HH:MM]` or `[YYYY-MM-DD HH:MM]` format

### SPEC-03.4: Streaming Updates
- Gateway sends incremental chat events during assistant response
- Buffer updates in-place for streaming content
- Final message replaces streaming content

### SPEC-03.5: Message Faces
- Define faces for: user messages, assistant messages, system messages, timestamps, session headers

## SPEC-04: Slash Commands and Key Bindings

### SPEC-04.1: Slash Commands (sent to gateway)
- `/help` - Show help
- `/status` - Show session status
- `/agent <id>` - Switch agent
- `/agents` - List agents
- `/session <key>` - Switch session
- `/sessions` - List sessions
- `/model <provider/model>` - Set model
- `/models` - List models
- `/new` / `/reset` - Reset session
- `/abort` - Abort active run
- `/deliver <on|off>` - Toggle delivery
- `/think <level>` - Set thinking level
- `/verbose <on|full|off>` - Set verbose mode
- `/reasoning <on|off|stream>` - Set reasoning mode
- `/context` - Show context info
- `/exit` - Exit/disconnect

### SPEC-04.2: Key Bindings (Chat Mode)
- `RET` or `C-c C-c` - Send message (from input area)
- `C-c C-l` - List sessions
- `C-c C-s` - Switch session
- `C-c C-n` - New chat
- `C-c C-h` - Show/refresh history
- `C-c C-q` - Close connection
- `C-c C-a` - Abort current run

### SPEC-04.3: TUI Keyboard Shortcuts (Emacs equivalents)
- `C-c C-m` - Model picker (TUI: Ctrl+L)
- `C-c C-g` - Agent picker (TUI: Ctrl+G)  
- `C-c C-p` - Session picker (TUI: Ctrl+P)
- `C-c C-t` - Toggle thinking visibility (TUI: Ctrl+T)
- `C-c C-o` - Toggle tool output expansion (TUI: Ctrl+O)

## SPEC-05: Error Handling

### SPEC-05.1: Connection Errors
- Display clear error message on connection failure
- Don't crash on WebSocket errors

### SPEC-05.2: RPC Errors
- Handle `ok: false` responses
- Display error message from `payload.error` or top-level `error`
- Don't leave dangling callbacks

### SPEC-05.3: Reconnection
- Show disconnection message
- Allow manual reconnect via `openclaw-connect`

## SPEC-06: Buffer Model

### SPEC-06.1: Buffer per Session
- Each session gets its own buffer: `*openclaw:SESSION-LABEL*`
- Buffer uses `openclaw-chat-mode`
- Buffer is read-only except for input area

### SPEC-06.2: Session List Buffer
- `*openclaw-sessions*` buffer with clickable session entries
- Read-only, refreshable

### SPEC-06.3: Help Buffer
- `*openclaw-help*` buffer with keybinding reference

### SPEC-06.4: Input Model
- Messages entered via minibuffer (`read-string`) or dedicated input area
- Slash commands detected by leading `/` and routed to `chat.send`

## SPEC-07: Mode Line

### SPEC-07.1: Mode Line Display
- Show connection state (connected/disconnected)
- Show current agent ID
- Show current session key/label
- Show current model (when known)

## SPEC-08: Agent Management

### SPEC-08.1: Agent List
- RPC method: `agents.list`
- Display available agents with completing-read

### SPEC-08.2: Agent Switch
- Switch agent context, update sessions list
- Reflect in mode line

## SPEC-09: Event Handling

### SPEC-09.1: Chat Events
- `chat.message` - New message from assistant/system
- `chat` event with sessionKey - triggers history refresh

### SPEC-09.2: Session Events
- `sessions.update` - Session list changed, refresh

### SPEC-09.3: System Events
- Connection state changes
- Error notifications
