import XCTest
@testable import StudyShell

final class ModuleSessionTests: XCTestCase {
    @MainActor func testFinishingOneTaskDoesNotReleaseAnotherActiveTask() {
        let session = ModuleSession()
        session.setBusy(true, reason: "study")
        session.setBusy(true, reason: "backup")
        session.setBusy(false, reason: "backup")
        XCTAssertFalse(session.canLeave)
        session.setBusy(false, reason: "study")
        XCTAssertTrue(session.canLeave)
    }
}
