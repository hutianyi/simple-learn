import XCTest
@testable import StudyShell

final class AudioOwnershipTests: XCTestCase {
    func testOldOwnerAndOldRevisionCannotTakeOverAfterSwitch() {
        var ownership = AudioOwnership()
        ownership.select("ji")
        let old = ownership.revision
        XCTAssertTrue(ownership.permits("ji", revision: old))
        ownership.select("ting")
        XCTAssertFalse(ownership.permits("ji", revision: old))
        ownership.select("ji")
        XCTAssertFalse(ownership.permits("ji", revision: old))
        XCTAssertTrue(ownership.permits("ji", revision: ownership.revision))
        ownership.select(nil)
        XCTAssertFalse(ownership.permits("ji", revision: ownership.revision))
    }
}
