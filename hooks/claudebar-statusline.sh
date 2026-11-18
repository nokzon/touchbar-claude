#!/bin/sh
# ClaudeBar status line: saves what Claude Code passes to status lines (plan usage limits,
# cost, context) so the Touch Bar details view can show it. Prints nothing, so the
# status line itself stays empty.
dir="$HOME/.claude/claudebar/status"
mkdir -p "$dir" 2>/dev/null
input=$(cat)
sid=$(printf '%s' "$input" | plutil -extract session_id raw -o - - 2>/dev/null || true)
case "$sid" in *"Could not extract"*|"") sid=default ;; esac
sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9_-')
printf '%s' "$input" > "$dir/$sid.tmp" && mv -f "$dir/$sid.tmp" "$dir/$sid.json"
exit 0
