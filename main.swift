// NoCake — invisible keyboard-lock deterrent for macOS.
// Armed: swallows ALL keyboard input, shows a popup. Disarmed: invisible, ~0 cost.
// Toggle: cmd+opt+ctrl+F10. See README for the Accessibility + Input Monitoring grants.
//
// Anti-lockout guarantees (in priority order):
//   1. Keyboard-only tap never blocks the mouse -> can always click Force Quit.
//   2. Toggle is detected INSIDE the tap callback (a tap sits upstream of Carbon
//      dispatch, so Carbon can't be an unswallowable escape while armed).
//   3. Dead-man timeout auto-disarms after DEAD_MAN_MINUTES.

import AppKit
import Carbon.HIToolbox

// ---- tunables (edit + rebuild to change) --------------------------------
let MESSAGE = "Not today. Agents running. Bring your own cake"
let EMOJI = "🤖🍰"
let DEAD_MAN_MINUTES = 5.0        // auto-disarm backstop (short on purpose)
let POPUP_SECONDS = 2.0           // how long the popup stays up
let DEBOUNCE_SECONDS = 2.0        // min gap between popups when keys are mashed
let TOGGLE_KEYCODE = UInt16(kVK_F10)
// -------------------------------------------------------------------------

/// Pure predicate: is this the cmd+opt+ctrl+F10 toggle? Kept pure so the
/// lockout-critical logic is testable via `--selftest`.
func isToggle(keycode: UInt16, flags: CGEventFlags) -> Bool {
    guard keycode == TOGGLE_KEYCODE else { return false }
    return flags.contains(.maskCommand)
        && flags.contains(.maskAlternate)
        && flags.contains(.maskControl)
}

final class Controller {
    static let shared = Controller()

    private var armed = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotKeyRef: EventHotKeyRef?
    private var deadMan: Timer?
    private var lastPopup = Date.distantPast
    private let panel = PopupPanel()

    // ---- arm / disarm ----------------------------------------------------
    func arm() {
        guard !armed else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // .defaultTap = can swallow
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in Controller.shared.handle(type: type, event: event) },
            userInfo: nil
        ) else {
            // Tap refused -> missing Accessibility/Input Monitoring. Stay disarmed.
            NSLog("NoCake: could not create event tap (grant Accessibility + Input Monitoring)")
            return
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        armed = true
        deadMan = Timer.scheduledTimer(withTimeInterval: DEAD_MAN_MINUTES * 60, repeats: false) { _ in
            Controller.shared.disarm()
        }
        NSLog("NoCake: armed")
    }

    func disarm() {
        guard armed else { return }
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil; runLoopSource = nil
        deadMan?.invalidate(); deadMan = nil
        panel.hide()
        armed = false
        NSLog("NoCake: disarmed")
    }

    // ---- the tap callback ------------------------------------------------
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disabled the tap (timeout / heavy input). Re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        if type == .keyDown {
            let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if isToggle(keycode: keycode, flags: event.flags) {
                DispatchQueue.main.async { self.disarm() }
                return nil                 // swallow the toggle itself
            }
            DispatchQueue.main.async { self.showPopup() }
        }
        return nil                         // swallow everything (keyDown + flagsChanged)
    }

    private func showPopup() {
        let now = Date()
        guard now.timeIntervalSince(lastPopup) > DEBOUNCE_SECONDS else { return }
        lastPopup = now
        panel.show(text: "\(EMOJI)\n\(MESSAGE)", seconds: POPUP_SECONDS)
    }

    // ---- always-alive arming hotkey (Carbon) -----------------------------
    // Only fires while disarmed (no tap installed). Once armed, the tap
    // intercepts the combo upstream and Carbon never sees it.
    func installArmingHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Controller.shared.arm()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4E434B45), id: 1)   // 'NCKE'
        RegisterEventHotKey(UInt32(TOGGLE_KEYCODE),
                            UInt32(cmdKey | optionKey | controlKey),
                            id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

/// Borderless, non-activating floating panel. Never steals focus.
final class PopupPanel {
    private var panel: NSPanel?
    private var hideTimer: Timer?

    func show(text: String, seconds: Double) {
        if panel == nil { build() }
        guard let panel = panel, let label = panel.contentView?.subviews.first as? NSTextField else { return }
        label.stringValue = text
        if let screen = NSScreen.main {
            let f = panel.frame
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - f.width / 2,
                                         y: screen.frame.midY - f.height / 2))
        }
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        panel?.orderOut(nil)
    }

    private func build() {
        let rect = NSRect(x: 0, y: 0, width: 460, height: 140)
        let p = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let content = NSView(frame: rect)
        content.wantsLayer = true
        content.layer?.cornerRadius = 18
        content.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: "")
        label.frame = rect.insetBy(dx: 24, dy: 24)
        label.alignment = .center
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        content.addSubview(label)
        p.contentView = content
        panel = p
    }
}

// ---- selftest (lockout-critical predicate) ------------------------------
if CommandLine.arguments.contains("--selftest") {
    let all: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
    assert(isToggle(keycode: UInt16(kVK_F10), flags: all), "full combo must match")
    assert(!isToggle(keycode: UInt16(kVK_F10), flags: [.maskCommand, .maskControl]), "missing option must NOT match")
    assert(!isToggle(keycode: UInt16(kVK_ANSI_A), flags: all), "wrong key must NOT match")
    assert(!isToggle(keycode: UInt16(kVK_F10), flags: []), "no modifiers must NOT match")
    print("selftest OK")
    exit(0)
}

// ---- launch (invisible agent) -------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.accessory)     // no Dock icon, no menu bar
Controller.shared.installArmingHotKey()
NSLog("NoCake: running (disarmed). Press cmd+opt+ctrl+F10 to arm.")
app.run()
