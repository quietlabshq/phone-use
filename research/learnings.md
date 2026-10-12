# Learnings so far

Everything learned while researching TapKit and preparing the phone-use plan (2026-09-29). The TapKit teardown itself is in [tapkit.md](tapkit.md). The design is in [../docs/superpowers/specs/2026-09-29-phone-use-design.md](../docs/superpowers/specs/2026-09-29-phone-use-design.md).

## TapKit, in short

- It uses three standard Apple features. The iPhone screen comes over USB as a camera device. Input goes through a Bluetooth HID mouse and keyboard, with AssistiveTouch giving the phone a pointer. Device management goes over USB lockdown. Nothing is installed on the phone and developer mode stays off.
- The 7-phone cap comes from the Classic Bluetooth limit of 7 active devices per connection.
- Typing is limited to US-ASCII, at most 100 characters, because it goes through a HID keyboard.
- Home is mouse button 3, mapped to Home in AssistiveTouch settings. A vision model sets this up during onboarding.
- They used to use Switch Control and moved away from it.
- An iOS Shortcut on the phone checks their server for actions a pointer can't do well, such as opening apps and copying text.
- Agents only get screenshots, with no accessibility tree. Screenshots are JPEGs with the long edge capped at 1344 px, and tool coordinates are in screenshot pixels.
- Their skills say to prefer `drag` over `flick` in Settings, and they ship an AssistiveTouch "warm-up" routine. Both suggest pointer gestures are flaky.
- Cloud: a Railway server, Supabase auth, and Agora streaming. Screenshots are stored on their servers.

## Decisions for phone-use

- Standalone local stdio remains offline and account-free. The authorized follow-up adds authenticated direct HTTP and an optional user-owned Cloudflare relay.
- Two backends behind one `Phone` interface: **Simulator** and **Hardware** (a real iPhone).
- Hardware eyes: USB screen capture through the public CoreMediaIO property `kCMIOHardwarePropertyAllowScreenCaptureDevices`, then AVFoundation.
- Hardware hands: does whatever TapKit is doing via Bluetooth. **Another agent builds that part** behind the `HIDTransport` interface. The ESP32 idea is dropped.
- Until then, Home and opening apps use keyboard shortcuts, and AssistiveTouch is turned on by hand in iPhone Settings.
- Pointer strategy: push the pointer into the top-left corner, then move a calibrated number of counts at a constant step size and interval. Calibration finds the cursor by diffing screen captures. If that doesn't work, gains can be set manually in the config.
- Language: Swift (Swift 6, macOS 14+) with the official MCP Swift SDK and Swift Testing.

## Verified on the iOS Simulator (iPhone 17, iOS 26.5)

- **Cmd+Space, then typing "Settings", then Enter opens Settings.** Spotlight works with HID keyboard input, so `open_app` can be built from keyboard input alone.
- **Cmd+H exits an app**, but later testing showed it can restore Spotlight hidden underneath that app. It is not sufficient by itself for reliable Home recovery.
- Screenshot size is **1206x2622 px** and the accessibility root frame is **402x874 pt**, so the scale is 3. AXe works in points. Convert with `points = pixels / scale`.
- `xcrun simctl io <udid> screenshot <path>` gives native-resolution PNGs.
- `axe describe-ui --udid <udid>` returns a JSON array. The first element is the application, with `frame {x, y, width, height}` in points and nested `children`.

## Environment gotchas on this Mac

- Xcode is `Xcode-27.1.0-Beta.app` (27.2 beta and a 27.0 RC are also installed). `xcode-select -p` points to the 27.1 beta. Swift is 6.4.
- **AXe 1.5.2 (the Homebrew-installed version) is broken with Xcode 27.** It looks for `Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework`, which moved to `Contents/SharedFrameworks/`.
- `brew upgrade cameroncooke/axe/axe` failed because it wants Command Line Tools for Xcode 27.0.
- **AXe 1.8.0 works for single taps and other actions.** Complete multi-tap support needs the pinned extension built by `scripts/build-axe.sh`, selected with `PHONE_USE_AXE="$PWD/.build/tools/axe/bin/axe"`. This avoids changing globally managed tools.
- Available simulator runtimes: iOS 18.5, 18.6, 26.5, 27.0, 27.1, 27.2. The iPhone 17 simulator (UDID `842C0EF9-652A-4285-8148-1324C6EA2C4D`) is currently booted.

## AXe command reference (1.8.0)

- `axe tap -x X -y Y --udid U` (points)
- `axe swipe --start-x --start-y --end-x --end-y [--duration s] --udid U`
- `axe touch -x X -y Y --down --up [--delay s] --udid U` for a long press
- `axe type 'text' --udid U` (US keyboard characters only)
- `axe key <hid-usage> [--duration s] --udid U`
- `axe key-combo --modifiers 227 --key 11 --udid U` (227 = Left Cmd, 11 = H)
- `axe button home|lock|side-button|siri --udid U`
- `axe batch --udid U --step "..." --step "..."` runs several steps in one HID session.
- `axe screenshot --udid U --output file.png`

## MCP Swift SDK (0.12.1)

- SDK 0.12.1 is pinned and vendored under `Vendor/swift-sdk` with its license and provenance. It needs one JSON string decoding correction; see `UPSTREAM.md`.
- `Server(name:version:capabilities: .init(tools: .init(listChanged: false)))`, `try await server.start(transport: StdioTransport())`, `await server.waitUntilCompleted()`.
- `await server.withMethodHandler(ListTools.self) { _ in .init(tools: [...]) }` and `withMethodHandler(CallTool.self) { params in ... }`. Read arguments with `params.arguments?["x"]?.intValue`.
- `Tool(name:description:inputSchema: Value)`, where the schema is built with `.object([...])`.
- Results: `CallTool.Result(content: [.text(text:annotations:_meta:)], isError:)`. For images, use `.image(data: base64String, mimeType: "image/jpeg", annotations: nil, _meta: nil)`.

## HID facts we'll rely on

- Keyboard usages: a-z = 0x04-0x1D, 1-9 = 0x1E-0x26, 0 = 0x27, Enter 0x28, Esc 0x29, Backspace 0x2A, Tab 0x2B, Space 0x2C, arrows Right/Left/Down/Up = 0x4F/0x50/0x51/0x52.
- Modifier usages: Left Ctrl 0xE0 (224), Left Shift 0xE1, Left Alt 0xE2, Left Cmd 0xE3 (227).
- Modifier bits in a boot-style keyboard report: Ctrl 0x01, Shift 0x02, Alt 0x04, Cmd 0x08.
- Constant pointer velocity should give a constant gain despite iOS pointer acceleration. This is an assumption to verify.
- The user's iPhone hardware keyboard layout needs to be US. Otherwise symbols come out wrong, for example with a Hungarian layout.

## Open questions for test day

- H1: Does the iPhone show up as a capture device? (Expected yes.)
- H2 and H3: Does the input transport connect, type, and move the AssistiveTouch pointer?
- H4: Is the AssistiveTouch pointer visible in USB capture frames? This decides auto-calibration versus manual gains.
- H5: Do Cmd+H and Cmd+Space behave the same on a real iPhone as on the simulator?
- H6: Is the pointer gain linear at a constant step size and interval?
- Hardware needed: just the iPhone and a USB data cable.

## Implementation and end-to-end verification

- The actual iPhone 17 runtime is iOS **26.5**, confirmed visually in Settings > General > About through a Claude Code session using only the nine phone-use MCP tools. Xcode's version is not the simulator runtime version.
- `open_app` needs an 800 ms settling delay after Enter as well as between its preceding steps. Without it, the first screenshot can capture the app-opening animation.
- Ordinary taps can return before navigation finishes. A fresh screenshot may still show a transition; inspect another frame before assuming the tap missed or repeating it.
- Screenshot dimensions can change with rotation. Both backends update their internal bounds from captures, and the dispatcher maps coordinates using the most recent screenshot size.
- `Process.waitUntilExit()` on a different dispatch worker from launch intermittently hung after the child had already exited. This reproduced in the simulator integration test, a real Claude MCP session, and a stress test with 256 rapid concurrent child exits. Registering a termination handler before launch and storing completion under a lock resolved the reproduced race.
- Drain stdout and stderr concurrently while feeding stdin. Disable SIGPIPE on the input pipe because a child can close stdin early. Cancellation sends SIGTERM and escalates to SIGKILL after 250 ms for the direct child.
- USB capture requires camera usage metadata in the executable. The CLI embeds its Info.plist; capture refuses missing metadata or denied camera authorization with an actionable error. Frame requests wait for a newly delivered frame rather than returning a cached image.
- The default executable deliberately has no Bluetooth transport implementation. The other agent's module must be integrated at `Runtime.transportFactory` before physical input can work. Simulator success does not validate Bluetooth, USB capture, or AssistiveTouch behavior.
- On test day, also disconnect and reconnect USB while the MCP server remains running, without listing phones while disconnected. Confirm capture recovery; if the retained capture session does not recover, restart the server and record the behavior for a targeted fix.

- Cmd+H can restore populated Spotlight hidden behind an app launched from search. One Escape clears its query and another dismisses it. Home is now an explicit backend action. The simulator sends two native Home-button events 800 ms apart, then the macro waits 800 ms. Hardware retains Cmd+H, Escape, Escape with 800 ms release intervals; that fallback still needs physical validation. `open_app` uses the same Home action.
- Spotlight completion can consume a backspace without removing a typed character. In an ordinary text area, repeated backspace correctly removed two characters. Verify the field contents rather than inferring delivery solely from Spotlight's text length.

- AXe batch taps insert enough work between steps that two nominal taps may not become a double tap. The pinned patch resolves coordinates once and sends one composite with 40 ms holds and 80 ms gaps. Live double/triple selection verified the distinction.
- The AXe release frameworks were built with Swift 6.3.2 and could not be imported by this Mac's Swift 6.4 toolchain. The helper rebuilds all pinned IDB frameworks with the active toolchain. It confines upstream cleanup paths and ignores inherited build configuration.
- MCP SDK 0.12.1 automatically decoded JSON data-URL strings into binary values before tool dispatch, changing or rejecting literal text. Keeping JSON strings as strings fixes the boundary; explicit binary-value encoding remains supported. Wire tests reproduced the failure and verified exact input plus length limits.
