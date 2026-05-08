import Foundation
import SwiftData

public enum ExecutionStatus: String, Codable, CaseIterable, Sendable {
    case running = "running"
    case success = "success"
    case failure = "failure"
    case timeout = "timeout"
    case cancelled = "cancelled"

    public var displayName: String {
        switch self {
        case .running: L10n.tr("status.running")
        case .success: L10n.tr("status.success")
        case .failure: L10n.tr("status.failure")
        case .timeout: L10n.tr("status.timeout")
        case .cancelled: L10n.tr("status.cancelled")
        }
    }

    public var iconName: String {
        switch self {
        case .running: "play.circle.fill"
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .timeout: "clock.badge.exclamationmark"
        case .cancelled: "stop.circle.fill"
        }
    }
}

public enum TriggerType: String, Codable, Sendable {
    case schedule = "schedule"
    case manual = "manual"
    case launch = "launch"

    public var displayName: String {
        switch self {
        case .schedule: L10n.tr("log.detail.trigger.schedule")
        case .manual:   L10n.tr("log.detail.trigger.manual")
        case .launch:   L10n.tr("log.detail.trigger.launch")
        }
    }
}

@Model
public final class ExecutionLog {
    public var id: UUID = UUID()
    public var task: ScheduledTask?
    public var startedAt: Date = Date()
    public var finishedAt: Date?
    public var statusRaw: String = ExecutionStatus.running.rawValue
    public var exitCode: Int?
    public var stdout: String?
    public var stderr: String?
    public var durationMs: Int?
    public var triggeredByRaw: String = TriggerType.manual.rawValue

    public init(
        task: ScheduledTask? = nil,
        triggeredBy: TriggerType = .manual
    ) {
        self.id = UUID()
        self.task = task
        self.startedAt = Date()
        self.statusRaw = ExecutionStatus.running.rawValue
        self.triggeredByRaw = triggeredBy.rawValue
    }

    public var status: ExecutionStatus {
        get { ExecutionStatus(rawValue: statusRaw) ?? .running }
        set { statusRaw = newValue.rawValue }
    }

    public var triggeredBy: TriggerType {
        get { TriggerType(rawValue: triggeredByRaw) ?? .manual }
        set { triggeredByRaw = newValue.rawValue }
    }

    /// Maximum output size: 512KB
    public static let maxOutputSize = 512 * 1024

    public static func truncateOutput(_ output: String) -> String {
        if output.utf8.count > maxOutputSize {
            let truncated = String(output.prefix(maxOutputSize / 2))
            return truncated + "\n\n--- 输出已截断 (超过 512KB) ---"
        }
        return output
    }
}
