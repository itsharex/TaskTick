import ArgumentParser
import Foundation

struct RevealCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reveal",
        abstract: "Open the TaskTick main window with this task selected."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Flag(name: .long) var json: Bool = false

    @MainActor
    func run() async throws {
        try await dispatch(action: .reveal, identifier: identifier, json: json)
    }
}
