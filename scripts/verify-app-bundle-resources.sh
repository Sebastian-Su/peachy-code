#!/bin/bash
set -euo pipefail

APP="${1:?usage: scripts/verify-app-bundle-resources.sh /path/to/PeachyPet.app}"
EXECUTABLE="$APP/Contents/MacOS/PeachyPet"

for resource in \
  Contents/Resources/Defaults \
  Contents/Resources/Extensions \
  Contents/Resources/Fonts \
  Contents/Resources/Images \
  Contents/Resources/en.lproj/Localizable.strings \
  Contents/Resources/zh.lproj/Localizable.strings; do
  if [ ! -e "$APP/$resource" ]; then
    echo "ERROR: standalone app resource is missing: $APP/$resource" >&2
    exit 1
  fi
done

if strings "$EXECUTABLE" | grep -q "could not load resource bundle"; then
  echo "ERROR: app executable still depends on SwiftPM build-time resources" >&2
  exit 1
fi

echo "Standalone app resources verified: $APP"
