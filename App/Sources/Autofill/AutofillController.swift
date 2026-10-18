import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import SwiftwardenCore
struct FillTarget {
    let app: NSRunningApplication
    let element: AXUIElement
    let kind: FieldKind
    let frame: CGRect
    let url: String?
    let verifiedBrowser: Bool
    let signed: Bool

    var isPassword: Bool { kind == .password }

    var contextLabel: String {
        if let url, let h = URLMatcher.host(of: url) { return verifiedBrowser ? h : "\(h) in \(app.localizedName ?? "this app")" }
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
    private var filling = false
    private var offerAfterFill: (cipherId: String, target: FillTarget)?
    private let offerPanel = FloatingPanel(canKey: false)
    private var offerHideTask: Task<Void, Never>?
    private let suggestions = FloatingPanel(canKey: false)
    private let palette = FloatingPanel(canKey: true)
    private var hotKey: HotKey?
    private var started = false

    nonisolated static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.vivaldi.Vivaldi", "com.vivaldi.Vivaldi.snapshot", "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "ai.perplexity.comet", "com.sigmaos.sigmaos.macos", "net.imput.helium", "org.chromium.Thorium",
        "ru.yandex.desktop.yandex-browser", "com.pushplaylabs.sidekick", "io.wavebox.wavebox",
    ]

    nonisolated static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS", "com.kagi.kagimacOS.RC", "com.duckduckgo.macos.browser",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
        "one.ablaze.floorp", "org.mozilla.librewolf", "net.waterfox.waterfox", "net.mullvad.mullvadbrowser", "org.torproject.torbrowser",
    ]

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
        if enabled, !trusted, !Prefs.d.bool(forKey: "axPrompted") {
            Prefs.d.set(true, forKey: "axPrompted")
            requestPermission()
        }
        attach(NSWorkspace.shared.frontmostApplication)
        if !trusted {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let s = AutofillController.shared
                    guard s.trusted else { return }
                    timer.invalidate()
                    s.attach(NSWorkspace.shared.frontmostApplication)
                }
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
        guard AutofillPolicy.allows(app.bundleIdentifier) else { return }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        let bid = app.bundleIdentifier ?? ""
        if AutofillPolicy.isBrowser(bid) && !bid.hasPrefix("com.apple.") {
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
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
        guard AutofillPolicy.allows(app.bundleIdentifier) else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let el = AX.element(appEl, kAXFocusedUIElementAttribute) else { return nil }
        let claimsBrowser = AutofillPolicy.isBrowser(app.bundleIdentifier)
        if claimsBrowser, AX.webArea(of: el) == nil { return nil }
        if AX.isSearch(el) { return nil }
        let secure = AX.isSecure(el)
        guard secure || AX.isTextInput(el) || !requireLoginField else { return nil }
        var kind: FieldKind = secure || AX.isTextInput(el) ? AX.kind(el) : .unknown
        if AX.isSearch(el) && !secure { kind = .unknown }
        if kind == .unknown, AX.isTextInput(el), !AX.isSearch(el),
           let next = AX.nextInput(after: el), AX.isSecure(next) {
            kind = .username
        }
        if requireLoginField, kind == .unknown { return nil }
        let frame = AX.frame(el) ?? CGRect(x: NSScreen.main?.frame.midX ?? 400, y: NSScreen.main?.frame.midY ?? 400, width: 1, height: 1)
        let browser = AppIdentity.isVerifiedBrowser(app)
        let signed = browser || (!claimsBrowser && AppIdentity.isSigned(app))
        return FillTarget(app: app, element: el, kind: kind, frame: frame, url: signed ? Self.webURL(el, browser: browser) : nil, verifiedBrowser: browser, signed: signed)
    }

    nonisolated static func webURL(_ el: AXUIElement, browser: Bool = false) -> String? {
        var cur: AXUIElement? = el
        var n = 0
        var window: AXUIElement?
        while let c = cur, n < 60 {
            let role = AX.string(c, kAXRoleAttribute)
            if role == "AXWebArea", let u = AX.url(c), u.hasPrefix("http") { return u }
            if role == kAXWindowRole { window = c }
            cur = AX.element(c, kAXParentAttribute)
            n += 1
        }
        let win = window ?? AX.element(el, kAXWindowAttribute)
        if let w = win, let doc = AX.string(w, kAXDocumentAttribute), doc.hasPrefix("http") { return doc }
        guard browser, let w = win else { return nil }
        return addressBarURL(in: w)
    }

    nonisolated static func addressBarURL(in window: AXUIElement) -> String? {
        let hints = ["address", "url", "location", "adresse", "search or enter", "suchen oder", "urlbar", "omnibox"]
        var stack = [window]
        var visited = 0
        while let e = stack.popLast(), visited < 800 {
            visited += 1
            let role = AX.string(e, kAXRoleAttribute)
            if role == "AXWebArea" { continue }
            if role == kAXTextFieldRole || role == kAXComboBoxRole {
                let label = [kAXDescriptionAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute, kAXTitleAttribute, "AXDOMIdentifier"]
                    .compactMap { AX.string(e, $0) }.joined(separator: " ").lowercased()
                if hints.contains(where: label.contains), let v = AX.string(e, kAXValueAttribute), let u = normalizedURL(v) { return u }
            }
            stack.append(contentsOf: AX.children(e).reversed())
        }
        return nil
    }

    nonisolated static func normalizedURL(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, !v.contains(" "), v.contains(".") || v.hasPrefix("http") || v.hasPrefix("localhost") else { return nil }
        let full = v.hasPrefix("http://") || v.hasPrefix("https://") ? v : "https://" + v
        return URLMatcher.host(of: full) == nil ? nil : full
    }

    func candidates(_ t: FillTarget) -> [Cipher] {
        let m = AppModel.shared
        guard m.phase == .unlocked else { return [] }
        if t.kind.isCard { return m.items(for: .type(.card), query: "") }
        if t.kind.isIdentity { return m.items(for: .type(.identity), query: "") }
        let isBrowser = AutofillPolicy.isBrowser(t.app.bundleIdentifier)
        let logins: [Cipher]
        if let u = t.url { logins = m.matches(url: u) }
        else if isBrowser { logins = [] }
        else { logins = m.matches(bundleId: t.app.bundleIdentifier ?? "", appName: t.app.localizedName ?? "", heuristics: t.signed) }
        switch t.kind {
        case .totp:
            let withCode = logins.filter(\.hasTotp)
            return withCode.isEmpty ? logins : withCode
        case .pin:
            let withPin = logins.filter { Self.pinValue($0, hints: nil) != nil }
            return withPin.isEmpty ? logins : withPin
        default:
            return logins
        }
    }

    static func pinValue(_ c: Cipher, hints: FieldHints?) -> String? {
        let usable = (c.fields ?? []).filter { $0.type == .text || $0.type == .hidden }
        if let h = hints, let f = usable.first(where: { FieldClassifier.customFieldMatches($0.name ?? "", hints: h) }) { return f.value }
        return usable.first { FieldClassifier.classify(FieldHints(texts: [$0.name ?? ""])) == .pin }?.value
    }

    func focusChanged() {
        guard !filling else { return }
        guard enabled, Prefs.d.bool(forKey: Prefs.autofillSuggestions), let t = currentTarget() else {
            suggestions.hide(); target = nil; return
        }
        if let d = dismissed, CFEqual(d, t.element) { return }
        target = t
        let m = AppModel.shared
        let matches = candidates(t)
        if t.kind != .password && matches.isEmpty && m.phase == .unlocked { suggestions.hide(); return }
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

    // MARK: Remember site / app

    func fillFromSearch(_ c: Cipher, into t: FillTarget) {
        palette.hide()
        offerAfterFill = shouldOfferToRemember(c, t) ? (c.id, t) : nil
        fill(c, into: t)
    }

    func rememberURI(for t: FillTarget) -> String? {
        let bid = t.app.bundleIdentifier ?? ""
        let isBrowserApp = AutofillPolicy.isBrowser(bid)
        if let u = t.url, let host = URLMatcher.host(of: u) {
            return (u.lowercased().hasPrefix("http://") ? "http://" : "https://") + host
        }
        guard !isBrowserApp, t.signed, !bid.isEmpty else { return nil }
        return "macapp://" + bid
    }

    func rememberPlace(for t: FillTarget) -> String {
        if let u = t.url, let host = URLMatcher.host(of: u) { return host }
        return t.app.localizedName ?? "this app"
    }

    func shouldOfferToRemember(_ c: Cipher, _ t: FillTarget) -> Bool {
        guard c.type == .login, c.canEdit, !c.isDeleted, let uri = rememberURI(for: t) else { return false }
        if candidates(t).contains(where: { $0.id == c.id }) { return false }
        return !(c.login?.uris ?? []).contains { ($0.uri ?? "").lowercased() == uri.lowercased() }
    }

    private func showRememberOffer(_ o: (cipherId: String, target: FillTarget)) {
        guard let c = AppModel.shared.cipher(o.cipherId), let uri = rememberURI(for: o.target) else { return }
        let place = rememberPlace(for: o.target)
        let view = RememberOfferView(cipher: c, place: place,
                                     onSave: { AutofillController.shared.saveRemembered(cipherId: o.cipherId, uri: uri, place: place) },
                                     onDismiss: { AutofillController.shared.offerPanel.hide() })
            .environment(AppModel.shared)
        offerPanel.show(view, near: o.target.frame)
        offerHideTask?.cancel()
        offerHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            AutofillController.shared.offerPanel.hide()
        }
    }

    private func saveRemembered(cipherId: String, uri: String, place: String) {
        offerPanel.hide()
        let m = AppModel.shared
        guard var c = m.cipher(cipherId) else { return }
        guard !(c.login?.uris ?? []).contains(where: { ($0.uri ?? "").lowercased() == uri.lowercased() }) else { return }
        let uris = (c.login?.uris ?? []).filter { !($0.uri ?? "").isEmpty } + [LoginUri(uri: uri)]
        c.login?.uris = uris
        Task {
            do {
                _ = try await m.save(c)
                m.showToast("\(c.displayName) will be suggested on \(place)")
            } catch {
                m.errorMessage = "Could not save: \(error.localizedDescription)"
            }
        }
    }

    func hotKeyPressed() {
        guard trusted else { requestPermission(); return }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
           !AutofillPolicy.allows(app.bundleIdentifier) {
            NSSound.beep()
            return
        }
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
                                 onFill: { c in AutofillController.shared.fillFromSearch(c, into: t) },
                                 onClose: { AutofillController.shared.palette.hide() })
            .environment(AppModel.shared)
        palette.show(view, near: t.frame, key: true)
    }

    // MARK: Filling

    func fill(_ c: Cipher, into t: FillTarget) {
        suggestions.hide()
        offerPanel.hide()
        let offer = offerAfterFill
        offerAfterFill = nil
        let m = AppModel.shared
        guard c.needsReprompt && !m.repromptPassed.contains(c.id) else { performFill(c, t, offer: offer); return }
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
                performFill(c, t, offer: offer)
            } else {
                m.showToast("Invalid master password")
            }
        }
    }

    private func performFill(_ c: Cipher, _ t: FillTarget, offer: (cipherId: String, target: FillTarget)? = nil) {
        var plan: [(AXUIElement, String)]
        switch c.type {
        case .login: plan = loginPlan(c, t)
        case .card, .identity: plan = formPlan(c, t)
        default: plan = []
        }
        plan = plan.filter { !$0.1.isEmpty }
        guard !plan.isEmpty else { AppModel.shared.showToast("Nothing to fill for this field"); return }
        let method = Prefs.d.string(forKey: Prefs.fillMethod) ?? "type"
        let submit = Prefs.d.bool(forKey: Prefs.autoSubmit) && c.type == .login && t.kind.isLogin
        let app = t.app
        let totpSecret = c.type == .login && Prefs.d.bool(forKey: Prefs.copyTotpAfterFill) ? c.login?.totp.flatMap { $0.isEmpty ? nil : $0 } : nil
        let origin = t.element
        let others = plan.filter { !CFEqual($0.0, origin) }
        let own = plan.filter { CFEqual($0.0, origin) }
        let pid = app.processIdentifier
        let host = t.url.flatMap(URLMatcher.host(of:))
        let viaBrowser = t.verifiedBrowser
        filling = true
        suggestions.hide()
        DispatchQueue.global(qos: .userInitiated).async {
            var completed = false
            defer {
                usleep(250_000)
                let showOffer = completed ? offer : nil
                DispatchQueue.main.async {
                    let s = AutofillController.shared
                    s.dismissed = origin
                    s.filling = false
                    if let showOffer { s.showRememberOffer(showOffer) }
                }
            }
            Filler.waitForModifiersReleased()
            app.activate()
            func cancel() { DispatchQueue.main.async { AppModel.shared.showToast("Fill canceled: the window or page changed") } }
            guard Filler.waitFront(pid) else { cancel(); return }
            usleep(60000)
            if let host, Self.webURL(origin, browser: viaBrowser).flatMap(URLMatcher.host(of:)) != host { cancel(); return }
            let failed = others.filter { !Filler.setQuietly($0.1, on: $0.0) }
            for (el, text) in failed {
                guard Filler.frontPid() == pid else { cancel(); return }
                Filler.set(text, on: el, method: method)
                usleep(80_000)
            }
            if own.isEmpty, !failed.isEmpty {
                AXUIElementSetAttributeValue(origin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            for (el, text) in own {
                guard Filler.frontPid() == pid else { cancel(); return }
                Filler.set(text, on: el, method: method)
            }
            for (el, text) in plan where !Filler.matches(el, text) { _ = Filler.setQuietly(text, on: el) }
            completed = true
            if submit, Filler.frontPid() == pid { Filler.key(UInt16(kVK_Return)) }
            guard let totpSecret else { return }
            if method == "paste" { usleep(700_000) }
            DispatchQueue.main.async {
                if let code = TOTP(totpSecret)?.code() { AppModel.shared.copy(code, "verification code") }
            }
        }
    }

    private func loginPlan(_ c: Cipher, _ t: FillTarget) -> [(AXUIElement, String)] {
        let user = c.login?.username ?? ""
        let pass = c.canViewPassword ? (c.login?.password ?? "") : ""
        let code = c.login?.totp.flatMap { TOTP($0)?.code() } ?? ""
        switch t.kind {
        case .totp:
            return [(t.element, code)]
        case .pin:
            return [(t.element, Self.pinValue(c, hints: AX.hints(t.element)) ?? "")]
        default:
            break
        }
        var plan: [(AXUIElement, String)] = []
        var used: [AXUIElement] = []
        func add(_ el: AXUIElement?, _ v: String) {
            guard let el, !v.isEmpty, !used.contains(where: { CFEqual($0, el) }) else { return }
            used.append(el)
            plan.append((el, v))
        }
        let inputs = AX.formInputs(around: t.element, want: 6)
        let kinds = inputs.map { ($0, AX.isSecure($0) ? FieldKind.password : AX.kind($0)) }
        let idx = inputs.firstIndex { CFEqual($0, t.element) } ?? 0
        if t.isPassword {
            let before = kinds[..<min(idx, kinds.count)].reversed()
            let userEl = before.first { $0.1 == .username || $0.1 == .email }?.0
                ?? before.first { !AX.isSecure($0.0) && ![.totp, .pin].contains($0.1) && !$0.1.isCard && !AX.isSearch($0.0) }?.0
            add(userEl, user)
            add(t.element, pass)
        } else {
            add(t.element, user)
            let after = idx + 1 < kinds.count ? Array(kinds[(idx + 1)...]) : []
            add(after.first { AX.isSecure($0.0) }?.0, pass)
        }
        for (el, kind) in kinds where kind == .totp { add(el, code) }
        for (el, kind) in kinds where !AX.isSecure(el) || kind == .pin {
            guard !used.contains(where: { CFEqual($0, el) }) else { continue }
            let h = AX.hints(el)
            if let f = (c.fields ?? []).first(where: { ($0.type == .text || $0.type == .hidden) && FieldClassifier.customFieldMatches($0.name ?? "", hints: h) }) {
                add(el, f.value ?? "")
            } else if kind == .pin, let v = Self.pinValue(c, hints: h) {
                add(el, v)
            }
        }
        return plan
    }

    private func formPlan(_ c: Cipher, _ t: FillTarget) -> [(AXUIElement, String)] {
        let inputs = AX.formInputs(around: t.element, want: 12)
        var plan: [(AXUIElement, String)] = []
        var filledKinds: Set<FieldKind> = []
        for el in inputs where !AX.isSearch(el) {
            let h = AX.hints(el)
            let kind = FieldClassifier.classify(h)
            guard kind != .unknown, !filledKinds.contains(kind) || kind == .address1 else { continue }
            if let v = value(kind, c, hints: h), !v.isEmpty {
                plan.append((el, v))
                filledKinds.insert(kind)
            }
        }
        if !plan.contains(where: { CFEqual($0.0, t.element) }), let v = value(t.kind, c, hints: AX.hints(t.element)) {
            plan.insert((t.element, v), at: 0)
        }
        return plan
    }

    private func value(_ kind: FieldKind, _ c: Cipher, hints: FieldHints) -> String? {
        if let card = c.card, c.type == .card {
            let month = (card.expMonth ?? "").count == 1 ? "0" + card.expMonth! : (card.expMonth ?? "")
            var year = card.expYear ?? ""
            if year.count == 2 { year = "20" + year }
            let short = FieldClassifier.normalize(hints.texts.joined(separator: " "))
            let twoDigitYear = (short.contains(" yy ") || short.contains(" jj ")) && !short.contains("yyyy")
            switch kind {
            case .cardNumber: return card.number?.replacingOccurrences(of: " ", with: "")
            case .cardCode: return card.code
            case .cardholder, .fullName: return card.cardholderName
            case .cardExpMonth: return month
            case .cardExpYear: return twoDigitYear ? String(year.suffix(2)) : year
            case .cardExpiry: return month.isEmpty || year.isEmpty ? nil : month + "/" + String(year.suffix(2))
            default: return nil
            }
        }
        if let i = c.identity, c.type == .identity {
            switch kind {
            case .firstName: return i.firstName
            case .middleName: return i.middleName
            case .lastName: return i.lastName
            case .fullName: return [i.firstName, i.middleName, i.lastName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
            case .email: return i.email
            case .username: return i.username ?? i.email
            case .phone: return i.phone
            case .address1: return i.address1
            case .address2: return [i.address2, i.address3].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
            case .city: return i.city
            case .state: return i.state
            case .postalCode: return i.postalCode
            case .country: return i.country
            case .company: return i.company
            default: return nil
            }
        }
        return nil
    }
}

enum Filler {
    static func frontPid() -> pid_t? {
        var pid: pid_t = 0
        guard let app = AX.element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
              AXUIElementGetPid(app, &pid) == .success else { return nil }
        return pid
    }

    static func waitFront(_ pid: pid_t) -> Bool {
        for _ in 0 ..< 30 {
            if frontPid() == pid { return true }
            usleep(40000)
        }
        return false
    }

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

    static func type(_ s: String, delay: useconds_t = 6000) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in s {
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                e?.post(tap: .cghidEventTap)
            }
            usleep(delay)
        }
    }

    static func clearAndType(_ text: String, delay: useconds_t) {
        key(UInt16(kVK_ANSI_A), flags: .maskCommand)
        key(UInt16(kVK_Delete))
        usleep(40000)
        type(text, delay: delay)
    }

    static func matches(_ el: AXUIElement, _ text: String) -> Bool {
        guard let v = AX.string(el, kAXValueAttribute) else { return !AX.isSecure(el) }
        return AX.isSecure(el) ? v.count == text.count : v == text
    }

    static func setQuietly(_ text: String, on el: AXUIElement) -> Bool {
        guard !AX.isSecure(el) else { return false }
        func attempt() -> Bool {
            guard AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) == .success else { return false }
            for _ in 0 ..< 6 {
                usleep(40000)
                if AX.string(el, kAXValueAttribute) == text { return true }
            }
            return false
        }
        for _ in 0 ..< 2 {
            guard focus(el) else { continue }
            if attempt() {
                usleep(120_000)
                return true
            }
        }
        return false
    }

    static func isFocused(_ el: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success,
              let f = AX.element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(f, el)
    }

    static func focus(_ el: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        for _ in 0 ..< 25 {
            usleep(30000)
            if isFocused(el) {
                usleep(250_000)
                return isFocused(el)
            }
        }
        return false
    }

    static func set(_ text: String, on el: AXUIElement, method: String) {
        guard focus(el) else {
            AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString)
            return
        }
        switch method {
        case "value":
            if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) != .success { fallthrough }
        case "paste":
            guard isFocused(el) else { break }
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
            if isFocused(el) { clearAndType(text, delay: 6000) }
        }
        usleep(200_000)
        if matches(el, text) { return }
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString)
        usleep(150_000)
        if matches(el, text) { return }
        guard focus(el) else { return }
        clearAndType(text, delay: 15000)
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



























