# NoCake 🤖🍰

Invisible macOS background app that blocks all keyboard input on demand, so a
coworker can't sit at your unlocked Mac and volunteer you for cake duty in Teams
while your agents run.

- **Armed:** every keystroke is swallowed and a popup shows your message. Toggle
  with **cmd+opt+ctrl+F10**.
- **Disarmed:** invisible. No Dock icon, no menu-bar icon, ~0 CPU.
- **You can't lock yourself out:** the mouse is never blocked (always click to
  Force Quit), the toggle is detected inside the key tap, and it auto-disarms
  after 5 minutes.

## Build

```bash
./build.sh          # produces NoCake.app
open NoCake.app
```

## Permissions (one-time)

Blocking keys needs **two** grants. macOS will prompt on first arm; if the tap
doesn't work, enable them manually:

- System Settings → Privacy & Security → **Accessibility** → add NoCake.app
- System Settings → Privacy & Security → **Input Monitoring** → add NoCake.app

**After any rebuild**, macOS may silently disable these (the grant is keyed to the
binary). Re-check both toggles if arming stops working.

## Use

1. `open NoCake.app` — it runs invisibly.
2. Step away with agents running → press **cmd+opt+ctrl+F10** to arm.
3. Keyboard is dead; typing shows your popup. Press the combo again to disarm.

Edit the message, emoji, and timeout at the top of `main.swift`, then rebuild.

## Known gaps

- **Password fields stay typeable while armed.** macOS Secure Input routes those
  keys past the tap. This is intentional (and a safety feature) — not blockable
  from an external app.
- Locking the screen or force-quitting always releases the keyboard.

## Roadmap

- Notarized `.app` + DMG on GitHub Releases.
- `brew install --cask nocake` once there's a signed release.
