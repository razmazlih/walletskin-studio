#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
/usr/bin/python3 scripts/prepare_helper.py
/usr/bin/python3 scripts/prepare_artwork.py
/usr/bin/python3 -m unittest discover -s Tests -p 'test_*.py' -v
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/Artwork.swift Tests/ArtworkTests.swift -o build/artwork-tests
build/artwork-tests
# Pairing remains entirely user-controlled; write scope is validated by tests above.
if [ -f 'dist/WalletSkin Studio.app/Contents/Resources/bin/device_helper' ]; then
 if nm -u 'dist/WalletSkin Studio.app/Contents/Resources/bin/device_helper' | rg 'AMDevicePair$'; then
   echo 'Unexpected automatic pairing symbol' >&2; exit 1
 fi
fi
