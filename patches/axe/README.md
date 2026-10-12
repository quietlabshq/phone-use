# AXe native multi-tap

`native-multitap.patch` applies to Cameron Cooke's AXe v1.8.0, commit
`30f4bfa9bc81817906a60fadedbc913d7314b7e1`. AXe is MIT licensed; its license is
included in this directory. The patch is maintained by this project under the
same license.

AXe's batch runner resolves coordinates and drains the HID transport for each
step. Its host-side delays therefore cannot guarantee double- or triple-tap
intervals. This patch adds `tap --count 1...3`: counts above one resolve the
coordinates once and submit all contacts as one HID composite, with 40 ms
contact holds and 80 ms gaps. Existing single-tap behavior stays intact. The
option also works in batch tap steps.

Run `scripts/build-axe.sh` from the repository root, or
`nix shell nixpkgs#xcodegen -c scripts/build-axe.sh` when XcodeGen is not installed.
The helper checks out pinned AXe and its pinned IDB revision, builds their
frameworks with the active Xcode, applies this patch, and produces a locally
signed executable at `.build/tools/axe/bin/axe`. It does not install global tools
or modify Xcode selection. Build downloads happen only in this explicit setup
step, never when phone-use runs.

Set `PHONE_USE_AXE` to the absolute path of that executable. Stock AXe still
supports single taps; multi-tap fails before sending input with an actionable
setup error when `tap --help` lacks `--count`.
