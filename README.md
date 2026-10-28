# Awake

Keeps your Mac awake while Claude Code is working. Lets it sleep when Claude waits for you.

Awake lives behind the notch. Move the pointer to the notch and a small panel drops down. Move away and it hides.

## What it does

- **With Claude.** While any Claude Code session works, the Mac does not sleep. The display still turns off and the screen still locks. When every session is idle or waits for your reply, Awake lets go.
- **Manual mode.** Click the cup to keep the Mac awake until you turn it off, or pick 15 min, 30 min, 1 h, 2 h or 4 h.
- **Battery guard.** On battery at 20% or less, Awake turns itself off.
- **Display on.** Choose if manual mode keeps the screen on too.

One Swift file. No dependencies. About 300 lines.

## Install

Needs macOS 14 or later and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/NikolaiPoverud/awake.git
cd awake
./build.sh          # builds Awake.app, puts it in ~/Applications and starts it
./install-hooks.sh  # adds the Claude Code hooks (needs jq)
```

You build it on your own Mac, so macOS does not block it. To start it when you log in, open the panel and click **At login**.

## How "With Claude" works

`install-hooks.sh` adds a small hook, `~/.claude/hooks/awake-state.sh`, to your Claude Code settings. It backs up `~/.claude/settings.json` first and keeps your other hooks.

| Claude Code event | State written |
|---|---|
| You send a prompt, a tool runs | `busy` |
| Claude stops, or waits for a permission or your reply | `idle` |
| The session ends | file removed |

Each session writes one line to `~/.claude/awake/<session id>`. Awake reads that folder every 15 seconds. It holds a "prevent idle system sleep" assertion while any live session is busy. Check it with:

```sh
pmset -g assertions | grep Claude
```

## Limits

- Closing the lid sleeps the Mac anyway, unless an external display is connected.
- Esc-interrupt fires no hook, so a session can stay "busy". Awake ignores a busy file that has not changed for 30 minutes. A tool call refreshes it.
- Awake checks the pointer position 20 times a second to open the panel. It uses close to 0% CPU and needs no Accessibility permission.

## Remove

Quit from the panel, delete `~/Applications/Awake.app`, and remove the six `awake-state.sh` entries from `~/.claude/settings.json`.

## Check

`./check.sh` runs the hook installer twice and the hook script against a throwaway home folder. It never touches your real settings.

## License

MIT
