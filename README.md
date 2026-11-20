
# Touchbar Claude

A little Claude guy on your MacBook Touch Bar that shows what Claude Code is doing, with the states:
#### Ready
<img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 11 59 PM" src="https://github.com/user-attachments/assets/058f16f5-76c1-4f45-9292-b77e7c42cda8" />

#### Building
<img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 12 16 PM" src="https://github.com/user-attachments/assets/f3cc5c26-6fd3-4e77-859f-e0691de239e5" />

#### Needs you 
<img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 14 10 PM" src="https://github.com/user-attachments/assets/0b59dc49-53f1-4e6f-96f6-c5e7075de15d" />

#### Done
<img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 12 22 PM" src="https://github.com/user-attachments/assets/a2861c89-4eed-4410-bb4d-6cda91e292b5" /><img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 12 19 PM" src="https://github.com/user-attachments/assets/7c75d239-2dea-45ea-bd3e-bbdf167442d4" />

#### It also shows more information by tapping on the Claude icon
<img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 14 20 PM" src="https://github.com/user-attachments/assets/3831dce5-7ea0-47c0-8e76-859f89dd1ff4" />


## Running it

The Claude Code hooks only need installing once, and they stay installed. After that:

- **Start it** (for example after restarting your Mac): `open "build/Touchbar Claude.app"`
- **Start it automatically at login:** `./install.sh --login` (one time)
- **After changing the code:** `./build.sh`, then quit Touchbar Claude from its menu bar icon and open it again
- **Stop it:** menu bar icon → Quit Touchbar Claude
<img width="307" height="233" alt="image" src="https://github.com/user-attachments/assets/55aa0922-937b-41c1-bb30-450b2f58749b" />

- **Preview an animation:** menu bar icon → Preview animation

## Install

```bash
./install.sh            # build, add Claude Code hooks, launch
./install.sh --login    # same, and start Touchbar Claude automatically at login
./install.sh --uninstall
```

The installer backs up `~/.claude/settings.json` to `settings.json.claudebar-backup` first.
