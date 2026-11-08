import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class StartupStore: ObservableObject {
    @Published private(set) var items: [StartupItem] = []
    @Published var message: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemNeedsApproval = false

    private let fm = FileManager.default
    private var uid: String { String(getuid()) }
    private var ownershipURL: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StartupManager/ownership.json")
    }

    var runningCount: Int { items.filter { $0.status == .running }.count }
    var stoppedCount: Int { items.filter { $0.status == .stopped }.count }

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginItemNeedsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginItemStatus()
            message = enabled
                ? (loginItemNeedsApproval ? "已登记。请在系统设置 → 通用 → 登录项中允许启动项管理器。" : "启动项管理器将在你登录 macOS 时自动打开。")
                : "已关闭登录时自动启动。"
        } catch {
            refreshLoginItemStatus()
            message = "更改登录启动设置失败：\(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refresh() {
        refreshLoginItemStatus()
        var found: [StartupItem] = []
        var seenServices = Set<String>()
        let overrides = loadOwnershipRegistry()
        let home = fm.homeDirectoryForCurrentUser
        let domain = "gui/\(uid)"
        let loadedLabels = Self.activeServices(in: domain)
        let disabledOutput = Self.run("launchctl", ["print-disabled", domain]).output
        let directory = home.appendingPathComponent("Library/LaunchAgents")
        let locations: [(URL, ItemKind)] = [(directory, .userAgent)]
        for (directory, kind) in locations {
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: file), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                let label = plist["Label"] as? String ?? file.deletingPathExtension().lastPathComponent
                // A LaunchAgent label is unique within its launchd domain. If the
                // same plist is copied into multiple searched folders, show the
                // user-owned copy first instead of presenting duplicate rows.
                let serviceKey = "\(domain)/\(label)"
                guard seenServices.insert(serviceKey).inserted else { continue }
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
                let args = plist["ProgramArguments"] as? [String] ?? []
                let override = disabledOutput.split(separator: "\n").first { $0.contains("\"\(label)\" =>") }
                let disabled = override.map { $0.contains("=> disabled") } ?? ((plist["Disabled"] as? Bool) == true)
                let running = loadedLabels.contains(label)
                let stdout = (plist["StandardOutPath"] as? String).map(URL.init(fileURLWithPath:))
                let stderr = (plist["StandardErrorPath"] as? String).map(URL.init(fileURLWithPath:))
                let ownership = overrides[file.path] ?? .unclassified
                let hint: String
                switch ownership {
                case .personal: hint = "由你创建或明确标记为自己的服务。"
                case .thirdParty: hint = "由你明确标记为第三方服务。"
                case .unclassified: hint = "macOS 不记录此服务由谁创建；请按需手动分类。"
                }
                found.append(StartupItem(label: label, developer: Self.developer(from: program), kind: kind, path: file, program: program, arguments: args, status: disabled ? .disabled : (running ? .running : .stopped), manageable: true, note: nil, stdoutLog: stdout, stderrLog: stderr, ownership: ownership, ownershipHint: hint))
            }
        }
        items = found.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func addService(name: String, executable: URL, arguments: [String], workingDirectory: URL?, runAtLoad: Bool, keepAlive: Bool, stdoutPath: String, stderrPath: String) {
        let safeName = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let label = "local.startup.\(safeName.isEmpty ? "service" : safeName).\(UUID().uuidString.prefix(8).lowercased())"
        let directory = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let target = directory.appendingPathComponent("\(label).plist")
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var plist: [String: Any] = ["Label": label, "ProgramArguments": [executable.path] + arguments, "RunAtLoad": runAtLoad, "KeepAlive": keepAlive]
            if let workingDirectory { plist["WorkingDirectory"] = workingDirectory.path }
            let outputPath = (stdoutPath as NSString).expandingTildeInPath
            let errorPath = (stderrPath as NSString).expandingTildeInPath
            let logFolder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StartupManager/\(safeName.isEmpty ? "service" : safeName)")
            let finalOutputPath = outputPath.trimmingCharacters(in: .whitespaces).isEmpty ? logFolder.appendingPathComponent("output.log").path : outputPath
            let finalErrorPath = errorPath.trimmingCharacters(in: .whitespaces).isEmpty ? logFolder.appendingPathComponent("error.log").path : errorPath
            plist["StandardOutPath"] = finalOutputPath
            plist["StandardErrorPath"] = finalErrorPath
            try fm.createDirectory(at: URL(fileURLWithPath: finalOutputPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: URL(fileURLWithPath: finalErrorPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: target, options: .atomic)
            setOwnership(.personal, forPath: target.path)
            if runAtLoad {
                let result = Self.run("launchctl", ["bootstrap", "gui/\(uid)", target.path])
                if result.status != 0 { message = "配置已创建，但加载失败：\(result.output)\n\(target.path)" }
                else { message = "服务「\(name)」已创建并启动。" }
            } else { message = "服务「\(name)」配置已创建。\n\(target.path)" }
            refresh()
        } catch { message = "添加失败：\(error.localizedDescription)" }
    }

    func setOwnership(_ ownership: ServiceOwnership, for item: StartupItem) {
        setOwnership(ownership, forPath: item.path.path)
        refresh()
    }

    private func loadOwnershipRegistry() -> [String: ServiceOwnership] {
        guard let data = try? Data(contentsOf: ownershipURL) else { return [:] }
        if let values = try? JSONDecoder().decode([String: ServiceOwnership].self, from: data) { return values }
        if let legacy = try? JSONDecoder().decode([String: Bool].self, from: data) {
            return legacy.mapValues { $0 ? .personal : .thirdParty }
        }
        return [:]
    }

    private func setOwnership(_ ownership: ServiceOwnership, forPath path: String) {
        var values = loadOwnershipRegistry()
        values[path] = ownership
        do {
            try fm.createDirectory(at: ownershipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(values)
            try data.write(to: ownershipURL, options: .atomic)
        } catch { message = "保存服务分类失败：\(error.localizedDescription)" }
    }

    func logPath(for item: StartupItem, channel: LogChannel) -> URL? {
        switch channel { case .output: item.stdoutLog; case .errors: item.stderrLog; case .launchd: nil }
    }

    func logText(for item: StartupItem, channel: LogChannel) -> String {
        if channel == .launchd {
            let domain = item.kind == .daemon || item.kind == .appleDaemon ? "system" : "gui/\(uid)"
            let result = Self.run("launchctl", ["print", "\(domain)/\(item.label)"])
            return result.status == 0 ? result.output : "launchd 当前没有加载此服务。\n\(result.output)"
        }
        guard let url = logPath(for: item, channel: channel) else { return "此服务未配置此类日志文件。" }
        let text: String
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let fileSize = try handle.seekToEnd()
            let maxBytes: UInt64 = 512 * 1024
            let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            var decoded = String(decoding: data, as: UTF8.self)
            if offset > 0, let newline = decoded.firstIndex(of: "\n") { decoded = String(decoded[decoded.index(after: newline)...]) }
            text = decoded
        } catch { return "日志文件尚未生成，或当前用户没有读取权限。\n\(url.path)" }
        let lines = text.components(separatedBy: .newlines).suffix(350)
        let tail = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return tail.isEmpty ? "暂无日志内容，服务产生输出后会显示在这里。" : tail
    }

    func perform(_ action: String, on item: StartupItem) {
        guard item.manageable else { message = item.note ?? "此项目不可由当前用户管理。"; return }
        let domain = "gui/\(uid)"
        var result = CommandResult(status: 0, output: "")
        switch action {
        case "开始":
            let service = Self.run("launchctl", ["print", "\(domain)/\(item.label)"])
            if service.status != 0 { result = Self.run("launchctl", ["bootstrap", domain, item.path.path]) }
            if result.status == 0 { result = Self.run("launchctl", ["kickstart", "-k", "\(domain)/\(item.label)"]) }
        case "停止":
            // A SIGTERM alone is immediately undone for KeepAlive jobs (such as Mango).
            // bootout unloads the job for this login session without removing its plist.
            result = Self.run("launchctl", ["bootout", domain, item.path.path])
        case "禁用":
            let service = Self.run("launchctl", ["print", "\(domain)/\(item.label)"])
            result = service.status == 0 ? Self.run("launchctl", ["bootout", domain, item.path.path]) : CommandResult(status: 0, output: "")
            if result.status == 0 { result = Self.run("launchctl", ["disable", "\(domain)/\(item.label)"]) }
        case "启用":
            result = Self.run("launchctl", ["enable", "\(domain)/\(item.label)"])
            if result.status == 0 { result = Self.run("launchctl", ["bootstrap", domain, item.path.path]) }
        case "删除":
            NSWorkspace.shared.recycle([item.path])
            _ = Self.run("launchctl", ["bootout", domain, "\(domain)/\(item.label)"])
            message = "已请求将项目移至废纸篓：\(item.path.lastPathComponent)"
        default: break
        }
        if action != "删除" {
            message = result.status == 0 ? "已执行：\(action)「\(item.label)」" : "\(action)失败：\(result.output.isEmpty ? "launchctl 返回错误码 \(result.status)" : result.output)"
        }
        refresh()
    }

    private struct CommandResult { let status: Int32; let output: String }
    private static func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        let pipe = Pipe(); process.standardError = pipe; process.standardOutput = pipe
        do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { return CommandResult(status: -1, output: error.localizedDescription) }
    }
    private static func activeServices(in domain: String) -> Set<String> {
        let output = run("launchctl", ["print", domain]).output
        var inServices = false
        var active = Set<String>()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" { inServices = true; continue }
            if inServices && trimmed == "}" { break }
            guard inServices else { continue }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let pid = Int(fields[0]), pid > 0 else { continue }
            active.insert(String(fields[2]))
        }
        return active
    }
    private static func developer(from path: String?) -> String {
        guard let path else { return "未知开发者" }
        let components = URL(fileURLWithPath: path).pathComponents
        if let index = components.firstIndex(of: "Applications"), components.indices.contains(index + 1) { return components[index + 1].replacingOccurrences(of: ".app", with: "") }
        return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }
}
