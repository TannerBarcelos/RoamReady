import Foundation
import NaturalLanguage
import DocumentSearch

/// Apple's English sentence embeddings. The revision and dimension are read from the model at runtime, never
/// assumed, so an OS update that ships a new model retires the old vectors instead of mixing the two.
/// When the model isn't on the device the provider reports itself unavailable and search stays lexical.
struct AppleEmbeddingProvider: EmbeddingProvider {
    /// Keeps each input within what a sentence embedding handles; passages are bounded already.
    private static let maximumCharacters = 1_000

    private func model() -> NLEmbedding? { NLEmbedding.sentenceEmbedding(for: .english) }

    func availability() async -> EmbeddingAvailability {
        guard let model = model(), model.dimension > 0 else { return .unavailable }
        return .available(EmbeddingProfile(revision: "NLEmbedding.sentence.en.\(model.revision)", dimension: model.dimension))
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let model = model() else { throw CocoaError(.featureUnsupported) }
        // A text the model can't embed gets a neutral unit vector: it ranks by words alone rather than
        // failing the whole document.
        let neutral = [Float](repeating: 1 / Float(model.dimension).squareRoot(), count: model.dimension)
        return try texts.map { text in
            try Task.checkCancellation()
            guard let vector = model.vector(for: String(text.prefix(Self.maximumCharacters))), vector.count == model.dimension,
                  vector.allSatisfy(\.isFinite) else { return neutral }
            return vector.map { Float($0) }
        }
    }
}
