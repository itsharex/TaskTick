import XCTest
import Foundation
@testable import tasktick

final class EventsCommandTests: XCTestCase {

    /// Smoke test: the formatter produces a valid NDJSON line with the right shape.
    func testStartedNotificationProducesNDJSONLine() throws {
        let id = UUID()
        let line = EventsCommand.formatStartedLine(id: id.uuidString,
                                                   executionId: "exec-1",
                                                   ts: "2026-05-08T10:00:00Z")
        // Must be valid JSON, single line, ends with newline.
        XCTAssertTrue(line.hasSuffix("\n"))
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "started")
        XCTAssertEqual(json?["id"] as? String, id.uuidString)
        XCTAssertEqual(json?["executionId"] as? String, "exec-1")
    }

    func testCompletedNotificationIncludesExitCode() throws {
        let line = EventsCommand.formatCompletedLine(id: "abc", executionId: "exec-2", exitCode: 7, ts: "2026-05-08T10:00:01Z")
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "completed")
        XCTAssertEqual(json?["exitCode"] as? Int, 7)
    }
}
