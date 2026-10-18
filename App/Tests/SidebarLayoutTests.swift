import XCTest

final class SidebarLayoutTests: AppTestCase {
    var layout: SidebarLayout { SidebarLayout.shared }
    var library: [String] { layout.items(.library).map(\.key) }

    func testReorderingVisibleItemsKeepsHiddenOnesInPlace() {
        layout.setVisible(.favorites, false)
        XCTAssertEqual(layout.visibleItems(.library).map(\.key), ["all", "codes", "passkeys", "security", "trash"])
        layout.moveItems(.library, IndexSet(integer: 0), 3, visibleOnly: true)
        XCTAssertEqual(library, ["codes", "favorites", "passkeys", "all", "security", "trash"])
        layout.moveItems(.library, IndexSet(integer: 5), 0, visibleOnly: false)
        XCTAssertEqual(library, ["trash", "codes", "favorites", "passkeys", "all", "security"])
        XCTAssertEqual(Prefs.codable("sidebarLayout", default: SidebarLayout.State()), layout.state)
    }

    func testDroppingAnItemTakesTheTargetSlot() {
        layout.move("trash", before: .codes)
        XCTAssertEqual(library, ["all", "favorites", "trash", "codes", "passkeys", "security"])
        layout.move("all", before: .passkeys)
        XCTAssertEqual(library, ["favorites", "trash", "codes", "passkeys", "all", "security"])
        layout.move("all", before: .all)
        layout.move("type.1", before: .all)
        XCTAssertEqual(library, ["favorites", "trash", "codes", "passkeys", "all", "security"])
    }

    func testHidingTheSelectionSelectsTheNextVisibleItem() {
        model.sidebar = .favorites
        model.selectedId = "x"
        layout.setVisible(.favorites, false)
        XCTAssertEqual(model.sidebar, .all)
        XCTAssertNil(model.selectedId)

        layout.setVisible(.library, false)
        XCTAssertEqual(model.sidebar, .type(.login))
        XCTAssertEqual(layout.visibleSections.first, .vaults)

        layout.moveSections(IndexSet(integer: 4), 0)
        XCTAssertEqual(layout.state.sections.first, .tools)
        layout.reset()
        XCTAssertEqual(layout.state, SidebarLayout.State(order: layout.state.order))
        XCTAssertTrue(layout.isVisible(.library) && layout.isVisible(SidebarItem.favorites))
    }
}
