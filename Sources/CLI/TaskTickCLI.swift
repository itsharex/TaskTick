import ArgumentParser
import Foundation
import TaskTickCore

@main
struct TaskTickCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tasktick",
        abstract: "Control TaskTick scheduled tasks from the command line.",
        version: "0.1.0",
        subcommands: [
            ListCommand.self,
            StatusCommand.self,
            LogsCommand.self,
            RunCommand.self
        ]
    )
}
