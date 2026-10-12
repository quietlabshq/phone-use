# TapKit teardown

Research notes on TapKit, which lets AI agents drive a real iPhone from a Mac. These notes are the starting point for an open-source, free alternative.

Collected 2026-09-29.

## References

- Launch tweet by TJ Littlejohn (@tj_littlejohn): https://x.com/tj_littlejohn/status/2104614327802282271
- Site: https://tapkit.ai
- Docs: https://docs.tapkit.ai (full index at https://docs.tapkit.ai/llms.txt)
- GitHub org: https://github.com/Jootsing-Research
  - `tapkit-releases`: DMG and Sparkle appcast. The Mac app itself is closed source.
  - `tapkit-python`: Python SDK for the REST API (plus CUA and OAGI adapters)
  - `tapkit-examples`: agent loops for Claude, OpenAI CUA, AutoGLM-Phone-9B, and UI-TARS-1.5-7B
  - `skills`, `tapkit-plugins-claude`, `tapkit-plugins-codex`, `tapkit-plugins-opencode`, `tapkit-plugin-openclaw`, `jootsing-plugins`: agent skills and plugins. There are per-app skills for Messages, Safari, Hinge, TikTok, LinkedIn, Uber Eats, and others. There are also iOS navigation skills for home screen recovery, pickers, and text editing.
  - `tapkit-docs`: the Mintlify docs source

### Tweet thread summary

- Launch: "a Mac app that lets your agents use your iPhone". It works with any agent and supports several phones at once.
- @GuyBuyside compared it with their own Appium setup. Appium reads the screen as text, taps by label, installs apps, and uses saved passwords. Its weak spots are that it needs Xcode and WebDriverAgent, and a stuck passcode prompt can block it. TapKit's weak spots are privacy (screenshots go through TapKit's cloud) and the price ($49 per phone per month).
- TJ replied that Appium is built for testing, not for agents. He added that "developer mode on its own is also a massive security risk" and that TapKit doesn't require it.
- @zakstaxx pointed out the 7-device cap and said it uses the Mac acting as a Bluetooth keyboard and mouse. TJ replied "Yes exactly".
- Pricing is flat $49 per phone per month with no volume discount. TJ said "pricing is something you figure out as you go".

## How it works

The docs and the app bundle (v1.0.101, `com.joosting.tapkit`) both confirm the mechanism below. The app bundle evidence comes from its `Info.plist`, entitlements, linked frameworks, and strings.

### 1. Screen capture: the iPhone as a USB camera

The app uses the same mechanism QuickTime uses for "New Movie Recording > iPhone":

- It sets `kCMIOHardwarePropertyAllowScreenCaptureDevices` through `CoreMediaIO`. The iPhone then shows up as an `AVCaptureDevice` of type external or muxed.
- This is why it asks for **Camera** permission. The usage string says: "your mac exposes it as a Camera".
- This needs a USB cable, the phone to trust the Mac, and nothing installed on the phone. Frames arrive in a module called `IOSScreenCapture`.
- There is a known issue where the capture sometimes doesn't start. The onboarding covers this with a "Sleep" step and a "Restart iPhone" step, both sent through lockdown `diagnostics_relay`.

### 2. Input: the Mac as a Bluetooth HID mouse and keyboard

- The app has an in-house Swift package called `HIDKit` (`HIDClassicManager`, `HIDClassicPeer`, SDP records, and HID control and interrupt channels over L2CAP). The Mac presents itself as a **Classic Bluetooth HID device**. The iPhone pairs with it from Settings > Bluetooth like any keyboard or mouse.
- It uses `CoreBluetooth` with `CBL2CAPChannel` and does not link `IOBluetooth`. That points to private or undocumented behaviour. A Classic piconet allows at most **7** active peripherals, which explains the 7-phone cap.
- The Bluetooth usage string says: "TapKit uses Bluetooth to expose an AssistiveTouch HID controller".
- **AssistiveTouch** must be on so that iOS shows a pointer for the mouse. The app turns it on over USB by writing the lockdown key `AssistiveTouchEnabledByiTunes` in domain `com.apple.Accessibility`. This is the same switch iTunes and Finder used for accessibility settings, and it doesn't need developer mode.
- The **Home** action is mouse button 3 mapped to Home. During onboarding the app goes through AssistiveTouch > Devices > (Mac) > Customize Additional Buttons, guided by a vision model. The binary contains prompts that return coordinates in a 0 to 999 grid and a model or service called "Lightcone".
- Keyboard: a HID keyboard report, which explains the "US-ASCII only, 100 chars" limit on typing (no emoji, no accented letters). Modifier and arrow keys work.
- Gestures (tap, double tap, triple tap, long press, flick, drag, hold and drag) are pointer moves plus button presses. Flick behaves unreliably. Their skills say "use drag, never flick" in Settings, and they ship a "warm up AssistiveTouch" routine.
- Earlier versions used **Switch Control**. The removed `enable_switch_control` tool, the `SwitchControlAutomationKit` bundle, and a "Gliding Cursor" mode all point to macOS Switch Control "Platform Switching", driven through AppleScript and System Settings on a hidden `CGVirtualDisplay`. They moved away from it.

### 3. Device management over lockdown (USB, no developer mode)

The app loads Apple's private `MobileDevice.framework` (`AMDevice*`) and uses these services:

- Pairing and trust (`AMDevicePair`, `AMDeviceValidatePairing`), and device info including the phone's Bluetooth address. It uses the Bluetooth address to match the USB device to the Bluetooth HID peer.
- `com.apple.springboardservices`: interface orientation. The same service can also return the home screen icon layout.
- `com.apple.mobile.diagnostics_relay`: restart and sleep.
- `AMDeviceLookupApplications`: list installed apps (the `get_apps` endpoint).

### 4. The iOS Shortcut side channel

The app bundle includes a "use-tapkit" iOS Shortcut flow (`/v1/shortcut-versions/use-tapkit/current`, `shortcut:next_action_polled`, `clipboardCopied`, a token exchange, and a QR scan). A Shortcut on the phone polls TapKit's server for things that pointer input can't do well, such as opening an app or copying text (`copy_text` in the Python SDK). The Mac side imports the Shortcut by driving Shortcuts.app with AppleScript.

### 5. Cloud

- The Mac app keeps a WebSocket open to `jootsing-server-production.up.railway.app` and uses Supabase for auth.
- The REST API is `api.tapkit.ai/v1`. Every action is a job routed to the right Mac. The MCP server is `mcp.tapkit.ai/mcp` (Streamable HTTP, OAuth).
- Screenshots are JPEGs with the long edge capped at 1344 px. TapKit **stores** screenshots, and Agora handles live browser streaming.
- The built-in agent calls a hosted LLM through their servers. PostHog handles analytics, Sparkle handles updates, and The Composable Architecture (TCA) is the app architecture.

### 6. Agent layer

- Tools: `list_phones`, `get_phone_status`, `screenshot`, `tap`, `double_tap`, `triple_tap`, `long_press`, `flick`, `drag`, `hold_and_drag`, `type_text`, `press_key`, `press_home`.
- Screenshot-only. There is no accessibility tree, so the agent has to locate elements from pixels. Most of the value is in the skills: iOS navigation recipes, per-app maps, and safety rules.

## Limitations of their approach

- The phone must stay unlocked with Auto-Lock set to Never. The app can't enter a passcode or pass Face ID. HID keyboard passcode entry might work, but they don't claim it.
- There's no UI hierarchy, so every step depends on vision grounding.
- ASCII-only typing, and the pointer is less precise than touch injection.
- The 7-phone Bluetooth limit per Mac.
- Privacy: every screenshot goes through and is stored on their servers.
