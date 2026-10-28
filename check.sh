#!/bin/sh
# Checks install-hooks.sh and the hook script against a throwaway HOME. Your real settings are not touched.
set -e
cd "$(dirname "$0")"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/.claude"
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}' > "$t/.claude/settings.json"

HOME="$t" ./install-hooks.sh >/dev/null
HOME="$t" ./install-hooks.sh >/dev/null   # second run must change nothing
n=$(jq '[.hooks[][].hooks[].command | select(test("awake-state"))] | length' "$t/.claude/settings.json")
[ "$n" = 6 ] || { echo "FAIL: expected 6 Awake hooks, got $n"; exit 1; }
jq -e '.hooks.Stop[0].hooks[0].command == "/bin/true"' "$t/.claude/settings.json" >/dev/null \
  || { echo "FAIL: existing hook was lost"; exit 1; }

echo '{"session_id":"abc-1"}' | HOME="$t" sh -c "$t/.claude/hooks/awake-state.sh busy"
[ "$(cut -d' ' -f1 "$t/.claude/awake/abc-1")" = busy ] || { echo "FAIL: busy not written"; exit 1; }
echo '{"session_id":"abc-1"}' | HOME="$t" "$t/.claude/hooks/awake-state.sh" end
[ ! -e "$t/.claude/awake/abc-1" ] || { echo "FAIL: end did not remove the file"; exit 1; }
echo "OK"
