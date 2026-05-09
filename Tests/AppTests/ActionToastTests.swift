import XCTest
import TaskTickCore
@testable import TaskTickApp

final class ActionToastTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Pin the L10n bundle to English regardless of host machine locale,
        // so test assertions on title strings are deterministic.
        L10n.reloadBundle(for: .en)
    }

    override func tearDown() {
        // Restore the system-default bundle so other tests in the same process
        // aren't pinned to English (L10n._bundle is process-global).
        L10n.reloadBundle(for: .system)
        super.tearDown()
    }

    func testStartedTitleAndBody() {
        let (title, body) = ActionToast.previewContent(for: .started(taskName: "Backup"))
        XCTAssertEqual(title, "Started")           // English locale assumed in test env
        XCTAssertEqual(body, "Backup")
    }

    func testStoppedRestartedFailedBodies() {
        XCTAssertEqual(ActionToast.previewContent(for: .stopped(taskName: "X")).title, "Stopped")
        XCTAssertEqual(ActionToast.previewContent(for: .restarted(taskName: "X")).title, "Restarted")
        let failed = ActionToast.previewContent(for: .failed(taskName: "X", reason: "not found"))
        XCTAssertEqual(failed.title, "Action failed")
        XCTAssertTrue(failed.body.contains("X"))
        XCTAssertTrue(failed.body.contains("not found"))
    }

    func testFailedWithoutTaskNameUsesReasonOnly() {
        let (_, body) = ActionToast.previewContent(for: .failed(taskName: nil, reason: "unknown id"))
        XCTAssertEqual(body, "unknown id")
    }
}
