#if DEBUG
import Foundation

/// Fixtures and accessibility markers only. Tests always use the real window's layout traits.
enum LayoutUITest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-layout-ui-test") }
    static var exposesMarkers: Bool { ProcessInfo.processInfo.arguments.contains { $0.hasSuffix("-ui-test") } }
}
#endif
