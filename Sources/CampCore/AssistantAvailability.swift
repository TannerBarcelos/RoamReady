/// The global Assistant's presentation state. Trip/checklist saved help has its own fallback.
public enum AssistantAvailability: Equatable, Sendable {
    case ready, unsupported, disabled, preparing, unavailable

    public var showsTab: Bool { self != .unsupported }
    public var showsConversation: Bool { self == .ready }

    public var title: String {
        switch self {
        case .ready: "How can I help?"
        case .unsupported: "AI isn’t supported on this device"
        case .disabled: "Turn on Apple Intelligence"
        case .preparing: "Apple Intelligence is getting ready"
        case .unavailable: "AI is currently unavailable"
        }
    }

    public var message: String {
        switch self {
        case .ready: "Ask about camping, your rig, or something that isn’t working."
        case .unsupported: "Assistant requires a supported iPhone with Apple Intelligence. Your saved trip and checklist guidance is still available."
        case .disabled: "Enable Apple Intelligence in Settings › Apple Intelligence & Siri, then return here. Your saved trip and checklist guidance is still available."
        case .preparing: "Your on-device model is still downloading or preparing. Check Apple Intelligence in Settings and try again when it’s ready."
        case .unavailable: "Apple’s on-device AI can’t answer right now. Try again in a moment. Your saved trip and checklist guidance is still available."
        }
    }
}
