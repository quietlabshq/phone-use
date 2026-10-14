# phone-use

A macOS CLI and stdio MCP server for controlling iPhone simulators and configured physical iPhones. Both interfaces share the same nine tools and screenshot coordinate system.

## Simulator quickstart

Requires macOS 14+, Xcode with an iPhone simulator, and Swift 6.1+. Build the pinned AXe with native multi-tap support for the complete simulator backend. The helper needs XcodeGen; the command below uses it through a temporary Nix environment. If XcodeGen is already on `PATH`, run `scripts/build-axe.sh` directly.

```sh
nix shell nixpkgs#xcodegen -c scripts/build-axe.sh
export PHONE_USE_AXE="$PWD/.build/tools/axe/bin/axe"
```

The helper builds into `.build/tools/axe` without installing global tools. See [the AXe patch notes](patches/axe/README.md). Stock AXe >= 1.8.0 supports single taps and the other actions, but multi-tap requires this extension and fails with a setup error when unavailable. Restart an existing MCP server after changing AXe.

```sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)/phone-use"
xcrun simctl list devices available
xcrun simctl boot <iphone-udid>
"$BIN" list --simulator
"$BIN" screenshot --simulator -o /tmp/phone.jpg
"$BIN" tap 309 672 --simulator
"$BIN" home --simulator
"$BIN" open-app Settings --simulator
```

Use `--phone <id>` on actions when more than one phone is available. `--simulator` and `--hardware` select backends; neither flag means both. Screenshots are JPEGs with the longest edge capped at 1344 pixels. A 1206x2622 display produces a 618x1344 screenshot. Always use coordinates from the returned screenshot, including after rotation.

```sh
"$BIN" long-press 309 672 --duration-ms 800 --simulator
"$BIN" swipe 309 1000 309 300 --duration-ms 300 --simulator
"$BIN" type 'Hello' --simulator
"$BIN" key a --modifiers command --repeat 1 --simulator
"$BIN" doctor
```

Text and app names support US-ASCII, with a 100-character limit. Tap count is 1-3; key repeat is 1-100. `doctor` prints prerequisites and fixes, returning nonzero if checks fail. Hardware checks may need attention even when simulator use works.

## MCP

```sh
"$BIN" mcp --simulator
```

The server reserves stdout for MCP JSON. Tools are `list_phones`, `screenshot`, `tap`, `long_press`, `swipe`, `type_text`, `press_key`, `press_home`, and `open_app`. Actions accept optional `phone_id`; it is required if discovery finds multiple phones. Screenshot results contain a base64 JPEG image and a coordinate note. Invalid arguments and backend failures return tool errors.

Register with Claude Code, substituting absolute executable paths:

```sh
claude mcp add --transport stdio --env PHONE_USE_AXE=/absolute/path/to/axe phone-use -- /absolute/path/to/phone-use mcp --simulator
```

For a desktop MCP client, use its MCP configuration:

```json
{
  "mcpServers": {
    "phone-use": {
      "command": "/absolute/path/to/phone-use",
      "args": ["mcp", "--simulator"],
      "env": {"PHONE_USE_AXE": "/absolute/path/to/axe"}
    }
  }
}
```

For agent operating instructions, see the [phone-use skill](skills/phone-use/SKILL.md).

## Physical iPhones

USB supplies screen capture. Classic Bluetooth HID supplies input separately: this Mac advertises itself as **phone-use HID Interface**, an absolute-coordinate mouse plus a US keyboard. Capture availability does not mean input is connected. See the [physical iPhone test-day guide](docs/test-day.md).

Connect, unlock, and trust the iPhone. Grant Camera access when capturing. macOS asks the app that launched `phone-use` for it, so run hardware capture from a terminal such as Terminal.app; apps without the camera entitlement, such as T3 Code, are denied without a prompt. If capture finds no screen device, see [capture troubleshooting](docs/test-day.md#capture-troubleshooting). Save configuration at `~/.config/phone-use/config.json` using the capture device name reported by `doctor`:

```json
{
  "phones": [
    {"name": "My iPhone", "captureDeviceName": "Richard's iPhone"}
  ]
}
```

Phone names and capture device names must be unique. A missing configuration is treated as empty; malformed configuration is reported as a hardware discovery hint and does not block simulator-only usage. Capture starts only when requested.

For input, enable Settings > Accessibility > Touch > AssistiveTouch, run `phone-use doctor` or any hardware command so the Mac advertises, then pair **phone-use HID Interface** in Settings > Bluetooth. Map AssistiveTouch additional button 3 to Home. The pointer uses absolute HID coordinates (0...32767), so `calibrate` is not required; it prints these pairing instructions.

## Development

```sh
swift test
swift build -c release
```

`Runtime.transportFactory` returns the shared `ClassicHIDHost`. There is no ESP32 or serial input backend.

See [verification results and remaining hardware checks](docs/verification.md) for the completed simulator checks. Physical Bluetooth input still needs a live iPhone pass of the test-day guide.
