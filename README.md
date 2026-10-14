# phone-use

Phone Use lets AI agents and you control iPhone simulators and physical iPhones from a Mac. **Phone Use.app** owns phone access: it holds the Camera and Bluetooth permissions, shows every phone live, and lets you click, drag, and type on them. The `phone-use` CLI and its stdio MCP server talk to the app, so permissions work no matter which agent host launched them.

## Install the app

Requires macOS 14+, Xcode with an iPhone simulator, and Swift 6.1+. First build the pinned AXe with native multi-tap support; the app bundles it. The helper needs XcodeGen; the command below uses it through a temporary Nix environment. If XcodeGen is already on `PATH`, run `scripts/build-axe.sh` directly.

```sh
nix shell nixpkgs#xcodegen -c scripts/build-axe.sh
PHONE_USE_APP_OUTPUT="/Applications/Phone Use.app" scripts/build-app.sh
open "/Applications/Phone Use.app"
```

See [the AXe patch notes](patches/axe/README.md). `build-app.sh` signs with your first Developer ID Application identity (override with `PHONE_USE_SIGN_IDENTITY`), so permission grants survive rebuilds; ad-hoc builds are re-prompted after every rebuild. Set `PHONE_USE_NOTARY_PROFILE` to a `notarytool` keychain profile to notarize. Without `PHONE_USE_APP_OUTPUT` the app is written to `.build/Phone Use.app`.

Open **Setup** in the app to grant Camera and Bluetooth access, configure USB iPhones, install the command-line tool (a link at `~/.local/bin/phone-use`), and turn on launch at login. Closing the window keeps the app serving agents from the menu bar.

The live view streams simulators at about 8 frames per second and USB iPhones at their capture rate. Click to tap, hold to long press, drag to swipe, and type to send keys. Shift-Command-H goes Home and Command-O opens an app. Your input and agent actions share one queue per phone, so gestures never interleave.

## Command line

The CLI runs every command through the app and launches it in the background when needed. It finds the app that contains it, then `PHONE_USE_APP`, then `/Applications` and `~/Applications`.

```sh
BIN=~/.local/bin/phone-use
xcrun simctl boot <iphone-udid>
"$BIN" list
"$BIN" screenshot -o /tmp/phone.jpg
"$BIN" tap 309 672
"$BIN" home
"$BIN" open-app Settings
```

Use `--phone <id>` on actions when more than one phone is available. Screenshots are JPEGs with the longest edge capped at 1344 pixels. A 1206x2622 display produces a 618x1344 screenshot. Always use coordinates from the returned screenshot, including after rotation.

```sh
"$BIN" long-press 309 672 --duration-ms 800
"$BIN" swipe 309 1000 309 300 --duration-ms 300
"$BIN" type 'Hello'
"$BIN" key a --modifiers command --repeat 1
"$BIN" doctor
```

Text and app names support US-ASCII, with a 100-character limit. Tap count is 1-3; key repeat is 1-100. `doctor` checks that the app is serving and prints its discovery hints; the app's Setup screen has the detailed checks.

## MCP

```sh
"$BIN" mcp
```

`mcp` relays standard input and output to a session inside the app, over a private socket at `~/.config/phone-use/run/app.sock`. The app serves simulators and configured iPhones together; the old `--simulator` and `--hardware` flags are still accepted and ignored. The server reserves stdout for MCP JSON. Tools are `list_phones`, `screenshot`, `tap`, `long_press`, `swipe`, `type_text`, `press_key`, `press_home`, and `open_app`. Actions accept optional `phone_id`; it is required if discovery finds multiple phones. Screenshot results contain a base64 JPEG image and a coordinate note. Invalid arguments and backend failures return tool errors.

Register with Claude Code:

```sh
claude mcp add --transport stdio phone-use -- ~/.local/bin/phone-use mcp
```

For a desktop MCP client, use its MCP configuration:

```json
{
  "mcpServers": {
    "phone-use": {
      "command": "/Users/you/.local/bin/phone-use",
      "args": ["mcp"]
    }
  }
}
```

For agent operating instructions, see the [phone-use skill](skills/phone-use/SKILL.md).

## Physical iPhones

USB supplies screen capture. Classic Bluetooth HID supplies input separately: this Mac advertises itself as **phone-use HID Interface**, an absolute-coordinate mouse plus a US keyboard. Capture availability does not mean input is connected. See the [physical iPhone test-day guide](docs/test-day.md).

Connect, unlock, and trust the iPhone, then click **Add** next to its screen in the app's Setup. Camera access belongs to Phone Use.app, so agents launched from any host, including T3 Code, can capture. If capture finds no screen device, see [capture troubleshooting](docs/test-day.md#capture-troubleshooting). Setup writes `~/.config/phone-use/config.json`, which you can also edit by hand; the app reloads it on every discovery:

```json
{
  "phones": [
    {"name": "My iPhone", "captureDeviceName": "Richard's iPhone"}
  ]
}
```

Phone names and capture device names must be unique. A missing configuration is treated as empty; malformed configuration is reported as a hardware discovery hint and does not block simulator-only usage. Capture starts only when requested.

For input, enable Settings > Accessibility > Touch > AssistiveTouch. While a hardware phone is configured, the app advertises over Bluetooth; pair **phone-use HID Interface** in Settings > Bluetooth. Setup shows whether an iPhone is connected. Map AssistiveTouch additional button 3 to Home. The pointer uses absolute HID coordinates (0...32767), so `calibrate` is not required; it prints these pairing instructions.

## Remote access

`phone-use serve` and the relay still run phones in-process (see [remote access](docs/remote-access.md)). They cannot run while the app is open, because only one process may own phone access.

## Development

```sh
swift test
swift build -c release
scripts/build-app.sh
```

`Runtime.transportFactory` (in `PhoneUseRuntime`) returns the shared `ClassicHIDHost`. There is no ESP32 or serial input backend yet. The app design is in [the companion app spec](docs/superpowers/specs/2026-10-14-companion-app-design.md).

See [verification results and remaining hardware checks](docs/verification.md) for the completed simulator checks. Physical Bluetooth input still needs a live iPhone pass of the test-day guide.
