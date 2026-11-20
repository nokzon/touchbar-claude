# Touchbar Claude

A little pixel Claude critter on your MacBook Touch Bar that shows what Claude Code is doing.

| Claude Code is…            | Touch Bar shows                                              |
|----------------------------|--------------------------------------------------------------|
| waiting for your prompt    | **Ready**: breathes, blinks, looks around                    |
| working (thinking / tools) | **Building…**: hammers a brick wall, with the current tool and elapsed time |
| asking for permission      | **Needs you**: waves with a "!" bubble                       |
| finished                   | **Done!**: stomps with confetti, then waves a checkered finish flag |

After 1 minute of "Done" it goes back to Ready.

## Running it

The Claude Code hooks only need installing once, and they stay installed. After that:

- **Start it** (for example after restarting your Mac): `open "build/Touchbar Claude.app"`
- **Start it automatically at login:** `./install.sh --login` (one time)
- **After changing the code:** `./build.sh`, then quit Touchbar Claude from its menu bar icon and open it again
- **Stop it:** menu bar icon → Quit Touchbar Claude
- **Preview an animation:** menu bar icon → Preview animation

## Install

```bash
./install.sh            # build, add Claude Code hooks, launch
./install.sh --login    # same, and start Touchbar Claude automatically at login
./install.sh --uninstall
```

The installer backs up `~/.claude/settings.json` to `settings.json.claudebar-backup` first.

## How it works

- `hooks/claudebar-hook.sh` runs on Claude Code hook events (SessionStart, UserPromptSubmit,
  Pre/PostToolUse, Notification `permission_prompt`, Stop, SessionEnd) and writes one small
  file per session to `~/.claude/claudebar/sessions/`.
- `Touchbar Claude.app` reads those files and draws the mascot procedurally at 30 fps (rectangles
  only, GSAP-style easing, sprite-style stepped frames for the stomp and the flag). The idea
  comes from the Codrops article "Reverse-Engineering Claude AI's Mascot Animations with SVG and GSAP".
- It uses the same private Touch Bar API that Pock and MTMR use, so it works on top of any app.
  A mini mascot lives in the Control Strip; tap it to bring the full bar back after closing it with ✕.
- Menu bar icon: show or hide it, turn pop-up-on-change on or off, and preview each animation.

## Details (tap the mascot)

Tap the bar (or the mini mascot in the Control Strip) to see, for the current session:
**model + effort**, **context used** (e.g. 173k/200k, with a gauge), **plan usage** (5-hour % with
time until reset, plus weekly %), and **project + session length**. It flips back after 15 s, or tap again.

Model, context and session info come from the session transcript. Plan usage comes from a
status line script (`claudebar-statusline.sh`, which prints nothing). Claude Code only sends usage
limits to status lines, and only on Pro/Max plans. When there's no usage data, the bar shows
tokens written instead. If you already have your own status line, the installer leaves it alone.

Multiple sessions: "Needs you" wins, then "Building", then "Done".
