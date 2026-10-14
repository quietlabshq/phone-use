# Physical iPhone test day

This checklist validates a particular Mac, iPhone, and iOS version. USB capture and Bluetooth input are separate. Input uses the built-in Classic Bluetooth HID host (`ClassicHIDHost`), which advertises **phone-use HID Interface**. Pairing an unrelated keyboard does not connect this CLI.

Record the device, OS versions, capture dimensions, and each result. These are hardware assumptions to test, not claims of compatibility:

| Assumption | Evidence required |
| --- | --- |
| H1: USB capture | A current, unlocked iPhone image reaches the Mac. |
| H2: Bluetooth keyboard | The HID host sends correct US-layout keys. |
| H3: Bluetooth mouse | AssistiveTouch responds to absolute-coordinate mouse reports. |
| H4: Cursor visible | USB captures include the moving cursor well enough to confirm a tap landed. |
| H5: Shortcuts | Command-Space (Spotlight) works in the tested iOS configuration. Home is AssistiveTouch additional button 3, not Command-H. |
| H6: Absolute mapping | Pixel (0, 0) in the returned screenshot maps to HID (0, 0) and the opposite corner to (32767, 32767) with no calibration. |

## Ordered checklist

1. **Prepare manually.** Connect by USB, unlock the phone, and accept Trust. Select the US hardware keyboard layout, set Auto-Lock to Never for the session, and enable Settings > Accessibility > Touch > AssistiveTouch. Keep the orientation and pointer settings fixed. If these options are unavailable, resolve that before input testing. Restore the user's preferred Auto-Lock setting afterward. After the Mac is advertising (step 2), pair **phone-use HID Interface** in Settings > Bluetooth, then in AssistiveTouch > Devices open that HID device and map additional button 3 to Home.

2. **Build, open the app, and diagnose.** From the repository:

   ```sh
   nix shell nixpkgs#xcodegen -c scripts/build-axe.sh
   scripts/build-app.sh
   open ".build/Phone Use.app"
   BIN=".build/Phone Use.app/Contents/MacOS/phone-use"
   ```

   In the app, open **Setup**. Allow Camera and Bluetooth, and check that AXe, the USB screen, and the Bluetooth HID rows are green. For capture failure, check USB, unlock, Trust, and Camera permission (see [capture troubleshooting](#capture-troubleshooting)). Bluetooth HID shows **Advertising** once a hardware phone is configured; it turns green only when the iPhone is paired with and connected to **phone-use HID Interface**, even if capture works. `phone-use doctor` prints the same discovery hints from a terminal.

3. **Configure capture and list phones.** Click **Add** next to the iPhone's screen in Setup, or save `~/.config/phone-use/config.json` using the exact capture device name shown there. This is example configuration, not a device discovered by this guide:

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
   "$BIN" list
   ```

   Expect a hardware ID for the configured, connected capture device. Copy that ID into `PHONE_ID` below. If absent, compare capture names exactly and reconnect/unlock the phone. Names and capture device names must each be unique. Missing config is treated as empty.

4. **Verify USB capture (H1).**

   ```sh
   PHONE_ID='<hardware-id-from-list>'
   "$BIN" screenshot --phone "$PHONE_ID" -o /tmp/iphone.jpg
   ```

   Open the JPEG and compare it with the phone. Expect the current screen, with its longest edge at most 1344 pixels. If stale, blank, or blocked, fix capture before proceeding. Also disconnect and reconnect USB while MCP remains running, without listing phones while disconnected, then request another screenshot. Verify recovery; if capture stays timed out, restart the MCP server and record this as a reconnect issue for debugging. Tool coordinates always refer to this returned image's pixels, not iOS points or the full native display resolution.

5. **Verify keyboard and shortcuts (H2, H5), only after pairing the HID host.**

   ```sh
   "$BIN" home --phone "$PHONE_ID"
   "$BIN" screenshot --phone "$PHONE_ID" -o /tmp/iphone.jpg
   "$BIN" open-app Settings --phone "$PHONE_ID"
   "$BIN" screenshot --phone "$PHONE_ID" -o /tmp/iphone.jpg
   ```

   Inspect each screenshot before the next action. Expect Home after `home` (AssistiveTouch button 3) and Settings after `open-app`. The latter uses Home, Command-Space, typing, and Enter, with settling delays. If input is disconnected, stop and pair **phone-use HID Interface**. If keys arrive but launch fails, check the US layout and Spotlight shortcut manually; do not infer mouse support from keyboard success. `calibrate` only prints pairing instructions; it does not move the pointer or write gains.

6. **Confirm the absolute pointer (H3, H4, H6).** Return to a static Home Screen with no animation or notification obscuring it. Take a screenshot and tap a known icon using coordinates from that image:

   ```sh
   "$BIN" screenshot --phone "$PHONE_ID" -o /tmp/iphone.jpg
   "$BIN" tap <icon-x> <icon-y> --phone "$PHONE_ID"
   "$BIN" screenshot --phone "$PHONE_ID" -o /tmp/iphone.jpg
   "$BIN" home --phone "$PHONE_ID"
   ```

   Expect the pointer to jump to the icon and the tap to open it, then Home. Watch the phone as well as the captures to distinguish an invisible captured cursor from failed mouse input. The HID mouse is absolute (report ID 2, 16-bit X/Y on 0...32767), so there is no corner reset and no `pointer` gains object to measure. If the tap lands systematically off-target, record the screenshot coordinate, the observed hit, and the screen size; do not add a calibration step.

7. **Check nine Home Screen positions (H3, H6).** Choose safe app icons across top/middle/bottom and left/center/right regions. On a fresh screenshot, record the center of each visible icon in returned-image pixels. For each of the nine positions, substitute its measured coordinates:

   ```sh
   "$BIN" tap <x> <y> --phone "$PHONE_ID"
   "$BIN" screenshot --phone "$PHONE_ID" -o /tmp/iphone.jpg
   "$BIN" home --phone "$PHONE_ID"
   "$BIN" screenshot --phone "$PHONE_ID" -o /tmp/iphone.jpg
   ```

   Inspect after each action. Expect the intended app, then Home. Record target, actual result, and any systematic drift. A failed tap gets one retry with fresh screenshot coordinates; repeated misses mean the absolute mapping or AssistiveTouch pointer settings need investigation. Avoid icons or controls that immediately send, purchase, or delete anything.

8. **Exercise MCP with Claude.** Install the command-line tool from Setup, then register it in Claude Code:

   ```sh
   claude mcp add --transport stdio phone-use -- ~/.local/bin/phone-use mcp
   ```

   Expect successful registration and the nine phone-use tools on the next client connection. If missing, check the absolute executable path and restart the MCP connection. Use [the phone-use agent skill](../skills/phone-use/SKILL.md) as task instructions; this repository does not install it globally. Run three safe tasks, inspecting screenshots after each action:

   - "List the phones, take a screenshot of my configured iPhone, and describe its current screen."
   - "Open Settings on my iPhone and show me the screen without changing settings."
   - "Return Home, open Settings, scroll down once, show the result, then return Home. Do not change any settings."

   Expect correct phone selection, screenshot coordinates, and a screenshot-action-verification loop. Stop at authentication prompts or repeated targeting failures. Capture success alone is not a pass for the input tasks. Do not extend these checks to sending messages, posting, payments, or deletion without explicit authorization.

## Capture troubleshooting

These steps got USB capture working on 2026-10-14 (iPhone 15 Pro Max, macOS 27.0, iOS 27). Work through them in order.

**Grant Camera access to Phone Use.app.** macOS charges Camera use to the app responsible for a process. Before the companion app, `phone-use` launched from T3 Code (Nightly) was denied without a prompt, because T3 Code lacks `com.apple.security.device.camera`. The app now opens the camera itself, so check System Settings > Privacy & Security > Camera for **Phone Use**, or use Setup > Camera.

**Check that the screen device exists, not just the camera.** A paired iPhone can show up only as Continuity Camera devices (`<name> Camera`, `<name> Desk View Camera`), which carry video but not the screen. The screen device is named after the phone itself (for example `richard-15`), carries muxed media, and is what Setup lists and QuickTime shows under File > New Movie Recording. If QuickTime does not list it either, the problem is below phone-use.

**Confirm the phone is on USB and unlocked.** `xcrun devicectl list devices` should say `connected`, not `available (paired)`, which means network only. `xcrun devicectl device info lockState --device <udid>` should report `passcodeRequired: false`. The screen device disappears when the phone auto-locks, and captures then time out.

**If the screen device is still missing, sleep the phone over USB.** This is the fix that worked, and TapKit's onboarding uses the same recovery (see [the TapKit teardown](../research/tapkit.md)):

```sh
nix shell nixpkgs#libimobiledevice -c idevicediagnostics -u <udid> sleep
```

The phone goes into deep sleep. Wake and unlock it; the screen device appeared immediately afterwards. Replugging the cable alone did not help. If sleeping does not help either, unplug and replug while unlocked, then restart the iPhone (`idevicediagnostics -u <udid> restart`, or by hand).

`list` reports the size as `1x1` until the first screenshot; it is a placeholder, not a capture failure.
