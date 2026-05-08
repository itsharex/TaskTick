import Foundation

enum TaskKind: String, Codable {
    case scheduled
    case manual
}

enum TaskStatus: String, Codable {
    case idle
    case running
}

struct TaskDTO: Codable {
    let id: UUID
    let shortId: String
    let name: String
    let kind: TaskKind
    let enabled: Bool
    let status: TaskStatus
    let scheduleSummary: String
    let lastRunAt: Date?
    let lastRunDurationSec: Int?
    let lastExitCode: Int?
    let createdAt: Date
}

struct StatusGlobalDTO: Codable {
    struct RunningTask: Codable {
        let id: UUID
        let name: String
        let startedAt: Date
        let elapsedSec: Int
    }
    let running: [RunningTask]
    let totalEnabled: Int
    let totalRunning: Int
}

struct ExecutionLogDTO: Codable {
    struct LogLine: Codable {
        let ts: Date
        let stream: String  // "stdout" | "stderr"
        let text: String
    }
    let executionId: UUID
    let taskId: UUID
    let startedAt: Date
    let endedAt: Date?
    let exitCode: Int?
    let stdout: String
    let stderr: String
    let lines: [LogLine]
}
