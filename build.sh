#!/bin/sh
# Builds Awake.app from source, installs it to ~/Applications and starts it.
# A local build is not quarantined, so Gatekeeper does not block it. No Apple developer account needed.
set -e
cd "$(dirname "$0")"
app=build/Awake.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
swiftc -O main.swift -o "$app/Contents/MacOS/Awake"
codesign -s - --force "$app"
pkill -x Awake 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Awake.app
cp -R "$app" ~/Applications/
open ~/Applications/Awake.app
echo "Awake is running. Move the pointer to the notch."
