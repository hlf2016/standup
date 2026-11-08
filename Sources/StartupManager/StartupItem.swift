import Foundation

enum ItemKind: String, CaseIterable, Identifiable {
    case userAgent = "用户 LaunchAgent"
    case systemAgent = "系统 LaunchAgent"
    case daemon = "LaunchDaemon"
    case appleAgent = "Apple 系统 LaunchAgent"
    case appleDaemon = "Apple LaunchDaemon"
    var id: String { rawValue }
}

enum ItemStatus: String {
    case running = "运行中", stopped = "已停止", disabled = "已禁用", unknown = "状态未知"
}

enum LogChannel: String, CaseIterable, Identifiable {
    case output = "服务输出"
    case errors = "错误输出"
    case launchd = "launchd 状态"
    var id: String { rawValue }
}

enum ServiceOwnership: String, CaseIterable, Codable, Identifiable {
    case personal = "我添加的"
    case thirdParty = "第三方"
    case unclassified = "来源未确认"
    var id: String { rawValue }
}

struct StartupItem: Identifiable, Hashable {
    var id: String { path.path }
    let label: String
    let developer: String
    let kind: ItemKind
    let path: URL
    let program: String?
    let arguments: [String]
    let status: ItemStatus
    let manageable: Bool
    let note: String?
    let stdoutLog: URL?
    let stderrLog: URL?
    let ownership: ServiceOwnership
    let ownershipHint: String

    var isMine: Bool { ownership == .personal }
    var isSystem: Bool { kind == .systemAgent || kind == .daemon || kind == .appleAgent || kind == .appleDaemon }
}
