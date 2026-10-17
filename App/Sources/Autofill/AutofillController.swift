import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import SwiftwardenCore

struct FillTarget {
    let app: NSRunningApplication
    let element: AXUIElement
    let isPassword: Bool
    let frame: CGRect
    let url: String?

    var contextLabel: String {
        if let url, let h = URLMatcher.host(of: url) { return h }
        return app.localizedName ?? "this app"
    }
}

@MainActor
final class AutofillController {
    static let shared = AutofillController()

    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private(set) var target: FillTarget?
    private var dismissed: AXUIElement?
    private let suggestions = FloatingPanel(canKey: false)
    private let palette = FloatingPanel(canKey: true)
    private var hotKey: HotKey?
    private var started = false

    static let userHints = ["user", "email", "e-mail", "login", "account", "benutzer", "anmelde", "konto", "identifier", "mail"]

    var trusted: Bool { AXIsProcessTrusted() }
    var enabled: Bool { Prefs.d.bool(forKey: Prefs.autofillEnabled) }

    func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { AutofillController.shared.attach(app) }
        }
        registerHotKey()
        attach(NSWorkspace.shared.frontmostApplication)
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                let s = AutofillController.shared
                if s.observer == nil, s.trusted { s.attach(NSWorkspace.shared.frontmostApplication) }
            }
        }
    }

    func registerHotKey() {
        hotKey?.unregister()
        hotKey = nil
        let combos: [String: (UInt32, UInt32)] = [
            "cmdShiftL": (UInt32(kVK_ANSI_L), UInt32(cmdKey | shiftKey)),
            "optCmdL": (UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey)),
            "ctrlShiftL": (UInt32(kVK_ANSI_L), UInt32(controlKey | shiftKey)),
            "cmdShiftBackslash": (UInt32(kVK_ANSI_Backslash), UInt32(cmdKey | shiftKey)),
        ]
        guard let c = combos[Prefs.d.string(forKey: Prefs.hotkey) ?? ""] else { return }
        hotKey = HotKey(keyCode: c.0, modifiers: c.1) { AutofillController.shared.hotKeyPressed() }
    }

    private func detach() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        observer = nil
        observedPid = 0
    }

    func attach(_ app: NSRunningApplication?) {
        suggestions.hide()
        detach()
        guard enabled, trusted, let app, app.processIdentifier != getpid() else { return }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, _ in
            MainActor.assumeIsolated { AutofillController.shared.focusChanged() }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        AXObserverAddNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString, nil)
        AXObserverAddNotification(obs, appEl, kAXFocusedWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPid = pid
        focusChanged()
    }

    func currentTarget(requireLoginField: Bool = true) -> FillTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let el = AX.element(appEl, kAXFocusedUIElementAttribute) else { return nil }
        let secure = AX.isSecure(el)
        if requireLoginField {
            guard secure || (AX.isTextInput(el) && Self.userHints.contains(where: AX.hint(el).contains)) else { return nil }
        }
        let frame = AX.frame(el) ?? CGRect(x: NSScreen.main?.frame.midX ?? 400, y: NSScreen.main?.frame.midY ?? 400, width: 1, height: 1)
        return FillTarget(app: app, element: el, isPassword: secure, frame: frame, url: webURL(el))
    }

    private func webURL(_ el: AXUIElement) -> String? {
        var cur: AXUIElement? = el
        var n = 0
        while let c = cur, n < 60 {
            if AX.string(c, kAXRoleAttribute) == "AXWebArea", let u = AX.url(c) { return u }
            cur = AX.element(c, kAXParentAttribute)
            n += 1
        }
        if let w = AX.element(el, kAXWindowAttribute), let doc = AX.string(w, kAXDocumentAttribute), doc.hasPrefix("http") { return doc }
        return nil
    }

    func candidates(_ t: FillTarget) -> [Cipher] {
        let m = AppModel.shared
        guard m.phase == .unlocked else { return [] }
        if let u = t.url { return m.matches(url: u) }
        return m.matches(bundleId: t.app.bundleIdentifier ?? "", appName: t.app.localizedName ?? "")
    }

    func focusChanged() {
        guard enabled, Prefs.d.bool(forKey: Prefs.autofillSuggestions), let t = currentTarget() else {
            suggestions.hide(); target = nil; return
        }
        if let d = dismissed, CFEqual(d, t.element) { return }
        target = t
        let m = AppModel.shared
        let matches = candidates(t)
        if !t.isPassword && matches.isEmpty && m.phase == .unlocked { suggestions.hide(); return }
        if m.phase == .loggedOut { suggestions.hide(); return }
        showSuggestions(t, matches)
    }

    private func showSuggestions(_ t: FillTarget, _ matches: [Cipher]) {
        let view = SuggestionView(target: t, matches: Array(matches.prefix(5)),
                                  onFill: { c in AutofillController.shared.fill(c, into: t) },
                                  onSearch: { AutofillController.shared.openPalette(t) },
                                  onDismiss: { AutofillController.shared.dismissed = t.element; AutofillController.shared.suggestions.hide() },
                                  onUnlocked: { AutofillController.shared.focusChanged() })
            .environment(AppModel.shared)
        suggestions.show(view, near: t.frame)
    }

    func hotKeyPressed() {
        guard trusted else { requestPermission(); return }
        let t = currentTarget(requireLoginField: false)
        guard let t else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openPalette(t)
    }

    func openPalette(_ t: FillTarget) {
        suggestions.hide()
        let view = QuickFillView(target: t, initial: candidates(t),
                                 onFill: { c in AutofillController.shared.palette.hide(); AutofillController.shared.fill(c, into: t) },
                                 onClose: { AutofillController.shared.palette.hide() })
            .environment(AppModel.shared)
        palette.show(view, near: t.frame, key: true)
    }

    // MARK: Filling

    func fill(_ c: Cipher, into t: FillTarget) {
        suggestions.hide()
        let m = AppModel.shared
        guard c.needsReprompt && !m.repromptPassed.contains(c.id) else { performFill(c, t); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Confirm master password"
        alert.informativeText = "\(c.displayName) is protected by master password re-prompt."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Fill")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pw = field.stringValue
        Task {
            if await m.verifyMasterPassword(pw) {
                m.repromptPassed.insert(c.id)
                performFill(c, t)
            } else {
                m.showToast("Invalid master password")
            }
        }
    }

    private func performFill(_ c: Cipher, _ t: FillTarget) {
        let user = c.login?.username ?? ""
        let pass = c.canViewPassword ? (c.login?.password ?? "") : ""
        var userEl: AXUIElement?
        var passEl: AXUIElement?
        if t.isPassword {
            passEl = t.element
            userEl = counterpart(of: t.element, wantSecure: false, before: true)
        } else {
            userEl = t.element
            passEl = counterpart(of: t.element, wantSecure: true, before: false)
        }
        let method = Prefs.d.string(forKey: Prefs.fillMethod) ?? "type"
        let submit = Prefs.d.bool(forKey: Prefs.autoSubmit)
        let fields = [(userEl, user), (passEl, pass)].filter { $0.0 != nil && !$0.1.isEmpty }.map { ($0.0!, $0.1) }
        let app = t.app
        let lastEl = fields.last?.0
        DispatchQueue.global(qos: .userInitiated).async {
            Filler.waitForModifiersReleased()
            app.activate()
            usleep(120_000)
            for (el, text) in fields {
                Filler.set(text, on: el, method: method)
                usleep(80_000)
            }
            if submit, lastEl != nil { Filler.key(UInt16(kVK_Return)) }
        }
        if Prefs.d.bool(forKey: Prefs.copyTotpAfterFill), let s = c.login?.totp, let code = TOTP(s)?.code() {
            m_copy(code)
        }
    }

    private func m_copy(_ code: String) { AppModel.shared.copy(code, "verification code") }

    private func counterpart(of el: AXUIElement, wantSecure: Bool, before: Bool) -> AXUIElement? {
        var ancestor = AX.element(el, kAXParentAttribute)
        var depth = 0
        while let a = ancestor, depth < 12 {
            let inputs = AX.collectInputs(a)
            if let i = inputs.firstIndex(where: { CFEqual($0, el) }) {
                let range = before ? Array(inputs[..<i].reversed()) : Array(inputs[(i + 1)...])
                if let f = range.first(where: { AX.isSecure($0) == wantSecure }) { return f }
            }
            ancestor = AX.element(a, kAXParentAttribute)
            depth += 1
        }
        return nil
    }
}

enum Filler {
    static func waitForModifiersReleased() {
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        for _ in 0 ..< 100 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty { return }
            usleep(20000)
        }
    }

    static func key(_ code: UInt16, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        usleep(8000)
    }

    static func type(_ s: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in s {
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                e?.post(tap: .cghidEventTap)
            }
            usleep(4000)
        }
    }

    static func set(_ text: String, on el: AXUIElement, method: String) {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(60000)
        switch method {
        case "value":
            if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) != .success { fallthrough }
        case "paste":
            DispatchQueue.main.sync {
                let pb = NSPasteboard.general
                let old = pb.string(forType: .string)
                pb.clearContents()
                pb.setString(text, forType: .string)
                pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                key(UInt16(kVK_ANSI_A), flags: .maskCommand)
                key(UInt16(kVK_ANSI_V), flags: .maskCommand)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    pb.clearContents()
                    if let old { pb.setString(old, forType: .string) }
                }
            }
        default:
            key(UInt16(kVK_ANSI_A), flags: .maskCommand)
            key(UInt16(kVK_Delete))
            type(text)
        }
    }
}

final class HotKey {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var nextId: UInt32 = 1
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        id = HotKey.nextId
        HotKey.nextId += 1
        HotKey.install()
        HotKey.handlers[id] = handler
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x5357_4644), id: id), GetEventDispatcherTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

