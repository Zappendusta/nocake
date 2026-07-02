# NoCake 🤖🍰

Invisible macOS background app that blocks all keyboard input on demand, so a
coworker can't sit at your unlocked Mac and volunteer you for cake duty in Teams
while your agents run.

- **Armed:** every keystroke is swallowed and a popup shows your message. Toggle
  with **cmd+opt+ctrl+F10**.
- **Disarmed:** invisible. No Dock icon, no menu-bar icon, ~0 CPU.
- **You can't lock yourself out**, three ways:
  1. The mouse is never blocked — always click Force Quit / Activity Monitor.
  2. Disarm chord is detected inside the tap: **cmd+opt+ctrl+F10** OR
     **cmd+opt+ctrl+Escape** (Escape always works; F10 is a mute key on some Macs).
  3. Auto-disarms after 5 minutes no matter what.

## Install

```bash
brew install Zappendusta/nocake/nocake
brew services start nocake      # run in background, start at login
```

Builds from source (no notarization). Each `brew upgrade` = new binary identity,
so macOS re-asks for both permissions after upgrading.

## Build from source directly

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
3. Keyboard is dead; typing shows your popup. Press the combo again to disarm —
   or **cmd+opt+ctrl+Escape** if F10 is a media key on your keyboard.

If F10 does nothing: your F-row is in media mode. Either use the Escape chord, or
enable System Settings → Keyboard → "Use F1, F2, etc. as standard function keys."

## Configure

Message, combo, Escape failsafe, and dead-man timeout are configurable — no rebuild.

```bash
nocake configure     # guided wizard: prompts, live-captures your combo, restarts
```

Or hand-edit `~/.config/nocake/config.json`:

```json
{
  "message": "Not today. Agents running. Bring your own cake 🤖🍰",
  "toggleKeyCode": 109,
  "toggleModifiers": ["cmd", "opt", "ctrl"],
  "escapeFailsafe": true,
  "deadManMinutes": 5
}
```

Bad or missing values fall back to defaults (logged). Your arm/disarm combo is
always a keyboard exit (F-keys allowed — hold Fn if your F-row is in media mode);
the Escape failsafe and dead-man timer are optional extras. **You can never lock
yourself out:** the mouse is never blocked, so a Force-Quit click always works no
matter what you configure.

Edit the message, emoji, and timeout at the top of `main.swift`, then rebuild.

## Known gaps

- **Password fields stay typeable while armed.** macOS Secure Input routes those
  keys past the tap. This is intentional (and a safety feature) — not blockable
  from an external app. If Secure Input gets stuck on, the tap goes deaf: use the
  mouse to Force Quit, or wait out the 5-minute dead-man.
- Locking the screen or force-quitting always releases the keyboard.

## Roadmap

- Optional: notarized `.app` + DMG on GitHub Releases for a click-to-install
  path (the Homebrew tap already covers CLI install without signing).
