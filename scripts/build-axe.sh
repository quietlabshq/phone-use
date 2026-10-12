#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tool_root="$repo_root/.build/tools/axe"
axe_revision=30f4bfa9bc81817906a60fadedbc913d7314b7e1
idb_revision=604c51013438f0c3603b720a05a44b7c5b8f286d
mkdir -p "$tool_root"

checkout() {
    local url=$1 revision=$2 destination=$3
    if [[ ! -d "$destination/.git" ]]; then
        git clone --filter=blob:none --no-checkout "$url" "$destination"
        git -C "$destination" checkout --detach "$revision"
    fi
    [[ $(git -C "$destination" rev-parse HEAD) == "$revision" ]] || {
        echo "Unexpected checkout revision in $destination; remove that task-owned directory and retry." >&2
        exit 1
    }
}
checkout https://github.com/cameroncooke/AXe.git "$axe_revision" "$tool_root/source"
checkout https://github.com/cameroncooke/idb.git "$idb_revision" "$tool_root/idb"
patch_file="$repo_root/patches/axe/native-multitap.patch"
if git -C "$tool_root/source" apply --check "$patch_file" 2>/dev/null; then
    git -C "$tool_root/source" apply "$patch_file"
elif ! git -C "$tool_root/source" apply --reverse --check "$patch_file" 2>/dev/null; then
    echo "AXe source does not match the maintained patch. Remove .build/tools/axe/source and retry." >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null; then
    echo "XcodeGen is required. Run: nix shell nixpkgs#xcodegen -c scripts/build-axe.sh" >&2
    exit 1
fi
export AXE_ENV_FILE=/dev/null
export IDB_CHECKOUT_DIR="$tool_root/idb"
export IDB_GIT_URL=https://github.com/cameroncooke/idb.git
export IDB_GIT_REF="$idb_revision"
export IDB_UPSTREAM_BASE_REF=e682506725e9efefb9c43b8b917c0b12eb2a5939
export BUILD_OUTPUT_DIR="$tool_root/source/build_products"
export DERIVED_DATA_PATH="$tool_root/source/build_derived_data"
export BUILD_XCFRAMEWORK_DIR="$BUILD_OUTPUT_DIR/XCFrameworks"
export TEMP_DIR="$tool_root/tmp"
mkdir -p "$TEMP_DIR"
cd "$tool_root/source"
compiler_stamp=$( { xcrun --find swiftc; xcrun --show-sdk-path; swiftc --version; } | shasum -a 256 | cut -d ' ' -f 1)
if [[ ! -f build_products/compiler-stamp || $(cat build_products/compiler-stamp) != "$compiler_stamp" ]]; then
    bash scripts/build.sh clean
    bash scripts/build.sh frameworks
    bash scripts/build.sh install
    bash scripts/build.sh strip
    for framework in build_products/Frameworks/*.framework; do
        codesign --force --sign - "$framework"
    done
    bash scripts/build.sh xcframeworks
    printf '%s\n' "$compiler_stamp" > build_products/compiler-stamp
fi

swift package clean
swift build -c release --arch "$(uname -m)"
bin_path=$(swift build -c release --arch "$(uname -m)" --show-bin-path)
mkdir -p "$tool_root/bin"
cp "$bin_path/axe" "$tool_root/bin/axe"
ditto "$bin_path/AXe_AXe.bundle" "$tool_root/bin/AXe_AXe.bundle"
ditto "$tool_root/source/build_products/Frameworks" "$tool_root/bin/Frameworks"
install_name_tool -add_rpath '@executable_path/Frameworks' "$tool_root/bin/axe"
codesign --force --sign - --entitlements entitlements.plist "$tool_root/bin/axe"
"$tool_root/bin/axe" tap --help | grep -q -- '--count'
printf '\nReady: export PHONE_USE_AXE="%s/bin/axe"\n' "$tool_root"
