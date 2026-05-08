import ArgumentParser
import Foundation

struct RestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Stop and immediately re-run a task."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Flag(name: .long) var json: Bool = false

    @MainActor
    func run() async throws {
        try await dispatch(action: .restart, identifier: identifier, json: json)
    }
}
