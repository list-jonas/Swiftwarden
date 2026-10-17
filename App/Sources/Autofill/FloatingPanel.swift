import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingPanel {
    private let panel: KeyablePanel

    init(canKey: Bool) {
        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.keyable = canKey
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = !canKey
        panel.isReleasedWhenClosed = false
    }

    var visible: Bool { panel.isVisible }

    func show(_ view: some View, near field: CGRect, key: Bool = false) {
        let host = NSHostingView(rootView: AnyView(view))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.contentView = host
        let screen = NSScreen.screens.first { $0.frame.intersects(field) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        var origin = CGPoint(x: field.minX, y: field.minY - size.height - 6)
        if origin.y < vis.minY { origin.y = field.maxY + 6 }
        origin.x = min(max(origin.x, vis.minX + 4), vis.maxX - size.width - 4)
        origin.y = min(max(origin.y, vis.minY + 4), vis.maxY - size.height - 4)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        if key { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
    }

    func hide() { panel.orderOut(nil) }
}
