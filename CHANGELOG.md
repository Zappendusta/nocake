# Changelog

## v1.1.0 — 2026-07-02

- Configurable message, arm/disarm combo, Escape failsafe, and dead-man timeout
  via `~/.config/nocake/config.json` — no rebuild needed.
- New `nocake configure` wizard: prompts, live-captures your combo, writes the
  config, and restarts the running app (brew services or manual launch).
- Your arm/disarm combo is always a keyboard exit (F-keys allowed — hold Fn if
  your F-row is in media mode). Escape failsafe and dead-man are optional extras.
  The mouse is never blocked, so Force-Quit always works no matter the config.
  Closes #1.

## v1.0.1 — 2026-07-01

- MIT license.
- Install via Homebrew: `brew install Zappendusta/nocake/nocake` (build-from-source
  tap at [homebrew-nocake](https://github.com/Zappendusta/homebrew-nocake), no
  notarization). `brew services start nocake` for background/launch-at-login.

## v1.0.0 — 2026-07-01

First release. Invisible macOS keyboard-lock deterrent.

- Arm/disarm with cmd+opt+ctrl+F10 (or cmd+opt+ctrl+Escape).
- Armed: `CGEventTap` swallows all keyboard input, shows a popup with your message.
- Disarmed: `LSUIElement` agent, no Dock/menu-bar icon, ~0 cost.
- Anti-lockout: mouse never blocked, disarm chord detected inside the tap,
  keyboard-independent Escape fallback, 5-minute dead-man auto-disarm.
- `--selftest` covers the lockout-critical disarm predicate.
