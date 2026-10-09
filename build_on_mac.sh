#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcrun --sdk iphoneos clang \
  -target arm64-apple-ios12.0 \
  -dynamiclib -fPIC -fobjc-arc -fblocks -O2 -Wall -Wextra \
  -Wl,-install_name,@rpath/ChaiUpdateBlockerV2.dylib \
  -lobjc -framework Foundation -framework UIKit \
  ChaiUpdateBlockerV2.m -o ChaiUpdateBlockerV2.dylib
codesign --force --sign - ChaiUpdateBlockerV2.dylib
file ChaiUpdateBlockerV2.dylib
lipo -info ChaiUpdateBlockerV2.dylib | grep -q 'arm64'
echo "Success: $(pwd)/ChaiUpdateBlockerV2.dylib"
