import Foundation

/// Contextual models emit token vectors. Pool the whole passage into one unit vector for cosine search.
/// Invalid or cancelling vectors produce no vector, allowing the index to retain lexical search instead.
struct EmbeddingVectorPool {
    private var sum: [Double]
    private var count = 0
    private var valid = true

    init(dimension: Int) { sum = Array(repeating: 0, count: max(0, dimension)) }

    mutating func add(_ vector: [Double]) {
        guard vector.count == sum.count, vector.allSatisfy(\.isFinite) else { valid = false; return }
        for index in sum.indices { sum[index] += vector[index] }
        count += 1
    }

    func normalized() -> [Float]? {
        guard valid, count > 0, !sum.isEmpty else { return nil }
        let length = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length.isFinite, length > 0 else { return nil }
        let result = sum.map { Float($0 / length) }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
}
