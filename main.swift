// NoCake — invisible macOS keyboard-lock deterrent.
// Armed: swallows ALL keyboard input, shows a popup. Disarmed: invisible, ~0 cost.
// Config: ~/.config/nocake/config.json (or run `nocake configure`).
//
// Anti-lockout: the mouse is never blocked (keyboard-only tap) — architectural,
// always an exit. On top of that, the exit invariant guarantees at least one of
// {reliable primary combo, +Escape failsafe, dead-man timer} is always active;
// a config that would leave zero is healed to escapeFailsafe on.

import AppKit
import Carbon.HIToolbox
import Darwin
import ApplicationServices
import IOKit.hid

// ---- defaults -----------------------------------------------------------
let DEFAULT_MESSAGE = "Not today. Agents running. Bring your own cake 🤖🍰"
let DEFAULT_KEYCODE = UInt16(kVK_F10)
let DEFAULT_MODS: Set<String> = ["cmd", "opt", "ctrl"]
let DEFAULT_DEADMAN = 5
let DEFAULT_ESCAPE = true
let POPUP_SECONDS = 2.0
let DEBOUNCE_SECONDS = 2.0
let MESSAGE_MAX = 200

// F1-F12 virtual keycodes — may act as media keys without Fn, so an F-key is
// NOT a reliable sole exit.
let FKEY_CODES: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

// ---- modifier mapping ---------------------------------------------------
/// Parse config modifier tokens. Case-insensitive, aliases, deduped.
/// Returns (set, valid); valid=false if any token is unknown.
func parseModifiers(_ raw: [String]) -> (set: Set<String>, valid: Bool) {
    var out = Set<String>()
    var ok = true
    for t in raw {
        switch t.lowercased() {
        case "cmd", "command":       out.insert("cmd")
        case "opt", "alt", "option": out.insert("opt")
        case "ctrl", "control":      out.insert("ctrl")
        case "shift":                out.insert("shift")
        default:                     ok = false
        }
    }
    return (out, ok)
}

func cgFlags(_ mods: Set<String>) -> CGEventFlags {
    var f = CGEventFlags()
    if mods.contains("cmd")   { f.insert(.maskCommand) }
    if mods.contains("opt")   { f.insert(.maskAlternate) }
    if mods.contains("ctrl")  { f.insert(.maskControl) }
    if mods.contains("shift") { f.insert(.maskShift) }
    return f
}

func carbonMods(_ mods: Set<String>) -> UInt32 {
    var m: UInt32 = 0
    if mods.contains("cmd")   { m |= UInt32(cmdKey) }
    if mods.contains("opt")   { m |= UInt32(optionKey) }
    if mods.contains("ctrl")  { m |= UInt32(controlKey) }
    if mods.contains("shift") { m |= UInt32(shiftKey) }
    return m
}

/// Trigger the macOS permission dialogs for Accessibility + Input Monitoring.
/// A key-swallowing CGEventTap needs BOTH; without them arming silently no-ops.
func requestPermissions() {
    if !AXIsProcessTrusted() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
}

func modsFromFlags(_ f: CGEventFlags) -> Set<String> {
    var s = Set<String>()
    if f.contains(.maskCommand)   { s.insert("cmd") }
    if f.contains(.maskAlternate) { s.insert("opt") }
    if f.contains(.maskControl)   { s.insert("ctrl") }
    if f.contains(.maskShift)     { s.insert("shift") }
    return s
}

let MOD_ORDER = ["cmd", "opt", "ctrl", "shift"]
/// Canonical modifier order for display and storage (not alphabetical).
func orderedMods(_ mods: Set<String>) -> [String] { MOD_ORDER.filter { mods.contains($0) } }

// ---- config -------------------------------------------------------------
struct Config {
    var message: String
    var keyCode: UInt16
    var mods: Set<String>
    var escapeFailsafe: Bool
    var deadManMinutes: Int

    static let defaults = Config(message: DEFAULT_MESSAGE, keyCode: DEFAULT_KEYCODE,
                                 mods: DEFAULT_MODS, escapeFailsafe: DEFAULT_ESCAPE,
                                 deadManMinutes: DEFAULT_DEADMAN)
}

struct RawConfig: Codable {
    var message: String?
    var toggleKeyCode: Int?
    var toggleModifiers: [String]?
    var escapeFailsafe: Bool?
    var deadManMinutes: Int?
}

func configPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.config/nocake/config.json"
}

/// F-keys may act as media keys unless Fn is held — worth a heads-up, not a block.
func isFKey(_ keyCode: UInt16) -> Bool { FKEY_CODES.contains(keyCode) }

/// Load config with per-field validation (each bad field defaults independently).
/// The primary combo is always a valid keyboard exit; the mouse is never blocked
/// (keyboard-only tap), so Force-Quit is always available. Never throws.
func loadConfig() -> Config {
    var c = Config.defaults
    guard let data = FileManager.default.contents(atPath: configPath()) else { return c }
    guard let raw = try? JSONDecoder().decode(RawConfig.self, from: data) else {
        NSLog("NoCake: config.json unparseable — using defaults")
        return c
    }
    if let m = raw.message {
        let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            NSLog("NoCake: empty message — using default")
        } else if t.count > MESSAGE_MAX {
            c.message = String(t.prefix(MESSAGE_MAX))
            NSLog("NoCake: message >\(MESSAGE_MAX) chars — truncated")
        } else {
            c.message = t
        }
    }
    if let k = raw.toggleKeyCode {
        if k >= 0 && k <= 127 { c.keyCode = UInt16(k) }
        else { NSLog("NoCake: invalid toggleKeyCode \(k) — using default \(DEFAULT_KEYCODE)") }
    }
    if let rawMods = raw.toggleModifiers {
        let (set, ok) = parseModifiers(rawMods)
        if ok && !set.isEmpty { c.mods = set }
        else { NSLog("NoCake: invalid toggleModifiers \(rawMods) — using default") }
    }
    if let e = raw.escapeFailsafe { c.escapeFailsafe = e }
    if let d = raw.deadManMinutes {
        if d >= 0 { c.deadManMinutes = d }
        else { NSLog("NoCake: negative deadManMinutes \(d) — using default \(DEFAULT_DEADMAN)") }
    }
    return c
}

/// Disarm predicate. Primary combo (permissive: contains all configured mods) OR
/// the fixed cmd+opt+ctrl+Escape failsafe when enabled. Pure — tested.
func isToggle(keycode: UInt16, flags: CGEventFlags, config: Config) -> Bool {
    let needed = cgFlags(config.mods)
    if keycode == config.keyCode && flags.intersection(needed) == needed { return true }
    if config.escapeFailsafe && keycode == UInt16(kVK_Escape)
        && flags.contains(.maskCommand) && flags.contains(.maskAlternate) && flags.contains(.maskControl) {
        return true
    }
    return false
}

// ---- controller ---------------------------------------------------------
final class Controller {
    static let shared = Controller()

    let config = loadConfig()
    private var armed = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotKeyRef: EventHotKeyRef?
    private var deadMan: Timer?
    private var lastPopup = Date.distantPast
    private let panel = PopupPanel()

    func arm() {
        guard !armed else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in Controller.shared.handle(type: type, event: event) },
            userInfo: nil
        ) else {
            NSLog("NoCake: could not create event tap — needs Accessibility + Input Monitoring")
            // Make the silent failure visible + reopen the permission dialogs.
            panel.show(text: "NoCake needs permission ⚙️\nSystem Settings → Privacy & Security →\nAccessibility + Input Monitoring", seconds: 5)
            requestPermissions()
            return
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        armed = true
        if config.deadManMinutes > 0 {
            deadMan = Timer.scheduledTimer(withTimeInterval: Double(config.deadManMinutes) * 60,
                                           repeats: false) { _ in Controller.shared.disarm() }
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

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        if type == .keyDown {
            let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if isToggle(keycode: keycode, flags: event.flags, config: config) {
                DispatchQueue.main.async { self.disarm() }
                return nil
            }
            DispatchQueue.main.async { self.showPopup() }
        }
        return nil
    }

    private func showPopup() {
        let now = Date()
        guard now.timeIntervalSince(lastPopup) > DEBOUNCE_SECONDS else { return }
        lastPopup = now
        panel.show(text: config.message, seconds: POPUP_SECONDS)
    }

    // Always-alive arming hotkey (fires only while disarmed; the tap intercepts
    // the combo upstream once armed).
    func installArmingHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Controller.shared.arm(); return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4E434B45), id: 1)   // 'NCKE'
        let status = RegisterEventHotKey(UInt32(config.keyCode), carbonMods(config.mods),
                                         id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("NoCake: RegisterEventHotKey failed (\(status)) — arming shortcut won't work")
        }
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
        // Size the panel to the (possibly multi-line) text.
        let width: CGFloat = 520, inset: CGFloat = 28
        let textW = width - inset * 2
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: textW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: label.font as Any])
        let textH = ceil(bounds.height)
        let height = max(120, textH + inset * 2)
        panel.setContentSize(NSSize(width: width, height: height))
        label.frame = NSRect(x: inset, y: inset, width: textW, height: textH)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
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
        let rect = NSRect(x: 0, y: 0, width: 520, height: 140)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
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
        label.alignment = .center
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.maximumNumberOfLines = 0        // unlimited — full multi-line message
        label.lineBreakMode = .byWordWrapping
        content.addSubview(label)
        p.contentView = content
        panel = p
    }
}

// ---- configure wizard ---------------------------------------------------
// Live-capture globals (C event-tap callback can't capture Swift context).
var captureKeyCode: UInt16 = 0
var captureMods: Set<String> = []
var captureGot = false

func captureCombo(timeout: TimeInterval) -> (UInt16, Set<String>)? {
    // No Accessibility permission → tapping is pointless; skip fast (no hang).
    guard AXIsProcessTrusted() else { return nil }
    captureGot = false
    let sem = DispatchSemaphore(value: 0)
    // Run the tap + its runloop on a background thread. The MAIN thread waits on
    // the semaphore with a hard timeout, so it can never block past `timeout`
    // regardless of what the tap/runloop does.
    DispatchQueue.global().async {
        let mask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, _ in
                captureKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                captureMods = modsFromFlags(event.flags)
                captureGot = true
                CFRunLoopStop(CFRunLoopGetCurrent())
                return Unmanaged.passUnretained(event)
            }, userInfo: nil
        ) else { sem.signal(); return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()   // stopped by the callback on a keypress
        sem.signal()
    }
    let outcome = sem.wait(timeout: .now() + timeout)
    // Only trust the result on a clean signal (no read/write race with timeout).
    return (outcome == .success && captureGot) ? (captureKeyCode, captureMods) : nil
}

func prompt(_ q: String, default def: String) -> String {
    print("\(q) [\(def)]: ", terminator: "")
    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return def }
    return line
}

/// Read a multi-line message. Blank first line keeps `current`. Otherwise collect
/// lines (blank lines allowed within) until a line that is just "." or EOF.
func readMessageMultiline(current: String) -> String {
    print("  Type your message. Blank lines are allowed. Finish with a single '.' on its own line.")
    print("  (Press Enter right away to keep the current message.)")
    guard let first = readLine() else { return current }
    if first.trimmingCharacters(in: .whitespaces).isEmpty { return current }
    if first == "." { return current }
    var lines = [first]
    while let l = readLine() {
        if l == "." { break }
        lines.append(l)
    }
    var joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if joined.count > MESSAGE_MAX { joined = String(joined.prefix(MESSAGE_MAX)) }
    return joined.isEmpty ? current : joined
}

func rule() { print(String(repeating: "─", count: 52)) }

func writeConfig(_ c: Config) -> Bool {
    let dir = (configPath() as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } catch {
        FileHandle.standardError.write("NoCake: cannot create \(dir): \(error)\n".data(using: .utf8)!)
        return false
    }
    let dict: [String: Any] = [
        "message": c.message,
        "toggleKeyCode": Int(c.keyCode),
        "toggleModifiers": orderedMods(c.mods),
        "escapeFailsafe": c.escapeFailsafe,
        "deadManMinutes": c.deadManMinutes,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                 options: [.prettyPrinted, .sortedKeys]) else { return false }
    let tmp = configPath() + ".tmp"
    guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return false }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
    return rename(tmp, configPath()) == 0   // atomic
}

func restartApp() {
    // Deliberately avoids `launchctl kickstart`: it HANGS on a stale/broken
    // service registration. SIGTERM the running agent (excluding this configure
    // process) and relaunch via `open` — non-blocking, works for manual launches
    // and for launchd (KeepAlive revives it; a single-instance `open` is harmless).
    let me = getpid()
    let pgrep = Process(); pgrep.launchPath = "/usr/bin/pgrep"
    pgrep.arguments = ["-f", "NoCake.app/Contents/MacOS/nocake"]
    let pipe = Pipe(); pgrep.standardOutput = pipe; pgrep.standardError = FileHandle.nullDevice
    try? pgrep.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    pgrep.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    let pids = out.split(whereSeparator: \.isNewline).compactMap { Int32($0) }.filter { $0 != me }
    for pid in pids { kill(pid, SIGTERM) }

    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let bundle = exe.range(of: ".app").map { String(exe[..<$0.upperBound]) } ?? exe
    let open = Process(); open.launchPath = "/usr/bin/open"; open.arguments = [bundle]
    open.standardOutput = FileHandle.nullDevice; open.standardError = FileHandle.nullDevice
    try? open.run()   // non-blocking; open returns immediately
    print(pids.isEmpty ? "  Started NoCake." : "  Restarted NoCake.")
}

func runConfigure() {
    let cur = loadConfig()
    let src = FileManager.default.fileExists(atPath: configPath()) ? "from config" : "defaults"
    print("")
    rule()
    print("  NoCake — configure")
    rule()
    print("  Current settings (\(src)):")
    print("    message:  \(cur.message.replacingOccurrences(of: "\n", with: "\n              "))")
    print("    combo:    keyCode \(cur.keyCode) + \(orderedMods(cur.mods).joined(separator: "+"))")
    print("    escape:   \(cur.escapeFailsafe ? "on" : "off")")
    print("    dead-man: \(cur.deadManMinutes == 0 ? "off" : "\(cur.deadManMinutes) min")")
    print("")

    var new = cur

    rule()
    print("  1. Message")
    new.message = readMessageMultiline(current: cur.message)
    print("")

    rule()
    print("  2. Arm/disarm combo")
    print("  Press your combo now (30s). Press Enter alone to keep the current one.")
    if let (kc, mods) = captureCombo(timeout: 30) {
        let isBareReturn = (kc == UInt16(kVK_Return) || kc == UInt16(kVK_ANSI_KeypadEnter)) && mods.isEmpty
        if isBareReturn {
            print("  Kept current combo.")
        } else {
            new.keyCode = kc; new.mods = mods
            print("  Captured: keyCode \(kc) + \(orderedMods(mods).joined(separator: "+"))")
            if isFKey(kc) { print("  ⚠ F-key — hold Fn if your F-row is in media mode.") }
        }
    } else {
        print("  No combo captured (timeout, or terminal lacks Accessibility/Input Monitoring). Kept current.")
    }
    print("")

    rule()
    print("  3. Failsafes")
    new.escapeFailsafe = prompt("  Escape failsafe on? (y/n)", default: cur.escapeFailsafe ? "y" : "n")
        .lowercased().hasPrefix("y")
    let dm = prompt("  Dead-man minutes (0 = off)", default: String(cur.deadManMinutes))
    new.deadManMinutes = max(0, Int(dm) ?? cur.deadManMinutes)
    print("")

    // Heads-up (not a block): F-key combo as the only keyboard exit needs Fn.
    // The mouse is never blocked, so Force-Quit always works regardless.
    if isFKey(new.keyCode) && !new.escapeFailsafe && new.deadManMinutes == 0 {
        print("  Note: your F-key combo is the only keyboard exit — hold Fn to disarm.")
        print("  (The mouse is never blocked, so Force-Quit always works.)")
        print("")
    }

    guard writeConfig(new) else {
        FileHandle.standardError.write("NoCake: failed to write config.\n".data(using: .utf8)!)
        exit(1)
    }
    rule()
    print("  Saved \(configPath())")
    let doRestart = prompt("  Restart NoCake now to apply? (y/n)", default: "y")
    if doRestart.lowercased().hasPrefix("y") {
        restartApp()
    } else {
        print("  Not restarted. Apply later: `brew services restart nocake` or relaunch NoCake.app.")
    }
    rule()
    print("")
}

// ---- selftest -----------------------------------------------------------
func runSelftest() {
    let all: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
    let def = Config.defaults
    // combo + escape
    assert(isToggle(keycode: UInt16(kVK_F10), flags: all, config: def), "default F10 combo disarms")
    assert(isToggle(keycode: UInt16(kVK_Escape), flags: all, config: def), "escape failsafe disarms when on")
    var noEsc = def; noEsc.escapeFailsafe = false
    assert(!isToggle(keycode: UInt16(kVK_Escape), flags: all, config: noEsc), "escape does NOT disarm when off")
    assert(!isToggle(keycode: UInt16(kVK_ANSI_A), flags: all, config: def), "wrong key does not disarm")
    // modifier parsing: aliases, case, dedup, unknown
    assert(parseModifiers(["Cmd", "ALT", "control"]).set == ["cmd", "opt", "ctrl"], "modifier aliases normalize")
    assert(parseModifiers(["cmd", "bogus"]).valid == false, "unknown modifier flagged invalid")
    assert(parseModifiers(["cmd", "command"]).set == ["cmd"], "duplicate modifiers dedup")
    // F-key detection (drives the Fn heads-up, not a block)
    assert(isFKey(UInt16(kVK_F10)), "F10 detected as F-key")
    assert(!isFKey(UInt16(kVK_ANSI_A)), "letter A is not an F-key")
    print("selftest OK")
    exit(0)
}

// ---- entry --------------------------------------------------------------
setvbuf(stdout, nil, _IONBF, 0)   // unbuffered — output appears immediately
let args = CommandLine.arguments
if args.contains("--selftest") { runSelftest() }
if args.count > 1 && args[1] == "configure" { runConfigure(); exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
requestPermissions()   // prompt on first launch so arming can't fail silently
Controller.shared.installArmingHotKey()
NSLog("NoCake: running (disarmed). Press the arm combo to arm.")
app.run()
