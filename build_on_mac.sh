#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcrun --sdk iphoneos clang \
  -target arm64-apple-ios12.0 \
  -dynamiclib -fPIC -fobjc-arc -fblocks -O2 -Wall -Wextra \
  -Wl,-install_name,@rpath/ChaiUpdateBlockerV3.dylib \
  -lobjc -framework Foundation -framework UIKit \
  ChaiUpdateBlockerV3.m -o ChaiUpdateBlockerV3.dylib
codesign --force --sign - ChaiUpdateBlockerV3.dylib
file ChaiUpdateBlockerV3.dylib
lipo -info ChaiUpdateBlockerV3.dylib | grep -q 'arm64'
echo "Success: $(pwd)/ChaiUpdateBlockerV3.dylib"
