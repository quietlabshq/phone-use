# Wall, agent activity, and phone control design

## Why

The companion app shows one phone at a time and has no idea which agent is doing what. With several agents driving several phones, you need to see every phone at once, know who is driving each one, step in when something needs a person, and hand control back. The visual direction comes from the Claude Design mock "Phone Use - Mac app" (three screens: Wall, Device, Setup).

## Decisions

- Pause, take over, and help requests **fail fast**: agent calls that would change the phone return a clear tool error immediately instead of waiting, so MCP client timeouts never hide what happened. Screenshots keep working so agents can watch.
- An agent asks for a person with `request_help`. The call returns immediately and marks the phone **Needs you**.
- An agent can withdraw **its own** help request with `cancel_help`. Once a person has taken over, only the person's **Hand back** returns control. Agents can never override Pause.
- Agents label their work with `set_task`. The label is shown under the phone and cleared when the agent disconnects.

## Control model

Each phone has one control state, owned by `ToolDispatcher`:

| State | Set by | Agent mutations | Ends with |
|---|---|---|---|
| `agents` (default) | - | allowed | - |
| `paused` | Pause, Pause all | fail: paused by the user | Resume, Take over |
| `helpRequested(reason, agent)` | `request_help` | fail: waiting for the user | `cancel_help` (same agent), Take over, agent disconnect |
| `person` | Take over, or manual input while an agent is active or help is requested | fail: a person is controlling | Hand back |

Mutations are every tool except `list_phones`, `screenshot`, `set_task`, `request_help`, and `cancel_help`. The state is checked after the call wins the per-phone queue, so a call queued behind a take over also fails. A call already running when you take over finishes; it is not interrupted mid-gesture.

Manual input from the app always runs. It implicitly takes over when an agent has acted on the phone in the last 60 seconds or help is requested, so a person and an agent never interleave gestures silently. Input on a paused or idle phone leaves the state alone.

## Agent identity and activity

- `MCPServer.serve` gives every MCP session an `AgentIdentity` (session UUID plus the client name from `initialize`, such as `claude-code`). Remote HTTP sessions get an identity derived from their session ID.
- `ToolDispatcher.events` is an `AsyncStream<DispatcherEvent>` (buffering newest 512) for one local consumer, the app:
  - `call(ToolCallRecord)` when a phone-bound call starts and again when it finishes (same ID). The record has the source (agent or person), tool, display arguments, the native touch point for taps, long presses, and swipes, and the outcome (running, succeeded with a short detail such as `618x1344 · 212 KB` or `16 keys`, failed with the error).
  - `control(phoneID, PhoneControl)` on every state change.
  - `task(phoneID, TaskLabel?)` when a task is set or cleared.
  - `agentConnected(AgentIdentity)` and `agentDisconnected(id)`.
- On disconnect the dispatcher clears that agent's tasks and help requests.

## New MCP tools

- `request_help(reason, phone_id?)`: marks the phone Needs you. Errors if the phone is paused, controlled by a person, or another agent already asked.
- `cancel_help(phone_id?)`: withdraws this agent's request. Succeeds as a no-op when nothing is pending; errors once a person has taken over.
- `set_task(title, phone_id?)`: sets the label; an empty title clears it.

The phone-use skill tells agents to set a task, to ask for help instead of stopping at passcodes and Face ID, and how to react to each error.

## App

The window follows the mock: a dark custom shell with a sidebar (Wall, Setup with a to-do badge, the device list, Add a device, and an MCP server status card with the agent count), hidden title bar, and Geist and Geist Mono bundled from the OFL-1.1 release.

- **Wall:** every phone live in a grid with 3, 4, 6, or 8 columns, status filters (All, Agent driving, Needs you, Paused, Idle, Offline, shown when non-empty), and Pause all or Resume all. Each card shows a status dot, transport (`USB·BT` or `SIM`), the live screen with the latest agent touch and an action caption, the agent or status, elapsed time, and the task or reason. Needs you cards have a Take over button. Configured iPhones whose USB screen is missing are Offline cards. Clicking a card opens the Device screen.
- **Device:** back button, name, and connection chips; Pause or Resume, Take over or Hand back; a status banner; the interactive live screen in a bezel with the agent touch overlay; a toolbar with Home, Open app, Save screenshot, and a touch overlay toggle; resolution, frame rate, and input status; an Activity list of recent calls; and a Connection panel (screen, input, MCP client).
- **Setup:** a progress bar over the countable checks (Camera, Bluetooth, AXe, command-line tool, and per configured iPhone its USB screen and Bluetooth input), sections This Mac, iPhones (configured phones with Remove, unconfigured USB screens with Add, and the Add an iPhone steps), Simulators (AXe and a custom path), and Agents (Claude Code and JSON snippets with Copy, command-line tool, Open at login, socket path). AssistiveTouch cannot be detected, so it appears as an instruction, not a check.
- **Menu bar:** the icon shows a badge when a phone needs you.

Live sessions are reference-counted so the Wall and Device screens share one stream per phone and navigation does not restart streams. Bluetooth input status moves from per-session polling to one app-level poll used by every screen.

## Error handling

- Agent errors name the state and the next step, for example `The user has taken over this phone. Do not act until they hand it back; take screenshots to watch.`
- If an agent disconnects while it has a help request, the phone returns to `agents`.
- The event stream drops the oldest events if the app falls behind; the app treats records as idempotent upserts by ID.

## Testing

- Dispatcher: each control state blocks mutations with the documented error and still allows screenshots; queued calls see a take over; `cancel_help` ownership; disconnect cleanup; Pause cannot be overridden by tools; events for start, finish, failure, task, and control changes.
- MCP server: tool list includes the new tools; the client name from `initialize` reaches the dispatcher.
- Manual: build the signed app, drive a simulator from an MCP client, and check the Wall, Device, Setup, take over, hand back, pause, help, and task flows against the mock.
