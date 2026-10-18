import AppKit
import ServiceManagement

@MainActor
final class BackgroundMode {
    static let shared = BackgroundMode()
    private var hideUntil = Date.distantPast

    func start() {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = ev?.eventID == AEEventID(kAEOpenApplication)
            && ev?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if atLogin || justLoggedIn || CommandLine.arguments.contains("--background") {
            hideUntil = Date().addingTimeInterval(3)
            NSApp.setActivationPolicy(.accessory)
            for t in [0.0, 0.2, 0.5, 1.0, 2.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.update(nil) } }
        }
        let nc = NotificationCenter.default
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in MainActor.assumeIsolated { self.update(nil) } }
        }
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            let w = n.object as? NSWindow
            MainActor.assumeIsolated { self.update(w) }
        }
        AppModel.shared.watchMemoryPressure()
        enableLoginItemOnce()
    }

    private var justLoggedIn: Bool {
        setutxent()
        defer { endutxent() }
        var login: time_t = 0
        while let e = getutxent() {
            var u = e.pointee
            let line = withUnsafeBytes(of: &u.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if u.ut_type == USER_PROCESS, line == "console" { login = max(login, u.ut_tv.tv_sec) }
        }
        return login > 0 && Date().timeIntervalSince1970 - Double(login) < 90
    }

    private func appWindows(excluding closing: NSWindow?) -> [NSWindow] {
        NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
    }

    private func update(_ closing: NSWindow?) {
        var wins = appWindows(excluding: closing)
        if Date() < hideUntil {
            wins.forEach { $0.close() }
            wins = []
        }
        let main = NSApp.windows.contains { $0 !== closing && ($0.isVisible || $0.isMiniaturized) && $0.identifier?.rawValue.hasPrefix("main") == true }
        if AppModel.shared.windowVisible != main { AppModel.shared.windowVisible = main }
        let policy: NSApplication.ActivationPolicy = wins.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate() }
    }

    private func enableLoginItemOnce() {
        let key = "loginItemConfigured"
        guard !Flavor.isDev, !Prefs.d.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        Prefs.d.set(true, forKey: key)
        Task {
            try? await SMAppService.mainApp.unregister()
            try? SMAppService.mainApp.register()
        }
    }
}
