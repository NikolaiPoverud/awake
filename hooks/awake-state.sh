#!/bin/sh
# Awake: records if this Claude Code session is working, so Awake keeps the Mac awake
# only while a session works. Arg: busy | idle | end. Writes "<state> <claude pid>" to ~/.claude/awake/<session>.
# $PPID is the claude process: sh -c execs a single command, so this script is its direct child.
d="$HOME/.claude/awake"
mkdir -p "$d"
sid=$(sed -n 's/.*"session_id" *: *"\([A-Za-z0-9_-]*\)".*/\1/p' | head -1)
[ -n "$sid" ] || exit 0
if [ "$1" = end ]; then rm -f "$d/$sid"; else printf '%s %s\n' "$1" "$PPID" > "$d/$sid"; fi
exit 0
