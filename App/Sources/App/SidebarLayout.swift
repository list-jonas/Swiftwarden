import AppKit
import SwiftUI
import SwiftwardenCore

enum SidebarSection: String, Codable, CaseIterable, Identifiable {
    case library, vaults, types, folders, tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .vaults: "Vaults"
        case .types: "Types"
        case .folders: "Folders"
        case .tools: "Tools"
        }
    }

    var symbol: String {
        switch self {
        case .library: "square.grid.2x2"
        case .vaults: "building.columns"
        case .types: "square.stack"
        case .folders: "folder"
        case .tools: "wrench.and.screwdriver"
        }
    }

    var defaultItems: [SidebarItem] {
        switch self {
        case .library: [.all, .favorites, .codes, .passkeys, .security, .trash]
        case .types: CipherType.allCases.map { .type($0) }
        case .tools: [.sends, .generator]
        case .vaults, .folders: []
        }
    }

    var reorderable: Bool { !defaultItems.isEmpty }
}

extension SidebarItem {
    var key: String {
        switch self {
        case .all: "all"
        case .favorites: "favorites"
        case .codes: "codes"
        case .passkeys: "passkeys"
        case .security: "security"
        case .trash: "trash"
        case let .type(t): "type.\(t.rawValue)"
        case let .folder(id): "folder.\(id ?? "none")"
        case let .collection(id): "collection.\(id)"
        case let .organization(id): "org.\(id)"
        case .personal: "personal"
        case .sends: "sends"
        case .generator: "generator"
        }
    }

    var section: SidebarSection {
        switch self {
        case .all, .favorites, .codes, .passkeys, .security, .trash: .library
        case .type: .types
        case .folder: .folders
        case .collection, .organization, .personal: .vaults
        case .sends, .generator: .tools
        }
    }

    var symbol: String {
        switch self {
        case .all: "key.fill"
        case .favorites: "star.fill"
        case .codes: "lock.rotation"
        case .passkeys: "person.badge.key.fill"
        case .security: "exclamationmark"
        case .trash: "trash.fill"
        case let .type(t): t.symbol
        case .folder(nil): "folder.badge.questionmark"
        case .folder, .collection: "folder"
        case .organization: "folder.badge.person.crop"
        case .personal: "person.crop.circle"
        case .sends: "paperplane"
        case .generator: "wand.and.stars"
        }
    }

    var tint: Color {
        switch self {
        case .all: Palette.blue
        case .favorites: Palette.yellow
        case .codes: Palette.cyan
        case .passkeys: Palette.green
        case .security: Palette.red
        case .trash: Palette.orange
        case let .type(t): typeColor(t)
        default: .accentColor
        }
    }

    var label: String {
        if case let .type(t) = self { return t.label }
        return title
    }
}

@MainActor @Observable
final class SidebarLayout {
    static let shared = SidebarLayout()

    struct State: Codable, Equatable {
        var sections = SidebarSection.allCases
        var hiddenSections: Set<SidebarSection> = []
        var collapsed: Set<SidebarSection> = []
        var order: [SidebarSection: [String]] = [:]
        var hidden: Set<String> = []
    }

    private static let key = "sidebarLayout"

    var state: State {
        didSet { if state != oldValue { Prefs.setCodable(Self.key, state); fixSelection() } }
    }

    private init() {
        state = Self.normalized(Prefs.codable(Self.key, default: State()))
    }

    private static func normalized(_ s: State) -> State {
        var s = s
        var seen = Set<SidebarSection>()
        s.sections = s.sections.filter { seen.insert($0).inserted }
        s.sections += SidebarSection.allCases.filter { !seen.contains($0) }
        for sec in SidebarSection.allCases where sec.reorderable {
            let all = sec.defaultItems.map(\.key)
            let kept = (s.order[sec] ?? []).filter { all.contains($0) }
            s.order[sec] = kept + all.filter { !kept.contains($0) }
        }
        return s
    }

    func items(_ s: SidebarSection) -> [SidebarItem] {
        let byKey = Dictionary(uniqueKeysWithValues: s.defaultItems.map { ($0.key, $0) })
        return (state.order[s] ?? []).compactMap { byKey[$0] }
    }

    func visibleItems(_ s: SidebarSection) -> [SidebarItem] { items(s).filter(isVisible) }

    var visibleSections: [SidebarSection] { state.sections.filter { !state.hiddenSections.contains($0) } }

    func isVisible(_ i: SidebarItem) -> Bool { !state.hidden.contains(i.key) }

    func setVisible(_ i: SidebarItem, _ on: Bool) {
        if on { state.hidden.remove(i.key) } else { state.hidden.insert(i.key) }
    }

    func isVisible(_ s: SidebarSection) -> Bool { !state.hiddenSections.contains(s) }

    func setVisible(_ s: SidebarSection, _ on: Bool) {
        if on { state.hiddenSections.remove(s) } else { state.hiddenSections.insert(s) }
    }

    func expanded(_ s: SidebarSection) -> Binding<Bool> {
        Binding(get: { !self.state.collapsed.contains(s) },
                set: { if $0 { self.state.collapsed.remove(s) } else { self.state.collapsed.insert(s) } })
    }

    func moveSections(_ from: IndexSet, _ to: Int) { state.sections.move(fromOffsets: from, toOffset: to) }

    func moveItems(_ s: SidebarSection, _ from: IndexSet, _ to: Int, visibleOnly: Bool) {
        var keys = state.order[s] ?? []
        if visibleOnly {
            var vis = keys.filter { !state.hidden.contains($0) }
            vis.move(fromOffsets: from, toOffset: to)
            var it = vis.makeIterator()
            keys = keys.map { state.hidden.contains($0) ? $0 : it.next()! }
        } else {
            keys.move(fromOffsets: from, toOffset: to)
        }
        state.order[s] = keys
    }

    func move(_ key: String, before target: SidebarItem) {
        let s = target.section
        guard var keys = state.order[s], let from = keys.firstIndex(of: key), key != target.key else { return }
        keys.remove(at: from)
        let to = keys.firstIndex(of: target.key).map { $0 + (from > $0 ? 0 : 1) } ?? keys.endIndex
        keys.insert(key, at: min(to, keys.endIndex))
        state.order[s] = keys
    }

    func reset() { state = Self.normalized(State()) }

    private func fixSelection() {
        let model = AppModel.shared
        guard let sel = model.sidebar, !isVisible(sel) || !isVisible(sel.section) else { return }
        let fallback = visibleSections.lazy.compactMap { self.visibleItems($0).first }.first ?? .all
        model.sidebar = fallback
        model.selectedId = nil
    }
}

@MainActor @Observable
final class CommandKey {
    static let shared = CommandKey()
    private(set) var down = NSEvent.modifierFlags.contains(.command)
    @ObservationIgnored private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            let d = e.modifierFlags.contains(.command)
            MainActor.assumeIsolated { if CommandKey.shared.down != d { CommandKey.shared.down = d } }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CommandKey.shared.down = false }
        }
    }
}

extension View {
    @ViewBuilder
    func draggable(_ key: String, when on: Bool) -> some View {
        if on { draggable(key) } else { self }
    }
}
