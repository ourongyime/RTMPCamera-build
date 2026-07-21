#!/bin/bash
# build_all.sh - Build all 3 GreenCam test tweaks
set -e

if [ -z "" ]; then
    echo "ERROR: THEOS environment variable not set"
    exit 1
fi

DIRS=("green-cfunc" "green-swizzle" "green-nsobject")

for d in ""; do
    echo "=== Building  ==="
    (cd "" && make package)
    echo "===  done ==="
done

echo ""
echo "All builds complete!"
echo "Packages:"
find . -name "*.deb" -type f
