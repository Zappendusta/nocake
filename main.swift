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

func modsFromFlags(_ f: CGEventFlags) -> Set<String> {
    var s = Set<String>()
    if f.contains(.maskCommand)   { s.insert("cmd") }
    if f.contains(.maskAlternate) { s.insert("opt") }
    if f.contains(.maskControl)   { s.insert("ctrl") }
    if f.contains(.maskShift)     { s.insert("shift") }
    return s
}

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

/// A key is a reliable sole exit if it is NOT an F-key (media-key risk).
func comboIsReliable(_ keyCode: UInt16) -> Bool { !FKEY_CODES.contains(keyCode) }

/// Exit invariant: at least one of {reliable combo, escape, dead-man} must be
/// active. If none are, force escapeFailsafe on. Pure — tested in --selftest.
func healInvariant(_ c: Config) -> Config {
    let reliableCombo = comboIsReliable(c.keyCode)
    let hasDeadman = c.deadManMinutes > 0
    if !reliableCombo && !c.escapeFailsafe && !hasDeadman {
        var healed = c
        healed.escapeFailsafe = true
        NSLog("NoCake: zero reliable exits (F-key combo + escape off + dead-man 0) — forcing escapeFailsafe on")
        return healed
    }
    return c
}

/// Load config with per-field validation (each bad field defaults independently),
/// then heal the exit invariant. Never throws; never returns an unsafe config.
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
    return healInvariant(c)
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
            NSLog("NoCake: could not create event tap (grant Accessibility + Input Monitoring)")
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
        let rect = NSRect(x: 0, y: 0, width: 460, height: 140)
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

// ---- configure wizard ---------------------------------------------------
// Live-capture globals (C event-tap callback can't capture Swift context).
var captureKeyCode: UInt16 = 0
var captureMods: Set<String> = []
var captureGot = false

func captureCombo(timeout: TimeInterval) -> (UInt16, Set<String>)? {
    captureGot = false
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
    ) else { return nil }   // no permission
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    CFRunLoopRunInMode(.defaultMode, timeout, false)
    CGEvent.tapEnable(tap: tap, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
    return captureGot ? (captureKeyCode, captureMods) : nil
}

func prompt(_ q: String, default def: String) -> String {
    print("\(q) [\(def)]: ", terminator: "")
    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return def }
    return line
}

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
        "toggleModifiers": Array(c.mods).sorted(),
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
    let label = "gui/\(getuid())/homebrew.mxcl.nocake"
    func run(_ cmd: String, _ args: [String]) -> Int32 {
        let p = Process(); p.launchPath = cmd; p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit(); return p.terminationStatus
    }
    if run("/bin/launchctl", ["print", label]) == 0 {
        _ = run("/bin/launchctl", ["kickstart", "-k", label])
        print("Restarted via launchd.")
        return
    }
    // Manual launch: find + kill + relaunch.
    let pgrep = Process(); pgrep.launchPath = "/usr/bin/pgrep"
    pgrep.arguments = ["-f", "NoCake.app/Contents/MacOS/nocake"]
    let pipe = Pipe(); pgrep.standardOutput = pipe
    try? pgrep.run(); pgrep.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let pids = out.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    if pids.isEmpty {
        print("NoCake not running. Start with `brew services start nocake` or `open NoCake.app`.")
        return
    }
    for pid in pids { kill(pid, SIGTERM) }
    // Best-effort relaunch via the Homebrew bundle if present.
    let brew = Process(); brew.launchPath = "/bin/sh"
    brew.arguments = ["-c", "open \"$(brew --prefix nocake 2>/dev/null)/NoCake.app\" 2>/dev/null || true"]
    try? brew.run(); brew.waitUntilExit()
    print("Restarted.")
}

func runConfigure() {
    let cur = loadConfig()
    print("Current NoCake config (\(FileManager.default.fileExists(atPath: configPath()) ? "from config" : "defaults")):")
    print("  message:        \(cur.message)")
    print("  combo:          keyCode \(cur.keyCode) + \(Array(cur.mods).sorted().joined(separator: "+"))")
    print("  escapeFailsafe: \(cur.escapeFailsafe)")
    print("  deadManMinutes: \(cur.deadManMinutes)")
    print("")

    var new = cur
    new.message = prompt("Message (with emoji)", default: cur.message)
    if new.message.count > MESSAGE_MAX { new.message = String(new.message.prefix(MESSAGE_MAX)) }

    // Combo: live capture, with keep-current fallback if no permission.
    print("Press your desired arm/disarm combo now (30s, Enter to keep current)...")
    // Drain the pending Enter is not needed; capture reads the next global keyDown.
    if let (kc, mods) = captureCombo(timeout: 30), !mods.isEmpty {
        new.keyCode = kc; new.mods = mods
        print("Captured: keyCode \(kc) + \(Array(mods).sorted().joined(separator: "+"))")
        if !comboIsReliable(kc) { print("  ⚠ that's an F-key — may need Fn on some keyboards.") }
    } else {
        print("No combo captured (timeout or missing Accessibility/Input Monitoring permission). Keeping current.")
    }

    let esc = prompt("Escape failsafe on? (y/n)", default: cur.escapeFailsafe ? "y" : "n")
    new.escapeFailsafe = esc.lowercased().hasPrefix("y")
    let dm = prompt("Dead-man minutes (0 = off)", default: String(cur.deadManMinutes))
    new.deadManMinutes = max(0, Int(dm) ?? cur.deadManMinutes)

    // Enforce the exit invariant at write time — block, don't silently heal.
    if !comboIsReliable(new.keyCode) && !new.escapeFailsafe && new.deadManMinutes == 0 {
        print("")
        print("REFUSED: that leaves zero reliable exits (F-key combo + escape off + dead-man 0).")
        print("Enable the Escape failsafe, set a dead-man timeout, or pick a non-F-key combo, then re-run `nocake configure`.")
        exit(1)
    }

    guard writeConfig(new) else {
        FileHandle.standardError.write("NoCake: failed to write config.\n".data(using: .utf8)!)
        exit(1)
    }
    print("Wrote \(configPath())")
    restartApp()
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
    // reliable key
    assert(!comboIsReliable(UInt16(kVK_F10)), "F10 is not a reliable sole exit")
    assert(comboIsReliable(UInt16(kVK_ANSI_A)), "letter A is a reliable exit")
    // exit-invariant heal: F-key + escape off + dead-man 0 -> escape forced on
    var risky = Config(message: "x", keyCode: UInt16(kVK_F10), mods: DEFAULT_MODS,
                       escapeFailsafe: false, deadManMinutes: 0)
    assert(healInvariant(risky).escapeFailsafe == true, "zero-exit config heals to escapeFailsafe on")
    // reliable combo with everything else off is allowed (no heal)
    risky.keyCode = UInt16(kVK_ANSI_A)
    assert(healInvariant(risky).escapeFailsafe == false, "reliable combo needs no heal")
    print("selftest OK")
    exit(0)
}

// ---- entry --------------------------------------------------------------
let args = CommandLine.arguments
if args.contains("--selftest") { runSelftest() }
if args.count > 1 && args[1] == "configure" { runConfigure(); exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Controller.shared.installArmingHotKey()
NSLog("NoCake: running (disarmed). Press the arm combo to arm.")
app.run()
