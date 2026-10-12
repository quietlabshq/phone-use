#!/bin/sh
set -eu

binary_dir=$(swift build -c release --show-bin-path)
exec "$binary_dir/phone-use" mcp --fake
