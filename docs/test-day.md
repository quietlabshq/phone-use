# Physical iPhone test day

This checklist validates a particular Mac, iPhone, and iOS version. USB capture and Bluetooth input are separate. **The default build has no input transport.** Complete the separately owned Mac Bluetooth transport work (Task 10), integrate it at `Runtime.transportFactory`, and establish its host connection before input tests. Pairing an unrelated keyboard does not connect this CLI. No pairing or raw mouse-count command is currently exposed by the CLI.

Record the device, OS versions, capture dimensions, transport implementation, and each result. These are hardware assumptions to test, not claims of compatibility:

| Assumption | Evidence required |
| --- | --- |
| H1: USB capture | A current, unlocked iPhone image reaches the Mac. |
| H2: Bluetooth keyboard | The integrated transport sends correct US-layout keys. |
| H3: Bluetooth mouse | AssistiveTouch responds to the integrated mouse reports. |
| H4: Cursor visible | USB captures include the moving cursor sufficiently clearly for calibration. |
| H5: Shortcuts | Command-H and Command-Space work in the tested iOS configuration. |
| H6: Gain and cadence | Measured gains remain accurate at the configured cadence and corner reset succeeds. |

## Ordered checklist

1. **Prepare manually.** Connect by USB, unlock the phone, and accept Trust. Select the US hardware keyboard layout, set Auto-Lock to Never for the session, and enable Settings > Accessibility > Touch > AssistiveTouch. Keep the orientation and pointer settings fixed. If these options are unavailable, resolve that before input testing. Restore the user's preferred Auto-Lock setting afterward.

2. **Build and diagnose.** From the repository:

   ```sh
   swift build -c release
   BIN="$(swift build -c release --show-bin-path)/phone-use"
   "$BIN" doctor
   ```

   Expect a successful build and individual `OK` or `FIX` lines for AXe, booted simulators, capture, configuration, and input. `doctor` exits nonzero when any check fails. AXe >= 1.8.0 is needed for simulator work; use the [pinned build](../patches/axe/README.md) for native multi-tap and set `PHONE_USE_AXE` to its executable if discovery fails. A simulator warning does not establish a hardware failure. For capture failure, check USB, unlock, Trust, and Camera permission (see [capture troubleshooting](#capture-troubleshooting)). For config failure, correct the JSON. An input failure requires the integrated transport and a connected host, even if capture works.

3. **Configure capture and list phones.** Save `~/.config/phone-use/config.json` using the exact capture device name printed by `doctor`. This is example configuration, not a device discovered by this guide:

   ```json
   {
     "phones": [
       {
         "name": "My iPhone",
         "captureDeviceName": "My iPhone"
       }
     ]
   }
   ```

   ```sh
   "$BIN" list --hardware
   ```

   Expect a hardware ID for the configured, connected capture device. Copy that ID into `PHONE_ID` below. If absent, compare capture names exactly and reconnect/unlock the phone. Names and capture device names must each be unique. Missing config is treated as empty.

4. **Verify USB capture (H1).**

   ```sh
   PHONE_ID='<hardware-id-from-list>'
   "$BIN" screenshot --hardware --phone "$PHONE_ID" -o /tmp/iphone.jpg
   ```

   Open the JPEG and compare it with the phone. Expect the current screen, with its longest edge at most 1344 pixels. If stale, blank, or blocked, fix capture before proceeding. Also disconnect and reconnect USB while MCP remains running, without listing phones while disconnected, then request another screenshot. Verify recovery; if capture stays timed out, restart the MCP server and record this as a reconnect issue for debugging. Tool coordinates always refer to this returned image's pixels, not iOS points or the full native display resolution.

5. **Verify keyboard and shortcuts (H2, H5), only after connecting the input transport.**

   ```sh
   "$BIN" key h --modifiers command --hardware --phone "$PHONE_ID"
   "$BIN" screenshot --hardware --phone "$PHONE_ID" -o /tmp/iphone.jpg
   "$BIN" open-app Settings --hardware --phone "$PHONE_ID"
   "$BIN" screenshot --hardware --phone "$PHONE_ID" -o /tmp/iphone.jpg
   ```

   Inspect each screenshot before the next action. Expect Home after Command-H and Settings after `open-app`. The latter uses Home, Command-Space, typing, and Enter, with settling delays. If input is disconnected, stop and fix the transport. If keys arrive but launch fails, check the US layout and Spotlight shortcut manually; do not infer mouse support from keyboard success.

6. **Calibrate pointer (H3, H4, H6).** Return to a static Home Screen with no animation or notification obscuring it, then run:

   ```sh
   "$BIN" home --hardware --phone "$PHONE_ID"
   "$BIN" calibrate --phone "$PHONE_ID"
   ```

   Expect pointer movement followed by a message that gains were saved to `~/.config/phone-use/config.json`. Calibration compares captures for cursor movement and rejects invisible, clipped, ambiguous, or inconsistent results. Watch the phone as well as the captures to distinguish an invisible captured cursor from failed mouse input. Recalibration preserves the existing cadence. Restart an already-running MCP server after CLI calibration or any configuration edit so it reloads the saved values.

   If the cursor is invisible in USB capture, automated calibration cannot measure it. Manual fallback requires measured gains from observing actual pointer displacement at a known report cadence, using the transport's own diagnostic facility if it has one. The current CLI has no raw-count movement command. Do not claim a measurement from `tap` alone, since `tap` already depends on configured gains. If no such diagnostic facility exists, record H4 as failed and defer reliable pointer control until one is available.

   The optional `pointer` object below shows the schema. **All gains are EXAMPLES, not measurements.** Replace them only with measured values; 8 counts every 8 ms is a valid starting cadence:

   ```json
   {
     "phones": [
       {
         "name": "My iPhone",
         "captureDeviceName": "My iPhone",
         "pointer": {
           "pixelsPerCountX": 1.0,
           "pixelsPerCountY": 1.0,
           "stepCounts": 8,
           "stepIntervalMs": 8
         }
       }
     ]
   }
   ```

   Gains describe native capture pixels per HID count internally; the tools translate returned-image coordinates. Pointer acceleration can make gain depend on cadence. Keep cadence, orientation, and iOS pointer settings fixed and recalibrate when they change. Each pointer action resets toward the top-left using 40 reports of -127 counts per axis at 8 ms intervals, then moves to its target. This assumes the reset reaches the corner; it is not visual feedback. The implementation rejects gains requiring more than 5080 counts to cross either axis and movement cadences exceeding its time limit. Passing these checks does not prove real-device accuracy.

7. **Check nine Home Screen positions (H3, H6).** Choose safe app icons across top/middle/bottom and left/center/right regions. On a fresh screenshot, record the center of each visible icon in returned-image pixels. For each of the nine positions, substitute its measured coordinates:

   ```sh
   "$BIN" tap <x> <y> --hardware --phone "$PHONE_ID"
   "$BIN" screenshot --hardware --phone "$PHONE_ID" -o /tmp/iphone.jpg
   "$BIN" home --hardware --phone "$PHONE_ID"
   "$BIN" screenshot --hardware --phone "$PHONE_ID" -o /tmp/iphone.jpg
   ```

   Inspect after each action. Expect the intended app, then Home. Record target, actual result, and any systematic drift. A failed tap gets one retry with fresh screenshot coordinates; repeated misses mean calibration or reset assumptions need investigation. Avoid icons or controls that immediately send, purchase, or delete anything.

8. **Exercise MCP with Claude.** Register the absolute built executable in Claude Code:

   ```sh
   claude mcp add --transport stdio phone-use -- /absolute/path/to/phone-use mcp --hardware
   ```

   Expect successful registration and the nine phone-use tools on the next client connection. If missing, check the absolute executable path and restart the MCP connection. Use [the phone-use agent skill](../skills/phone-use/SKILL.md) as task instructions; this repository does not install it globally. Run three safe tasks, inspecting screenshots after each action:

   - "List the phones, take a screenshot of my configured iPhone, and describe its current screen."
   - "Open Settings on my iPhone and show me the screen without changing settings."
   - "Return Home, open Settings, scroll down once, show the result, then return Home. Do not change any settings."

   Expect correct phone selection, screenshot coordinates, and a screenshot-action-verification loop. Stop at authentication prompts or repeated targeting failures. Capture success alone is not a pass for the input tasks. Do not extend these checks to sending messages, posting, payments, or deletion without explicit authorization.

## Capture troubleshooting

These steps got USB capture working on 2026-10-14 (iPhone 15 Pro Max, macOS 27.0, iOS 27). Work through them in order.

**Run from an app that can get Camera access.** macOS charges a command-line tool's Camera use to the app that launched it. Terminal.app and cmux can ask for access; T3 Code (Nightly) cannot, because it is signed with the hardened runtime and without `com.apple.security.device.camera`. From such an app, `screenshot` fails with "Camera access denied", and the app never appears in System Settings > Privacy & Security > Camera. Discovery (`doctor`, `list`) works anywhere because it does not open the camera. An agent session running inside T3 Code can still drive capture by writing a script and opening it in Terminal:

```sh
mkdir -p /tmp/pu-run && cat > /tmp/pu-run/screenshot.command <<'SH'
#!/bin/sh
exec > /tmp/pu-run/screenshot.log 2>&1
cd /path/to/phone-use && "$(swift build -c release --show-bin-path)/phone-use" screenshot --hardware --phone "$PHONE_ID" -o /tmp/iphone.jpg
echo "exit=$?"
SH
chmod +x /tmp/pu-run/screenshot.command && open -a Terminal /tmp/pu-run/screenshot.command
```

**Check that the screen device exists, not just the camera.** A paired iPhone can show up only as Continuity Camera devices (`<name> Camera`, `<name> Desk View Camera`), which carry video but not the screen. The screen device is named after the phone itself (for example `richard-15`), carries muxed media, and is what `doctor` lists and QuickTime shows under File > New Movie Recording. If QuickTime does not list it either, the problem is below phone-use.

**Confirm the phone is on USB and unlocked.** `xcrun devicectl list devices` should say `connected`, not `available (paired)`, which means network only. `xcrun devicectl device info lockState --device <udid>` should report `passcodeRequired: false`. The screen device disappears when the phone auto-locks, and captures then time out.

**If the screen device is still missing, sleep the phone over USB.** This is the fix that worked, and TapKit's onboarding uses the same recovery (see [the TapKit teardown](../research/tapkit.md)):

```sh
nix shell nixpkgs#libimobiledevice -c idevicediagnostics -u <udid> sleep
```

The phone goes into deep sleep. Wake and unlock it; the screen device appeared immediately afterwards. Replugging the cable alone did not help. If sleeping does not help either, unplug and replug while unlocked, then restart the iPhone (`idevicediagnostics -u <udid> restart`, or by hand).

`list --hardware` reports the size as `1x1` until the first screenshot; it is a placeholder, not a capture failure.
