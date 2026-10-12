# phone-use design

An open-source, local-only way for AI agents to use a real iPhone. It follows TapKit's architecture (see `research/tapkit.md`), with no cloud and no subscription.

## Goals

- An agent (Claude Code or any MCP client) can see an iPhone screen and tap, swipe, type, go Home, and open apps.
- Everything runs on the user's Mac. Screenshots never leave the machine except to the agent's own model provider.
- The same tools work on the iOS Simulator, so the agent layer can be developed and tested without hardware.
- Nothing is installed on the iPhone, and developer mode and jailbreaking are not needed.

## Non-goals (v1)

- Multiple Macs, remote access, team sharing, live browser streaming.
- Unlocking the phone. It must stay unlocked with Auto-Lock set to Never.
- Accessibility-tree access on real hardware. Real phones are screenshot-only.
- Non-ASCII typing on real hardware.

## Architecture

```
agent (Claude Code, ...) --stdio MCP--> phone-use mcp
                                             |
                          +------------------+-------------------+
                          |                                      |
                   SimulatorPhone                          HardwarePhone
            (xcrun simctl screenshot, AXe input)   (USB screen capture + input transport)
                                                                 |
                                         USB cable: iPhone screen as AVCaptureDevice
                                         input transport (separate module) -> iPhone
```

- **Eyes (hardware):** macOS exposes a USB-connected, trusted iPhone as a capture device once `kCMIOHardwarePropertyAllowScreenCaptureDevices` is set. This is the public CoreMediaIO property QuickTime uses. We read frames through AVFoundation.
- **Hands (hardware):** does whatever TapKit is doing via Bluetooth. Built by another agent behind the `HIDTransport` interface.
- **Pointer:** iOS shows a pointer for a Bluetooth mouse when AssistiveTouch is on. The user turns it on once. Mouse input is relative, so taps work by pushing the pointer into the top-left corner, then moving a calibrated number of counts at a constant speed. Constant speed matters because iOS pointer acceleration depends on velocity, so a fixed step and interval give a linear gain. Gains come from a calibration command that finds the cursor by diffing screen captures, or from manual config values.
- **Home and opening apps:** hardware-keyboard shortcuts. Cmd+H goes Home. Cmd+Space opens Spotlight, where we type the app name and press Enter. Both are verified on the iOS 27 simulator with HID keyboard input.
- **Simulator:** `xcrun simctl io <udid> screenshot` for pixels, and AXe >= 1.8 for touch and keyboard HID input. AXe works in points, and we convert from pixels using the root accessibility frame.
- **Agent interface:** a stdio MCP server exposing `list_phones`, `screenshot`, `tap`, `long_press`, `swipe`, `type_text`, `press_key`, `press_home`, and `open_app`. Screenshots are JPEGs whose long edge is scaled to at most 1344 px. Tool coordinates are in screenshot pixels, and the server maps them to native pixels. Actions on one phone are serialized.
- **Skill:** `skills/phone-use/SKILL.md` teaches agents the screenshot-act loop, iOS navigation, and safety rules.

## Configuration

`~/.config/phone-use/config.json`:

```json
{
  "phones": [
    {
      "name": "Richard's iPhone",
      "captureDeviceName": "Richard's iPhone",
      "pointer": { "pixelsPerCountX": 2.1, "pixelsPerCountY": 2.1, "stepCounts": 8, "stepIntervalMs": 8 }
    }
  ]
}
```

## Hypotheses to verify on test day

- H1: The iPhone appears as an AVCaptureDevice after enabling screen capture devices (high confidence, it's how QuickTime works).
- H2: The iPhone connects to the input transport and accepts keyboard input.
- H3: Relative mouse moves the AssistiveTouch pointer, and button 1 taps (high).
- H4: The AssistiveTouch pointer is visible in USB screen capture frames, so auto-calibration works (unknown; manual gains are the fallback).
- H5: Cmd+H and Cmd+Space work on a real iPhone over a Bluetooth keyboard as they do on the simulator (medium-high).
- H6: A constant step size and interval give a linear pointer gain (medium).
