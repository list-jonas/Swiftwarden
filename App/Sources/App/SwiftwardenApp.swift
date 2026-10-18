import SwiftUI
import SwiftwardenCore

@main
struct SwiftwardenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @AppStorage(Prefs.menuBarIcon) private var menuBar = true

    var body: some Scene {
        Window(Flavor.name, id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1220, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Menu("New Item") {
                    ForEach(CipherType.allCases, id: \.self) { t in Button(t.label) { model.newItem(t) } }
                }
                .disabled(model.phase != .unlocked)
                Button("New Login") { model.newItem(.login) }.keyboardShortcut("n").disabled(model.phase != .unlocked)
            }
            CommandMenu("Vault") {
                Button("Sync") { Task { await model.sync() } }.keyboardShortcut("r").disabled(model.phase != .unlocked)
                Button("Lock") { model.lock() }.keyboardShortcut("l").disabled(model.phase != .unlocked)
                Divider()
                Button("Generator") { model.sidebar = .generator }.keyboardShortcut("g").disabled(model.phase != .unlocked)
                Button("Send") { model.sidebar = .sends }.disabled(model.phase != .unlocked)
                Divider()
                Button("Copy Username") { model.copy(model.cipher(model.selectedId)?.login?.username, "username", sensitive: false) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Copy Password") {
                    if let c = model.cipher(model.selectedId) { model.withReprompt(c) { model.copy(c.login?.password, "password") } }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Copy Verification Code") {
                    if let t = model.cipher(model.selectedId)?.login?.totp { model.copy(TOTP(t)?.code(), "code") }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra(Flavor.name, systemImage: Flavor.isDev ? "hammer" : "lock.shield", isInserted: $menuBar) {
            MenuBarView().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            applyAppearance(Prefs.d.string(forKey: Prefs.appearance) ?? "system")
            AutofillController.shared.start()
            BackgroundMode.shared.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
