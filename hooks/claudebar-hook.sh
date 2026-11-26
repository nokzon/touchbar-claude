#!/bin/sh
# Touchbar Claude hook: records what each Claude Code session is doing.
# Usage (from Claude Code hooks): claudebar-hook.sh idle|working|waiting|done|end
# Writes ~/.claude/claudebar/sessions/<session_id> as: state since workStart updated tool
# Must stay silent on stdout (UserPromptSubmit output would be added to the prompt).

state="$1"
dir="$HOME/.claude/claudebar/sessions"
mkdir -p "$dir" 2>/dev/null

input=$(cat)
field() { printf '%s' "$input" | plutil -extract "$1" raw -o - - 2>/dev/null || true; }
sid=$(field session_id)
case "$sid" in *"Could not extract"*) sid="" ;; esac
tool=$(field tool_name)
case "$tool" in *"Could not extract"*) tool="" ;; esac
tool=$(printf '%s' "$tool" | tr -cd 'A-Za-z0-9_.-')
[ -z "$sid" ] && sid=default
sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9_-')
f="$dir/$sid"

# Remember where this session's transcript lives (the app reads model + token usage from it).
meta="$HOME/.claude/claudebar/meta"
transcript=$(field transcript_path); case "$transcript" in *"Could not extract"*) transcript="" ;; esac
cwd=$(field cwd); case "$cwd" in *"Could not extract"*) cwd="" ;; esac
if [ -n "$transcript" ] && [ "$state" != "end" ]; then
  mkdir -p "$meta" 2>/dev/null
  # Lines 3-4: the app hosting this session (so tapping the bar can bring it forward).
  # Worked out once per session: bundle id the app passed down, and our ancestor pids.
  app=""; chain=""
  if [ -f "$meta/$sid" ]; then
    app=$(sed -n 3p "$meta/$sid"); chain=$(sed -n 4p "$meta/$sid")
  fi
  if [ -z "$chain" ]; then
    app=$(printf '%s' "${__CFBundleIdentifier:-}" | tr -cd 'A-Za-z0-9._-')
    p=$PPID; i=0
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ $i -lt 15 ]; do
      chain="$chain $p"
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
      i=$((i + 1))
    done
    chain=${chain# }
  fi
  printf '%s\n%s\n%s\n%s\n' "$transcript" "$cwd" "$app" "$chain" > "$meta/$sid"
fi

if [ "$state" = "end" ]; then
  rm -f "$f" "$HOME/.claude/claudebar/meta/$sid"
  exit 0
fi

now=$(date +%s)
pstate=""; psince=$now; pwork=$now
if [ -f "$f" ]; then
  read -r pstate psince pwork _rest < "$f"
fi

since=$now; work=$now
case "$state" in
  working)
    if [ "$pstate" = "working" ] || [ "$pstate" = "waiting" ]; then work=$pwork; fi
    [ "$pstate" = "working" ] && since=$psince
    ;;
  waiting|done)
    if [ "$pstate" = "working" ] || [ "$pstate" = "waiting" ]; then work=$pwork; fi
    [ "$pstate" = "$state" ] && since=$psince
    ;;
esac

printf '%s %s %s %s %s\n' "$state" "$since" "$work" "$now" "$tool" > "$f.tmp" && mv -f "$f.tmp" "$f"
exit 0
