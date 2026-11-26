# Touchbar Claude

A little Claude guy on your MacBook Touch Bar that shows what Claude Code is doing!

## What it shows

#### Ready
<img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 11 59 PM" src="https://github.com/user-attachments/assets/058f16f5-76c1-4f45-9292-b77e7c42cda8" />

#### Building
<img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 12 16 PM" src="https://github.com/user-attachments/assets/f3cc5c26-6fd3-4e77-859f-e0691de239e5" />

#### Needs you
<img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 14 10 PM" src="https://github.com/user-attachments/assets/0b59dc49-53f1-4e6f-96f6-c5e7075de15d" />

#### Done
<img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 12 22 PM" src="https://github.com/user-attachments/assets/a2861c89-4eed-4410-bb4d-6cda91e292b5" /><img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 12 19 PM" src="https://github.com/user-attachments/assets/7c75d239-2dea-45ea-bd3e-bbdf167442d4" />

## Tap and hold

- **Tap** the mascot to jump back to your Claude session.
- **Hold** the mascot to see more: the model, how much context is used, and your usage limits.

<img width="1085" height="30" alt="Touch Bar Shot 2026-11-20 at 5 14 20 PM" src="https://github.com/user-attachments/assets/3831dce5-7ea0-47c0-8e76-859f89dd1ff4" />

## Install

Open Terminal and go to the project folder:
```bash
cd path/to/touchbar-claude
```

Run the installer. It builds the app, sets up the Claude Code hooks and starts it:
```bash
./install.sh
```

To have it start on its own every time you log in, run this once instead:
```bash
./install.sh --login
```

## Everyday use

You only need to install once. After that:

- **Start it** (for example after restarting your Mac): `open "build/Touchbar Claude.app"`
- **After changing the code:** `./build.sh`, then quit Touchbar Claude from its menu bar icon and open it again
- **Preview an animation:** menu bar icon → Preview animation
- **Stop it:** menu bar icon → Quit Touchbar Claude

<img width="307" height="233" alt="image" src="https://github.com/user-attachments/assets/55aa0922-937b-41c1-bb30-450b2f58749b" />

## Uninstall
```bash
./install.sh --uninstall
```
