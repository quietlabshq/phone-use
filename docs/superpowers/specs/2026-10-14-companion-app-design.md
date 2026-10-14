# Phone Use companion app design

## Why

macOS grants Camera (and Bluetooth) to the app responsible for a process, not to the binary. When an agent host such as T3 Code or Codex launches `phone-use mcp`, the request is attributed to that host and silently denied, so physical screenshots only worked from Terminal. Testing on 2026-10-14 also showed that there is no way to see or poke at a phone while an agent drives it.

## Goals

- `Phone Use.app` is the only macOS process that touches the camera, Bluetooth, and simulators. Permissions are granted to it once and apply no matter which agent launched the MCP.
- Existing agent configurations (`phone-use mcp`) keep working unchanged.
- A live view of every simulator and physical iPhone, with click to tap, drag to swipe, hold to long press, keyboard typing, Home, and open app.
- A setup screen showing Camera and Bluetooth authorization, the Bluetooth HID link, AXe, USB capture devices (with one-click configuration), the command-line tool, and launch at login.
- Signed with the Developer ID certificate so grants survive rebuilds; notarization is optional in the build script.

## Non-goals (v1)

- ESP32 transport and flashing. A later sub-project adds an ESP32 `HIDTransport` next to the Mac Bluetooth HID host, which stays supported.
- Running the HTTP `serve` daemon or relay inside the app. They stay in-process CLI commands and fail with the existing ownership conflict while the app runs.
- DMG packaging, auto-updates, and a guided onboarding wizard.

## Architecture

```
agent --stdio--> phone-use mcp (byte relay) --unix socket--> Phone Use.app
CLI subcommands --MCP client--------------------------^          |
                                              ToolDispatcher (one per app)
                                               |                 |
                                         SimulatorPhone     HardwarePhone
                                                        (USB capture + HID)
```

- **Socket:** `~/.config/phone-use/run/app.sock`. The directory is private (0700) and owned by the user; the app rejects peers with another UID (`getpeereid`). Each connection carries newline-delimited MCP JSON-RPC and gets its own MCP `Server` session backed by the shared dispatcher.
- **`phone-use mcp`** relays bytes between stdin/stdout and the socket, so the agent's MCP session lives in the app. Other subcommands use the SDK `Client` over the same socket. If the socket is missing the CLI launches the app in the background and waits up to 10 seconds.
- **Ownership:** the app holds `ProcessOwnership` for its lifetime. Agent sessions, CLI commands, and the live view all go through the one dispatcher, which already serializes actions per phone.
- **Live frames:** a `LiveFrameSource` protocol in `PhoneUseCapture`. Hardware phones stream from the existing `AVCaptureSession`; simulators stream from `axe stream-video`.
- **Manual input:** the live view sends native-pixel `PhoneAction`s through `ToolDispatcher.perform`, sharing per-phone serialization with agents.
- **Hardware configuration:** `HardwareRegistry` reloads `config.json` on each discovery so devices added from the setup screen appear without restarting.
- **Packaging:** `scripts/build-app.sh` assembles the bundle from SwiftPM output (app executable, the `phone-use` CLI, and the patched AXe when built), writes Info.plist, and signs with the hardened runtime and the camera entitlement.

## Error handling

- App fails to acquire ownership: show the conflict in the window and menu bar; no socket is served.
- CLI cannot reach the app: actionable error naming the app path and how to start it.
- Camera or Bluetooth denied: setup screen shows the state with a button to the matching System Settings pane.
- Live stream failure: the phone view shows the error and a Retry button.

## Testing

- Socket transport and host listener: round-trip MCP sessions over a temporary socket with a fake registry, peer cleanup, and concurrent sessions.
- Dispatcher `perform`: serialization with tool calls and phone selection.
- `axe stream-video` frame parsing with recorded fixtures.
- Live view coordinate mapping (aspect-fit, letterboxing) as a pure function.
- Manual verification of the bundle: permissions prompt attributed to Phone Use, agent MCP from T3 Code captures a physical screenshot, live view input on the simulator.
