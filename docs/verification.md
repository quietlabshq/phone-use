# Verification and handoff

Verified on 2026-09-29 on this Mac: Swift 6.4, Xcode 27.1 beta, patched AXe `1.8.0-phone-use.1` at `.build/tools/axe/bin/axe`, and the iPhone 17 simulator running iOS 26.5 (`842C0EF9-652A-4285-8148-1324C6EA2C4D`).

## Automated checks

| Check | Result |
| --- | --- |
| `env -u PHONE_USE_SIM_UDID swift test` | 140 tests declared; 139 passed and one simulator integration test skipped. |
| `PHONE_USE_SIM_UDID=842C0EF9-652A-4285-8148-1324C6EA2C4D PHONE_USE_AXE="$PWD/.build/tools/axe/bin/axe" swift test --filter SimulatorIntegration` | Live iPhone 17 SimulatorIntegration passed in 24.323 seconds. |
| `swift build -c release` | Passed. |
| `docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2 swift test` | 75 Linux tests passed in Ubuntu 24.04.5 aarch64 with Swift 6.2.4. |
| `docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2 swift build -c release` | Passed for the portable Linux package and fake-phone executable. |
| `python3 scripts/test-linux-stdio.py -- docker run --rm -i -v "$PWD:/workspace" -w /workspace swift:6.2 sh /workspace/scripts/run-linux-fake-mcp.sh` | Real Linux stdio executable passed initialize, tool listing, fake discovery, screenshot image, action, and error checks. |
| `mise exec node@24.18.0 -- npm test --prefix relay` | 21 Worker tests passed. |
| `mise exec node@24.18.0 -- npm run typecheck --prefix relay` | Passed. |
| Stdio MCP smoke | Initialize, nine-tool catalog, nine invalid calls, Home, open Settings, JPEG screenshot, and clean EOF exit passed. |
| Claude Code MCP session | Opened Settings > General > About and visually reported iOS 26.5 using only phone-use MCP tools. |

Coverage includes screenshot scaling and rotation, bounds and argument errors, unsupported text without partial typing, per-phone action serialization, HID reports, pointer planning and simulated calibration, configuration persistence, disconnected hardware input with working fake capture, frame freshness, camera authorization errors, subprocess I/O and cancellation, and 256 rapid concurrent subprocess exits.

The Linux check is a hardware-independent portability spike, not Linux phone support. It covers the portable frame/HID/MCP layers and a development-only fake-phone stdio executable. Linux USB/AirPlay capture, BlueZ input, physical-device behavior, and the supported distribution remain open. See the [Linux portability record](linux-portability-spike.md).

The first final integration run and a Claude session exposed a subprocess termination race. A stress regression reproduced it before the fix; both the full simulator suite and Claude session passed after replacing `waitUntilExit()` with a prelaunch termination handler. Ordinary UI transitions can still require a second screenshot before deciding whether an action succeeded.

The pinned AXe extension sends double/triple taps in one native HID gesture. Live selection checks selected one word with a double tap and the whole text area with a triple tap. Repeated Backspace removed two characters. The live integration test also verifies Home recovery from a populated Spotlight search and from an app opened through Spotlight.

The vendored MCP SDK preserves literal JSON strings instead of interpreting data URLs as binary values. Wire regressions cover exact text and the original 100-character boundary; 11 focused upstream value/data tests also passed. A live stdio call typed `data:text/html,<textarea>alpha%20beta%20gamma</textarea>` into a focused Safari text area; its accessibility value matched exactly. A lingering selection menu initially left the field inactive, so the verification established focus before checking delivery.

## Direct HTTP milestone

The release daemon passed a real loopback HTTP flow against the same iPhone 17 simulator. The flow initialized two authenticated sessions, discovered the nine tools, filtered discovery to the authorized device, opened Settings, tapped using screenshot coordinates, and returned a 618 x 1344 JPEG. A conflicting session could not mutate until the owning session explicitly released its lease. Missing/invalid credentials and unapproved Host/Origin values were rejected. Credential revocation invalidated an existing session immediately. Local CLI access failed clearly while the daemon owned the phones; SIGTERM completed cleanly and subsequent CLI discovery succeeded.

The HTTP adapter also has real SDK client interoperability tests and deterministic tests for session isolation, request limits, cancellation, deadlines, revocation, and disconnect cleanup. The live simulator integration test passed again after the HTTP changes. A full-suite run exposed an intermittent ownership release failure during concurrent subprocess launches. Commit `975e6b3` explicitly unlocks in the owning process before closing the descriptor. Its deterministic regression failed before the fix; all 28 core tests then passed in 20 repeated runs. The latest macOS suite after the portable-frame migration passed 140 declared tests: 139 passed and one simulator integration test skipped. The live simulator test had passed before this migration; after it, the simulator screenshot and rotation adapter tests passed with mocked process I/O.

## Optional relay verification

The local Wrangler 4.143.0 Worker, persisted Durable Object emulator state, and release `phone-use serve --relay --simulator` daemon were exercised together against the same iPhone 17 simulator. The setup page was opened in T3's browser and showed `paired: true`, `connected: true`, revision 1, one scoped client credential, the catalog, and the public MCP URL. The browser reported no console or network errors.

Both direct and relay routes rejected an invalid bearer with HTTP 401, initialized authenticated MCP sessions, discovered the simulator, and returned JPEG screenshot content. Direct and relay screenshots had identical 152,596-byte payloads in the combined run. A direct `press_home` lease blocked a relay mutation in another session; releasing the direct lease allowed the relay mutation. Revoking the client credential propagated as Worker revision 2 with zero credentials and returned 401 on both routes. A replacement credential propagated at revision 3 and initialized on both routes.

During a Worker outage, direct MCP initialization continued to return 200 while the relay endpoint was offline. Restarting Wrangler with the same local Durable Object state restored the daemon connection; a relay screenshot then returned 152,621 bytes. The setup page's Revoke daemon button cleared paired/connected state. The replacement client credential continued to work over direct HTTP and received 401 over the relay, which stayed revoked after the reconnect interval.

The combined run caught a wire mismatch that unit tests had missed: Swift omitted `expiresAt` for non-expiring credentials, while the Worker contract requires JSON `null`. Commit `c4cdcac` encodes the explicit null and adds a regression test against the actual hello frame. Both implementation and review agents approved the fix.

No production Cloudflare account, real Worker deployment, APNs setup, Tailscale/second-machine access, or physical iPhone action was configured or tested. These remain external checks. Task 10 is still owned by the separate Mac Bluetooth transport effort, and `Runtime.transportFactory` remains `nil`; simulator results do not establish physical input support. There is no ESP32 work.

Tailscale and LAN HTTPS setup is documented in [remote access](remote-access.md). No second-machine access or external network configuration has been performed. The local optional Cloudflare relay is implemented and verified; deploying it to a user's account remains external. The [shutdown checkpoint](handoffs/2026-09-29-shutdown.md) and [next-agent prompt](handoffs/2026-09-29-next-agent-prompt.md) are historical records.

## Doctor without hardware

`PHONE_USE_AXE="$PWD/.build/tools/axe/bin/axe" .build/release/phone-use doctor` returned exit 1, as expected with no configured physical phone or installed transport:

```text
OK AXe .build/tools/axe/bin/axe: 1.8.0-phone-use.1; requires >= 1.8.0
OK AXe native multi-tap (--count)
OK Booted iPhones: iPhone 17
OK Camera usage metadata in executable
OK USB screen capture enabled; devices: none (connect, unlock, and trust iPhone)
OK Configuration: /Users/richard/.config/phone-use/config.json, 0 phones
FIX No hardware phones configured; input transport not installed by default
```

## Physical-device scope

The Mac is to act as the Bluetooth keyboard and mouse. There is no ESP32 work. Task 10 belongs to the separate Bluetooth implementation effort and remains a prerequisite for physical input. This repository supplies the tested `HIDTransport`, composite report descriptor, report encoding, hardware action pipeline, USB capture, configuration, and calibration. Connect the transport through `Runtime.transportFactory` and `HardwareRegistry(config:transportFor:)`.

Transport contract: `send(_ report: HIDReport) async throws` and `isHostConnected() async -> Bool`. Use `ReportDescriptor.bytes` unchanged with keyboard report ID 1 (8 payload bytes), mouse ID 2 (4 payload bytes), and consumer ID 3 (2 payload bytes). `HIDReport.payload` excludes the report ID; the transport must frame it as required by its Bluetooth API. Connection status must describe the intended iPhone, and send failures must propagate so the hardware action pipeline can release held input.

The default factory currently returns `nil`; do not mistake simulator completion for completed Bluetooth support. Physical capture, pairing/input, AssistiveTouch cursor visibility, shortcuts, pointer gains, and USB reconnect behavior remain unverified on hardware. Follow [the ordered test-day guide](test-day.md) once the transport is integrated and an iPhone is available.

No user MCP configuration or global skill installation was changed. Claude verification used a session-specific MCP configuration pointing at the release executable with `mcp --simulator` and `PHONE_USE_AXE="$PWD/.build/tools/axe/bin/axe"`.
