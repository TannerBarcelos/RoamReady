#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage

/// Prefer Apple's sentence vectors. If that OS asset is missing, use a contextual model whose assets
/// the app can request. Each backend has its own profile, so the index never mixes their vectors.
public actor NaturalLanguageEmbeddingProvider: EmbeddingProvider {
    private enum Model {
        case sentence(NLEmbedding)
        case contextual(NLContextualEmbedding)

        var profile: EmbeddingProfile {
            switch self {
            case .sentence(let model):
                EmbeddingProfile(revision: "NLEmbedding.sentence.en.\(model.revision)", dimension: model.dimension)
            case .contextual(let model):
                EmbeddingProfile(revision: "NLContextualEmbedding.\(model.modelIdentifier).\(model.revision).mean-l2-v1",
                                 dimension: model.dimension)
            }
        }
    }

    private enum Failure: Error { case unavailable, noUsableVector }
    private var selected: Model?
    private var checkedSentenceModel = false
    private var contextual: NLContextualEmbedding?
    private let assets = EmbeddingAssetPreparation()
    private var reportedStatus: String?
    private static let maximumCharacters = 1_000

    public init() {}

    public func availability() async -> EmbeddingAvailability {
        guard let model = usableModel() else { return .unavailable }
        return .available(model.profile)
    }

    /// Asset preparation is explicit: normal availability/search calls never wait for a download.
    /// Concurrent callers share the OS request. The app reconciles its index when preparation finishes.
    @discardableResult
    public func prepare() async -> EmbeddingAvailability {
        if let model = usableModel() { return .available(model.profile) }
        guard contextual != nil, !Task.isCancelled else { return .unavailable }
        _ = await assets.request { await self.requestAssets() }
        guard !Task.isCancelled else { return .unavailable }
        return await availability()
    }

    private func requestAssets() async -> Bool {
        guard let contextual else { return false }
        report("requesting English contextual embedding assets; document search remains lexical")
        return await withCheckedContinuation { continuation in
            contextual.requestAssets { result, error in
                if result != .available {
                    NSLog("DOCUMENT-EMBEDDINGS: asset request result=%ld errorCode=%ld", result.rawValue,
                          (error as NSError?)?.code ?? 0)
                }
                continuation.resume(returning: result == .available)
            }
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let model = usableModel() else { throw Failure.unavailable }
        return try texts.map { original in
            try Task.checkCancellation()
            let text = String(original.prefix(Self.maximumCharacters))
            switch model {
            case .sentence(let sentence):
                guard let vector = sentence.vector(for: text), vector.count == sentence.dimension,
                      vector.allSatisfy(\.isFinite) else { throw Failure.noUsableVector }
                let result = vector.map { Float($0) }
                guard result.allSatisfy(\.isFinite) else { throw Failure.noUsableVector }
                return result
            case .contextual(let contextual):
                let result = try contextual.embeddingResult(for: text, language: .english)
                var pool = EmbeddingVectorPool(dimension: contextual.dimension)
                result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                    pool.add(vector)
                    return true
                }
                guard let vector = pool.normalized() else { throw Failure.noUsableVector }
                return vector
            }
        }
    }

    private func usableModel() -> Model? {
        if let selected { return selected }
        if !checkedSentenceModel {
            checkedSentenceModel = true
            if let sentence = NLEmbedding.sentenceEmbedding(for: .english), sentence.dimension > 0 {
                return select(.sentence(sentence))
            }
            report("English sentence embedding asset missing; checking contextual fallback")
        }
        if contextual == nil { contextual = NLContextualEmbedding(language: .english) }
        guard let contextual, contextual.dimension > 0 else {
            report("no English contextual model supported; document search remains lexical")
            return nil
        }
        guard contextual.hasAvailableAssets else { return nil }
        do {
            try contextual.load()
            return select(.contextual(contextual))
        } catch {
            report("contextual model failed to load (error code \((error as NSError).code)); document search remains lexical")
            return nil
        }
    }

    private func select(_ model: Model) -> Model {
        selected = model
        report("ready revision=\(model.profile.revision) dimension=\(model.profile.dimension)")
        return model
    }

    private func report(_ status: String) {
        guard status != reportedStatus else { return }
        reportedStatus = status
        NSLog("DOCUMENT-EMBEDDINGS: %@", status)
    }
}
#endif
