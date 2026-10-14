# Linux portability spike

> Paused on 2026-10-14. The package is macOS-only; the Linux manifest branch, fake-phone executable, and Linux scripts were removed. Recover them from git history to resume.

This hardware-independent slice was started on 2026-09-29 at the user's direction while Task 15 remains pending. It proves that the portable frame, HID planning, MCP dispatcher, and a fake-phone stdio executable build and run on Linux. It does not implement or claim support for Linux capture or Bluetooth input.

## What is included

- `PixelFrame` owns its bytes and describes RGBA8 premultiplied sRGB pixels, row stride, orientation, and monotonic capture freshness.
- The shared `Phone.screenshot`, cursor analysis, calibration, and dispatcher use `PixelFrame`. CoreGraphics conversion and ImageIO encoding live in the macOS capture adapter.
- The Linux SwiftPM manifest excludes the AVFoundation, CoreMediaIO, CoreGraphics, ImageIO, simulator, physical-capture, and remote HTTP/relay targets.
- The Linux `phone-use` executable exposes stdio MCP and a deterministic `--fake` phone for protocol checks. The fake screenshot uses a bundled JPEG fixture; Linux image encoding remains undecided until Task 15.
- POSIX imports compile against Glibc. Linux subprocess stdin writes block SIGPIPE on the writer thread and consume any newly pending signal before restoring that thread's prior signal mask.

The fake executable does not provide the macOS CLI commands, device discovery, or a real Linux backend. Task 15 still needs the Mac physical-device baseline, a real iPhone, a Linux host, and a Bluetooth adapter. Tasks 18-20 remain hardware gates. The current resolved `swift-collections` 1.7.1 dependency requires Swift 6.2, so the Linux proof uses Swift 6.2.4 although the package manifest retains tools version 6.1.

## Verification environment

The Linux container was `swift:6.2`, Ubuntu 24.04.5 LTS, aarch64, Swift 6.2.4 (`aarch64-unknown-linux-gnu`). This is a smoke-test environment only; Task 15 will choose the supported Linux distribution and hardware.

Run from the repository root:

```sh
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2 swift test
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.2 swift build -c release
python3 scripts/test-linux-stdio.py -- docker run --rm -i -v "$PWD:/workspace" -w /workspace swift:6.2 sh /workspace/scripts/run-linux-fake-mcp.sh
```

The stdio smoke drives the actual executable through initialize, `tools/list`, fake phone discovery, an image response, an action, and an invalid tool call. It keeps stdin open until each response arrives, then checks clean process shutdown.

The macOS suite also passes with the portable frame migration. The simulator integration remains separately gated by `PHONE_USE_SIM_UDID`, as recorded in [verification](verification.md).
