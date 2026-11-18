#!/bin/sh
# Builds ClaudeBar, installs the Claude Code hooks, and (optionally) starts it at login.
#   ./install.sh            build + hooks + launch
#   ./install.sh --login    also start ClaudeBar automatically when you log in
#   ./install.sh --uninstall
set -e
cd "$(dirname "$0")"
HOOK_DIR="$HOME/.claude/claudebar"
SETTINGS="$HOME/.claude/settings.json"
AGENT="$HOME/Library/LaunchAgents/com.claudebar.app.plist"

if [ "$1" = "--uninstall" ]; then
  python3 - "$SETTINGS" remove <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
hooks = s.get("hooks", {})
for ev in list(hooks):
    hooks[ev] = [g for g in hooks[ev] if not any("claudebar-hook" in h.get("command", "") for h in g.get("hooks", []))]
    if not hooks[ev]: del hooks[ev]
if not hooks: s.pop("hooks", None)
if "claudebar" in s.get("statusLine", {}).get("command", ""): s.pop("statusLine")
json.dump(s, open(p, "w"), indent=2)
PY
  launchctl unload "$AGENT" 2>/dev/null || true
  rm -f "$AGENT"; pkill -x ClaudeBar || true
  rm -rf "$HOOK_DIR"
  echo "ClaudeBar removed."
  exit 0
fi

./build.sh
mkdir -p "$HOOK_DIR"
cp hooks/claudebar-hook.sh "$HOOK_DIR/claudebar-hook.sh"
chmod +x "$HOOK_DIR/claudebar-hook.sh"
cp hooks/claudebar-statusline.sh "$HOOK_DIR/claudebar-statusline.sh"
chmod +x "$HOOK_DIR/claudebar-statusline.sh"

[ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.claudebar-backup"
python3 - "$SETTINGS" <<'PY'
import json, os, sys
p = sys.argv[1]
s = json.load(open(p)) if os.path.exists(p) else {}
cmd = lambda st: '"$HOME/.claude/claudebar/claudebar-hook.sh" ' + st
wanted = [
    ("SessionStart", None, "idle"),
    ("UserPromptSubmit", None, "working"),
    ("PreToolUse", "*", "working"),
    ("PostToolUse", "*", "working"),
    ("Notification", "permission_prompt", "waiting"),
    ("Stop", None, "done"),
    ("SessionEnd", None, "end"),
]
hooks = s.setdefault("hooks", {})
for ev, matcher, st in wanted:
    groups = [g for g in hooks.get(ev, []) if not any("claudebar-hook" in h.get("command", "") for h in g.get("hooks", []))]
    g = {"hooks": [{"type": "command", "command": cmd(st), "timeout": 5}]}
    if matcher: g = {"matcher": matcher, **g}
    groups.append(g)
    hooks[ev] = groups
# Status line: only claim it if you don't already have one (it prints nothing).
if "statusLine" not in s:
    s["statusLine"] = {"type": "command", "command": '"$HOME/.claude/claudebar/claudebar-statusline.sh"'}
elif "claudebar" not in s["statusLine"].get("command", ""):
    print("You already have a statusLine, so plan usage % won't be shown on the Touch Bar.")
json.dump(s, open(p, "w"), indent=2)
print("Hooks installed in", p)
PY

if [ "$1" = "--login" ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.claudebar.app</string>
  <key>ProgramArguments</key><array><string>$(pwd)/build/ClaudeBar.app/Contents/MacOS/ClaudeBar</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  launchctl unload "$AGENT" 2>/dev/null || true
  launchctl load "$AGENT"
  echo "ClaudeBar will start at login."
fi

pkill -x ClaudeBar 2>/dev/null || true
sleep 0.5
open build/ClaudeBar.app
echo "ClaudeBar is running. Look at your Touch Bar."
