import XCTest

extension XCUIApplication {
    /// iPhone exposes tab buttons under a TabBar. iPad's floating tabs are exposed as Cells.
    /// Match the actual selectable controls, excluding same-named navigation titles and text.
    func navigationTab(_ title: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(
            format: "(label == %@ OR identifier == %@) AND (elementType == %@ OR elementType == %@)",
            title, title,
            NSNumber(value: XCUIElement.ElementType.button.rawValue),
            NSNumber(value: XCUIElement.ElementType.cell.rawValue)
        )).firstMatch
    }

    /// Ask Assistant as a native bar item. Duo's open layout can show trailing items in a vertical
    /// toolbar instead of the navigation bar, so both are checked.
    var barAssistantButton: XCUIElement {
        descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %@ OR elementType == %@",
            NSNumber(value: XCUIElement.ElementType.navigationBar.rawValue),
            NSNumber(value: XCUIElement.ElementType.toolbar.rawValue)
        )).descendants(matching: .button)["openAssistant"].firstMatch
    }
}
