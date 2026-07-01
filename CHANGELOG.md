# Changelog

## v1.0.0 — 2026-07-01

First release. Invisible macOS keyboard-lock deterrent.

- Arm/disarm with cmd+opt+ctrl+F10 (or cmd+opt+ctrl+Escape).
- Armed: `CGEventTap` swallows all keyboard input, shows a popup with your message.
- Disarmed: `LSUIElement` agent, no Dock/menu-bar icon, ~0 cost.
- Anti-lockout: mouse never blocked, disarm chord detected inside the tap,
  keyboard-independent Escape fallback, 5-minute dead-man auto-disarm.
- `--selftest` covers the lockout-critical disarm predicate.
