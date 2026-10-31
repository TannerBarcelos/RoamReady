#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage

/// Apple's downloadable English contextual embedding model, shared by the app and eval command.
/// The profile identifies the model and pooling algorithm so incompatible vectors are never compared.
public actor NaturalLanguageEmbeddingProvider: EmbeddingProvider {
    private enum Failure: Error { case unavailable, noUsableVector }
    private var contextual: NLContextualEmbedding?
    private var isLoaded = false
    private let assets = EmbeddingAssetPreparation()
    private var reportedStatus: String?
    private static let maximumCharacters = 1_000

    public init() {}

    public func availability() async -> EmbeddingAvailability {
        guard let model = usableModel() else { return .unavailable }
        return .available(profile(for: model))
    }

    /// Asset preparation is explicit: normal availability/search calls never wait for a download.
    /// Concurrent callers share the OS request. The app reconciles its index when preparation finishes.
    @discardableResult
    public func prepare() async -> EmbeddingAvailability {
        if let model = usableModel() { return .available(profile(for: model)) }
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
            let result = try model.embeddingResult(for: text, language: .english)
            var pool = EmbeddingVectorPool(dimension: model.dimension)
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                pool.add(vector)
                return true
            }
            guard let vector = pool.normalized() else { throw Failure.noUsableVector }
            return vector
        }
    }

    private func usableModel() -> NLContextualEmbedding? {
        if isLoaded { return contextual }
        if contextual == nil { contextual = NLContextualEmbedding(language: .english) }
        guard let contextual, contextual.dimension > 0 else {
            report("no English contextual model supported; document search remains lexical")
            return nil
        }
        guard contextual.hasAvailableAssets else { return nil }
        do {
            try contextual.load()
            isLoaded = true
            let profile = profile(for: contextual)
            report("ready revision=\(profile.revision) dimension=\(profile.dimension)")
            return contextual
        } catch {
            report("contextual model failed to load (error code \((error as NSError).code)); document search remains lexical")
            return nil
        }
    }

    private func profile(for model: NLContextualEmbedding) -> EmbeddingProfile {
        EmbeddingProfile(revision: "NLContextualEmbedding.\(model.modelIdentifier).\(model.revision).mean-l2-v1",
                         dimension: model.dimension)
    }

    private func report(_ status: String) {
        guard status != reportedStatus else { return }
        reportedStatus = status
        NSLog("DOCUMENT-EMBEDDINGS: %@", status)
    }
}
#endif
