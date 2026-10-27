/// Whether a scene should use the iPhone Duo workspace, driven by hinge reports.
///
/// The hinge is a property of the device, so one report is enough. A nil report only means the
/// observing view left a hierarchy that provides hinge updates (for example while SwiftUI
/// re-parents it), so it never turns the workspace back off.
public struct HingeCapability: Equatable, Sendable {
    public private(set) var usesDuoWorkspace: Bool

    /// - Parameter forced: Turns the workspace on without hardware, for debug UI tests.
    public init(forced: Bool = false) {
        usesDuoWorkspace = forced
    }

    /// Records one hinge update, including the initial one delivered when observation starts.
    public mutating func record(hingeReported: Bool) {
        if hingeReported { usesDuoWorkspace = true }
    }
}
