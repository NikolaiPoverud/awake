#!/bin/sh
# Builds Awake.app from source, installs it to ~/Applications and starts it.
# A local build is not quarantined, so Gatekeeper does not block it. No Apple developer account needed.
set -e
cd "$(dirname "$0")"
app=build/Awake.app
[ -d "$app" ] && find "$app" -delete
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources" && cp ops-glance.py "$app/Contents/Resources/"
swiftc -O main.swift -o "$app/Contents/MacOS/Awake"
codesign -s - --force "$app"
pkill -x Awake 2>/dev/null || true
mkdir -p ~/Applications
[ -d ~/Applications/Awake.app ] && find ~/Applications/Awake.app -delete
cp -R "$app" ~/Applications/
open ~/Applications/Awake.app
echo "Awake is running. Move the pointer to the notch."
