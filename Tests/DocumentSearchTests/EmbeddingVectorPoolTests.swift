import XCTest
@testable import DocumentSearch

final class EmbeddingVectorPoolTests: XCTestCase {
    func testPoolingIncludesEveryTokenAndProducesAUnitVector() throws {
        var pool = EmbeddingVectorPool(dimension: 2)
        pool.add([3, 0])
        pool.add([0, 4])
        let vector = try XCTUnwrap(pool.normalized())
        XCTAssertEqual(vector[0], 0.6, accuracy: 0.00001)
        XCTAssertEqual(vector[1], 0.8, accuracy: 0.00001)
        XCTAssertEqual(vector.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 0.00001)
    }

    func testUnusableTokensCannotPublishFabricatedVectors() {
        for token in [[Double.nan, 0], [Double.infinity, 1], [Double(1)], [Double.greatestFiniteMagnitude, 0]] {
            var pool = EmbeddingVectorPool(dimension: 2)
            pool.add([1, 0])
            pool.add(token)
            XCTAssertNil(pool.normalized())
        }
        var cancelling = EmbeddingVectorPool(dimension: 2)
        cancelling.add([1, 2]); cancelling.add([-1, -2])
        XCTAssertNil(cancelling.normalized())
        XCTAssertNil(EmbeddingVectorPool(dimension: 2).normalized())
        var empty = EmbeddingVectorPool(dimension: 0)
        empty.add([])
        XCTAssertNil(empty.normalized())
    }
}
