#!/bin/bash
# Builds "Phone Use.app" from SwiftPM output, embeds the phone-use CLI, the Geist fonts, and
# the patched AXe (when scripts/build-axe.sh has run), and signs everything with the hardened runtime.
#
# Environment:
#   PHONE_USE_SIGN_IDENTITY  codesign identity; defaults to the first "Developer ID
#                            Application" identity, then ad-hoc ("-") with a warning.
#   PHONE_USE_NOTARY_PROFILE notarytool keychain profile; when set, the app is notarized
#                            and stapled.
#   PHONE_USE_APP_OUTPUT     output path (default: .build/Phone Use.app).
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
app=${PHONE_USE_APP_OUTPUT:-"$repo_root/.build/Phone Use.app"}
axe_dir="$repo_root/.build/tools/axe/bin"
entitlements="$repo_root/Sources/PhoneUseApp/PhoneUse.entitlements"

cd "$repo_root"
swift build -c release --product PhoneUseApp
swift build -c release --product phone-use
bin=$(swift build -c release --show-bin-path)

identity=${PHONE_USE_SIGN_IDENTITY:-}
if [[ -z "$identity" ]]; then
    identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [[ -z "$identity" ]]; then
    identity=-
    echo "warning: no Developer ID identity found; signing ad hoc. macOS will ask for permissions again after every rebuild." >&2
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$repo_root/Sources/PhoneUseApp/Info.plist" "$app/Contents/Info.plist"
cp "$bin/PhoneUseApp" "$app/Contents/MacOS/PhoneUseApp"
cp "$bin/phone-use" "$app/Contents/MacOS/phone-use"
cp -R "$repo_root/Sources/PhoneUseApp/Fonts" "$app/Contents/Resources/Fonts"
if [[ -x "$axe_dir/axe" ]]; then
    cp -R "$axe_dir" "$app/Contents/Helpers/axe"
else
    echo "warning: patched AXe not built; simulators will need AXe from Homebrew. Run scripts/build-axe.sh to bundle it." >&2
fi

# Notarization requires secure timestamps, which need the network; local builds skip them.
timestamp=--timestamp=none
if [[ -n "${PHONE_USE_NOTARY_PROFILE:-}" ]]; then
    [[ "$identity" == "-" ]] && { echo "Notarization needs a Developer ID identity." >&2; exit 1; }
    timestamp=--timestamp
fi
sign() {
    codesign --force --options runtime "$timestamp" --sign "$identity" "$@"
}
# Sign nested code inside out: frameworks and bundles, then executables, then the app.
if [[ -d "$app/Contents/Helpers/axe" ]]; then
    for framework in "$app/Contents/Helpers/axe/Frameworks"/*.framework; do
        find "$framework" -type d -name "*.framework" -path "*/Frameworks/*" -mindepth 2 | sort -r | while read -r nested; do sign "$nested"; done
        sign "$framework"
    done
    sign "$app/Contents/Helpers/axe/AXe_AXe.bundle"
    sign "$app/Contents/Helpers/axe/axe"
fi
sign --entitlements "$entitlements" --identifier com.quietlabs.phone-use.cli "$app/Contents/MacOS/phone-use"
sign --entitlements "$entitlements" "$app"
codesign --verify --strict --deep "$app"

if [[ -n "${PHONE_USE_NOTARY_PROFILE:-}" ]]; then
    archive=$(mktemp -d)/PhoneUse.zip
    ditto -c -k --keepParent "$app" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$PHONE_USE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
fi

echo "Built $app (signed with: $identity)"
