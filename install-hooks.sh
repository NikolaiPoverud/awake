#!/bin/sh
# Adds the Claude Code hooks that tell Awake when a session is working.
# Backs up ~/.claude/settings.json first. Safe to run twice. Needs jq.
set -e
cd "$(dirname "$0")"
command -v jq >/dev/null || { echo "jq is missing. Install it with: brew install jq"; exit 1; }

hook="$HOME/.claude/hooks/awake-state.sh"
settings="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude/hooks"
cp hooks/awake-state.sh "$hook"
chmod +x "$hook"
[ -f "$settings" ] || echo '{}' > "$settings"

if jq -e '[.hooks[]?[]?.hooks[]?.command] | any(test("awake-state"))' "$settings" >/dev/null; then
  echo "Hooks are already installed."
  exit 0
fi

cp "$settings" "$settings.bak-awake-$(date +%Y%m%d%H%M%S)"
jq --arg h "$hook" '
  def add(ev; m; arg): .hooks[ev] = ((.hooks[ev] // []) +
    [({hooks: [{type: "command", command: ($h + " " + arg)}]} + (if m then {matcher: m} else {} end))]);
  add("UserPromptSubmit"; null; "busy") | add("PreToolUse"; null; "busy") | add("PostToolUse"; null; "busy")
  | add("Stop"; null; "idle") | add("Notification"; "permission_prompt|idle_prompt"; "idle")
  | add("SessionEnd"; null; "end")' "$settings" > "$settings.new"
jq empty "$settings.new"
mv "$settings.new" "$settings"
echo "Hooks installed. A backup of your old settings is next to $settings."
