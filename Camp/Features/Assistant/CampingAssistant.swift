import Foundation
import CampCore
import Darwin
#if canImport(FoundationModels)
import FoundationModels
#endif

struct CampingAnswer: Sendable {
    let text: String
    let mode: String
    let sourceURL: String?
    var isGenerated = false
}

/// Saved guidance remains available on every device. Generative help uses Apple only.
@MainActor
enum CampingAssistant {
    private static var machineIdentifier: String {
        #if targetEnvironment(simulator)
        return "simulator"
        #else
        var system = utsname()
        guard uname(&system) == 0 else { return "" }
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
    }

    private static var meetsDevicePolicy: Bool {
        AssistantDevicePolicy.permitsGenerativeAI(machineIdentifier: machineIdentifier)
    }

    static var globalAvailability: AssistantAvailability {
        #if DEBUG
        if let simulated = uiTestingAvailability { return simulated }
        #endif
        guard AssistantDevicePolicy.supportsGlobalChat(machineIdentifier: machineIdentifier) else { return .unsupported }
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return SystemLanguageModel.default.supportsLocale() ? .ready : .unsupportedLanguage
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unsupported
            case .appleIntelligenceNotEnabled: return .disabled
            case .modelNotReady: return .preparing
            @unknown default: return .unavailable
            }
        @unknown default: return .unavailable
        }
        #else
        return .unsupported
        #endif
    }

    static var showsGlobalChat: Bool { globalAvailability.showsTab }

    #if DEBUG
    static var isRunningAssistantUITests: Bool {
        uiTestingAvailability != nil || ProcessInfo.processInfo.arguments.contains("-assistant-device-smoke")
    }

    /// Deterministic UI tests on Simulator, where Foundation Models cannot run.
    static var uiTestingAvailability: AssistantAvailability? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-assistant-ui-test"),
              arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case "ready": return .ready
        case "disabled": return .disabled
        case "preparing": return .preparing
        case "unsupported": return .unsupported
        case "unavailable": return .unavailable
        case "unsupported-language": return .unsupportedLanguage
        default: return nil
        }
    }
    #endif

    /// One clear status line; every Apple unavailability reason maps to its own explanation.
    static var availability: String {
        guard meetsDevicePolicy else {
            return "Saved guidance available · AI help requires iPhone 15 or newer"
        }
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return "Apple on-device AI available · Works offline"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "Saved guidance available · This iPhone doesn’t support Apple Intelligence (iPhone 15 Pro or later)"
            case .appleIntelligenceNotEnabled: return "Saved guidance available · Turn on Apple Intelligence in Settings to use AI help"
            case .modelNotReady: return "Saved guidance available · Apple’s AI model is still downloading or preparing. Try again later."
            @unknown default: return "Saved guidance available · Apple AI is currently unavailable"
            }
        @unknown default: return "Saved guidance available · Apple AI is currently unavailable"
        }
        #else
        return "Saved guidance available · Apple AI requires a supported system version"
        #endif
    }

    /// General chat can answer without checklist matches; trip help stays grounded in saved steps.
    static func answer(question: String, steps candidates: [ChecklistStepDraft], rigType: RigType?, step: ChecklistStepDraft?,
                       scope: CampingHelpRequest.Scope = .checklist, history: [CampingChatTurn] = []) async throws -> CampingAnswer {
        try Task.checkCancellation()
        let lower = question.lowercased()
        let hazardWords = ["smell gas", "gas smell", "propane leak", "carbon monoxide", "co alarm", "smoke", "sparking", "electric shock", "fire in", "gas leak"]
        if hazardWords.contains(where: lower.contains) {
            return CampingAnswer(text: "Stop setup and move everyone to a safe location away from the rig. Do not operate switches, ignite flames, or attempt repairs around a suspected gas leak. Contact emergency services for an immediate hazard, and campground staff or a qualified RV technician. Do not re-enter until it is safe.", mode: "Safety guidance", sourceURL: ChecklistFactory.sourceURL)
        }
        let request = CampingHelpRequest(question: question, steps: candidates, rigType: rigType,
                                         step: step, scope: scope, history: history)
        let passages = request.passages
        let fallback = passages.isEmpty
            ? "I don’t have saved guidance for that question. Check your rig or equipment manual, or contact campground staff or a qualified RV technician. Try a specific equipment or setup question, or open a checklist step for saved guidance. Your checklists and notes remain available offline."
            : passages + "\n\nThese are your saved checklist notes, which may include your own edits. Follow the equipment manufacturer’s instructions if they differ."
        if request.allowsGeneration {
            do {
                let text: String
                #if DEBUG
                if let generator = uiTestGenerator {
                    text = try await CampingGeneration.reply(to: request, using: generator)
                } else {
                    text = try await generate(request)
                }
                #else
                text = try await generate(request)
                #endif
                return CampingAnswer(text: text, mode: "Apple AI · Generated on this iPhone · Check against your manual",
                                     sourceURL: passages.isEmpty ? nil : ChecklistFactory.sourceURL, isGenerated: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // General chat must surface model failures; a checklist quotation is not an AI reply.
                if scope == .general { throw (error as? CampingChatFailure) ?? .failed }
            }
        }
        return CampingAnswer(text: fallback, mode: passages.isEmpty ? "AI unavailable · No matching saved guidance" : "Saved offline guidance", sourceURL: passages.isEmpty ? nil : ChecklistFactory.sourceURL)
    }

    private static func generate(_ request: CampingHelpRequest) async throws -> String {
        #if canImport(FoundationModels)
        guard meetsDevicePolicy else { throw CampingChatFailure.notReady }
        return try await CampingGeneration.reply(to: request, using: AppleCampingResponseGenerator())
        #else
        throw CampingChatFailure.notReady
        #endif
    }

    #if DEBUG
    private struct UITestGenerator: CampingResponseGenerating {
        let fails: Bool
        func respond(to prompt: String, instructions: String) async throws -> String {
            if fails { throw CampingChatFailure.failed }
            return "Test response: keep drinking water in a clean, covered container."
        }
    }

    private static var uiTestGenerator: UITestGenerator? {
        guard uiTestingAvailability == .ready else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-assistant-generation-test"),
              arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case "reply": return UITestGenerator(fails: false)
        case "failure": return UITestGenerator(fails: true)
        default: return nil
        }
    }
    #endif

}
