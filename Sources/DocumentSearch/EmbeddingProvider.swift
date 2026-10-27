import Foundation

/// Which embedding space a set of vectors lives in. Vectors from different profiles are never compared.
public struct EmbeddingProfile: Hashable, Sendable {
    public var revision: String
    public var dimension: Int

    public init(revision: String, dimension: Int) {
        self.revision = revision
        self.dimension = dimension
    }
}

public enum EmbeddingAvailability: Equatable, Sendable {
    case available(EmbeddingProfile)
    /// No usable model right now. Search falls back to the lexical index.
    case unavailable
}

/// Supplies embeddings. The revision and dimension come from the provider at runtime and are never assumed.
public protocol EmbeddingProvider: Sendable {
    func availability() async -> EmbeddingAvailability
    /// One vector per text, in order, each with the profile's dimension.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// A stable, model-free provider for tests and diagnostics. Words hash into buckets, so texts that share
/// words are close in cosine distance. It uses FNV-1a rather than `hashValue`, which is seeded per process.
public struct DeterministicEmbeddingProvider: EmbeddingProvider {
    public var profile: EmbeddingProfile
    public var isAvailable: Bool

    public init(revision: String = "deterministic-1", dimension: Int = 64, isAvailable: Bool = true) {
        self.profile = EmbeddingProfile(revision: revision, dimension: dimension)
        self.isAvailable = isAvailable
    }

    public func availability() async -> EmbeddingAvailability {
        isAvailable ? .available(profile) : .unavailable
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map(vector)
    }

    private func vector(for text: String) -> [Float] {
        var result = [Float](repeating: 0, count: profile.dimension)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in word.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            result[Int(hash % UInt64(profile.dimension))] += 1
        }
        let length = result.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? result.map { $0 / length } : result
    }
}
