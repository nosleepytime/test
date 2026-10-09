#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcrun --sdk iphoneos clang \
  -target arm64-apple-ios12.0 \
  -dynamiclib -fPIC -O2 -Wall -Wextra \
  -Wl,-install_name,@rpath/ChaiUpdateBlocker.dylib \
  -lobjc -framework Foundation -framework UIKit \
  ChaiUpdateBlocker.c -o ChaiUpdateBlocker.dylib
codesign --force --sign - ChaiUpdateBlocker.dylib
file ChaiUpdateBlocker.dylib
lipo -verify_arch arm64 ChaiUpdateBlocker.dylib
echo "Success: $(pwd)/ChaiUpdateBlocker.dylib"
