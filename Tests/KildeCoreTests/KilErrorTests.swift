import XCTest
@testable import KildeCore

final class KilErrorTests: XCTestCase {
    /// 終了コードは CLI の契約 (DESIGN.md §6 / CLAUDE.md §4)。成功 (0) は KilError を
    /// 経由しないのでここでは固定できない — 失敗系 1/2/3 の写像だけを固定する。
    func testExitCodeContractForKilErrors() {
        XCTAssertEqual(KilError.failed("failure").exitCode, 1)
        XCTAssertEqual(KilError.permission("permission").exitCode, 2)
        XCTAssertEqual(KilError.deviceNotFound("device").exitCode, 3)
    }
}
