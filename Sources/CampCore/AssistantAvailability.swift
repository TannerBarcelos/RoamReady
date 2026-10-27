/// The Assistant's presentation state, shared by the global chat and trip/checklist help.
public enum AssistantAvailability: Equatable, Sendable {
    case ready, unsupported, disabled, preparing, unavailable, unsupportedLanguage

    /// Supported hardware keeps the chat button so disabled or preparing AI can explain how to recover.
    public var showsChatButton: Bool { self != .unsupported }
    public var showsConversation: Bool { self == .ready }

    public var title: String {
        switch self {
        case .ready: "How can I help?"
        case .unsupported: "AI isn’t supported on this device"
        case .disabled: "Turn on Apple Intelligence"
        case .preparing: "Apple Intelligence is getting ready"
        case .unavailable: "AI is currently unavailable"
        case .unsupportedLanguage: "This language isn’t supported"
        }
    }

    public var message: String {
        switch self {
        case .ready: "Ask about camping, your rig, or something that isn’t working."
        case .unsupported: "Assistant requires an iPhone, iPad, or Mac that supports Apple Intelligence."
        case .disabled: "Enable Apple Intelligence in Settings › Apple Intelligence & Siri, then return here."
        case .preparing: "Your on-device model is still downloading or preparing. Check Apple Intelligence in Settings and try again when it’s ready."
        case .unavailable: "Apple’s on-device AI can’t answer right now. Try again in a moment."
        case .unsupportedLanguage: "Choose a language supported by Apple Intelligence in Settings, then try again."
        }
    }
}
