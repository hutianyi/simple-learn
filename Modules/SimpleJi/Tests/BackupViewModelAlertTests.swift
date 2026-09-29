import Foundation
import XCTest
@testable import WordMemoryCards

@MainActor
final class BackupViewModelAlertTests: XCTestCase {
    func testResetRequestSelectsConfirmationAlert() {
        let controller = PersistenceController(inMemory: true)
        let suiteName = "BackupViewModelAlertTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let viewModel = BackupViewModel(
            container: controller.container,
            settings: settings
        )

        viewModel.requestResetConfirmation()

        guard case .confirmReset = viewModel.alertState else {
            XCTFail("点击清除按钮后必须进入二次确认状态")
            return
        }
    }
}
