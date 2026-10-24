import Foundation
import StoreKBSync
import XCTest

final class StoreKBSyncTests: XCTestCase {
    func testInvalidIdentifiers() {
        for guid in ["", "00010203040Z", "00:01:02:03:04:05", "000102030405FF"] {
            XCTAssertThrowsError(try StoreKBSync.generate(guid: guid, dsid: 1))
        }
        XCTAssertThrowsError(try StoreKBSync.generate(guid: "000102030405", dsid: 0))
    }

    func testSyntheticGenerationWithoutJIT() throws {
        // Synthetic account/device only; this test makes no network requests.
        let value = try StoreKBSync.generate(guid: "000102030405", dsid: 1)
        let data = try XCTUnwrap(Data(base64Encoded: value))
        XCTAssertFalse(data.isEmpty)
        XCTAssertLessThanOrEqual(data.count, 64 * 1024)
        XCTAssertEqual(value, data.base64EncodedString())
    }
}
