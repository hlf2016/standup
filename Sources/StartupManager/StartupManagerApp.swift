import AppKit
import Combine
import Darwin
import SwiftUI
import UniformTypeIdentifiers

@main
struct StartupManagerApp: App {
    @NSApplicationDelegateAdaptor(StatusBarAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView(store: appDelegate.store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1080, height: 720)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
private final class StatusBarAppDelegate: NSObject, NSApplicationDelegate {
    let store = StartupStore()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var itemObserver: AnyCancellable?
    private var refreshTimer: Timer?
    private var instanceLockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimSingleInstance() else {
            NSApp.terminate(nil)
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Standup 启动项管理器")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = "Standup 0"
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityLabel("Standup 状态栏菜单")
        }
        item.isVisible = true
        statusItem = item
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 350, height: 565)
        popover.contentViewController = NSHostingController(rootView: MenuBarPanel(store: store) { [weak self] in self?.showMainWindow() })
        itemObserver = store.$items.sink { [weak self] _ in self?.updateStatusItem() }
        store.refresh()
        store.refreshLoginItemStatus()
        NSLog("Standup: native status item installed")
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(sender) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); popover.contentViewController?.view.window?.makeKey() }
    }

    private func showMainWindow() {
        if let existing = NSApp.windows.first(where: { $0.title == "Standup" }) {
            mainWindow = existing
        } else if mainWindow == nil {
            let controller = NSHostingController(rootView: ContentView(store: store).frame(minWidth: 900, minHeight: 560))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Standup"
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("Standup.MainWindow")
            window.contentViewController = controller
            window.center()
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        popover.performClose(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func claimSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "local.startup-manager"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        for app in existing { app.terminate() }

        let deadline = Date(timeIntervalSinceNow: 2)
        while existing.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        for app in existing where !app.isTerminated { _ = app.forceTerminate() }

        let lockPath = "/tmp/local.startup-manager.instance.lock"
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.title = "Standup \(store.runningCount)"
        button.toolTip = "Standup · \(store.runningCount) 个服务运行中"
        button.image = NSImage(systemSymbolName: store.runningCount > 0 ? "bolt.fill" : "bolt.slash.fill", accessibilityDescription: "Standup")
        button.image?.isTemplate = true
    }
}

struct ContentView: View {
    @ObservedObject var store: StartupStore
    @State private var selection: StartupItem.ID?
    @State private var query = ""
    @State private var filter = "全部"
    @State private var pending: PendingAction?
    @State private var showingAddService = false
    @State private var detailTab = "概览"
    @State private var logs = ""
    @State private var logChannel: LogChannel = .output
    private var selected: StartupItem? { store.items.first { $0.id == selection } }
    private var visible: [StartupItem] { store.items.filter { item in
        let matchesSearch = query.isEmpty || item.label.localizedCaseInsensitiveContains(query) || item.developer.localizedCaseInsensitiveContains(query)
        let matchesScope: Bool
        switch filter {
        case "我添加的": matchesScope = item.isMine
        case "来源未确认": matchesScope = item.ownership == .unclassified
        case "第三方": matchesScope = item.ownership == .thirdParty
        default: matchesScope = true
        }
        return matchesSearch && matchesScope
    } }
    private var personalItems: [StartupItem] { visible.filter(\.isMine) }
    private var unclassifiedItems: [StartupItem] { visible.filter { $0.ownership == .unclassified } }
    private var thirdPartyItems: [StartupItem] { visible.filter { $0.ownership == .thirdParty } }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 12) {
                HStack(spacing: 10) { AppLogo().frame(width: 35, height: 35); VStack(alignment: .leading, spacing: 2) { Text("Standup").font(.subheadline.weight(.bold)); Text("SERVICE CONTROL").font(.system(size: 8, weight: .bold, design: .rounded)).tracking(1.2).foregroundStyle(.secondary) }; Spacer() }.padding(.horizontal, 14).padding(.top, 8)
                HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索启动项", text: $query).textFieldStyle(.plain) }.padding(10).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 12).padding(.top, 8)
                HStack {
                    Label("\(store.items.filter(\.isMine).count) 个我的", systemImage: "person.crop.circle").font(.caption).foregroundStyle(.cyan)
                    Label("\(store.items.filter { $0.ownership == .unclassified }.count) 个未确认", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Menu { ForEach(["我添加的", "来源未确认", "第三方", "全部"] , id: \.self) { scope in Button(scope) { filter = scope } } } label: { Label(filter, systemImage: "line.3.horizontal.decrease.circle") }.menuStyle(.borderlessButton)
                }.padding(.horizontal, 14)
                List(selection: $selection) {
                    Section {
                        ForEach(personalItems) { item in itemRow(item).tag(item.id) }
                    } header: { Label("我添加的", systemImage: "person.crop.circle.fill").foregroundStyle(.cyan) }
                    Section {
                        ForEach(unclassifiedItems) { item in itemRow(item).tag(item.id) }
                    } header: { Label("来源未确认", systemImage: "questionmark.circle.fill").foregroundStyle(.orange) }
                    Section {
                        ForEach(thirdPartyItems) { item in itemRow(item).tag(item.id) }
                    } header: { Label("第三方服务", systemImage: "shippingbox.fill").foregroundStyle(.secondary) }
                }.listStyle(.sidebar)
                HStack { Button { showingAddService = true } label: { Label("添加启动项", systemImage: "plus") }.buttonStyle(.borderedProminent); Spacer(); Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新列表") }.padding(.horizontal, 12).padding(.bottom, 10)
            }.navigationTitle("启动项").navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
        } detail: {
            if let item = selected { detailView(item).onAppear { logs = store.logText(for: item, channel: logChannel) }.onChange(of: item.id) { _ in logs = store.logText(for: item, channel: logChannel); detailTab = "概览" } } else {
                dashboard
            }
        }
        .task { store.refresh() }
        .alert("确认操作", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("取消", role: .cancel) { pending = nil }
            Button(pending?.action ?? "确认", role: pending?.action == "删除" ? .destructive : nil) { if let pending { store.perform(pending.action, on: pending.item) }; self.pending = nil }
        } message: { Text(pending?.message ?? "") }
        .alert("启动项管理", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("好") { store.message = nil } } message: { Text(store.message ?? "") }
        .sheet(isPresented: $showingAddService) { AddServiceSheet { name, executable, arguments, workingDirectory, runAtLoad, keepAlive, stdout, stderr in
            store.addService(name: name, executable: executable, arguments: arguments, workingDirectory: workingDirectory, runAtLoad: runAtLoad, keepAlive: keepAlive, stdoutPath: stdout, stderrPath: stderr)
        } }
    }

    private var dashboard: some View {
        let running = store.items.filter { $0.status == .running }.count
        let stopped = store.items.filter { $0.status == .stopped }.count
        let disabled = store.items.filter { $0.status == .disabled }.count
        let chartData = [StatusSlice(name: "运行中", count: running, color: .green), StatusSlice(name: "已停止", count: stopped, color: .blue), StatusSlice(name: "已禁用", count: disabled, color: .orange)].filter { $0.count > 0 }
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    AppLogo().frame(width: 62, height: 62)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("服务总览").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("当前用户启动项运行状态概况").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    metricCard("启动项", value: "\(store.items.count)", caption: "当前用户服务", icon: "square.stack.3d.up.fill", tint: .cyan)
                    metricCard("运行中", value: "\(running)", caption: "当前已加载", icon: "waveform.path", tint: .green)
                    metricCard("已停止", value: "\(stopped)", caption: "可手动启动", icon: "pause.circle.fill", tint: .blue)
                }
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) { Text("状态分布").font(.headline); Text("按当前读取到的启动项状态统计").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 15) { legend("运行中", .green); legend("已停止", .blue); legend("已禁用", .orange) }.padding(.top, 8)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    DonutChartView(slices: chartData, total: store.items.count).frame(width: 160, height: 160)
                }.padding(20).background(LinearGradient(colors: [Color.cyan.opacity(0.09), Color.blue.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Color.cyan.opacity(0.14)))
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text("服务分类").font(.headline); Text("归属由 Standup 记录；未标记的启动项会显示为来源未确认").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { store.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                        categoryCard(title: "我添加的", subtitle: "由你创建或明确标记", count: store.items.filter(\.isMine).count, icon: "person.crop.circle.fill", tint: .cyan)
                        categoryCard(title: "来源未确认", subtitle: "当前用户的服务中，创建者未标记", count: store.items.filter { $0.ownership == .unclassified }.count, icon: "questionmark.circle.fill", tint: .orange)
                        categoryCard(title: "第三方", subtitle: "你已标记的第三方服务", count: store.items.filter { $0.ownership == .thirdParty }.count, icon: "shippingbox.fill", tint: .blue)
                    }
                }
            }.padding(28).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func metricCard(_ title: String, value: String, caption: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: icon).foregroundStyle(tint); Spacer() }
            Text(value).font(.system(size: 27, weight: .bold, design: .rounded))
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.weight(.semibold)); Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }
    private func categoryCard(title: String, subtitle: String, count: Int, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: icon).font(.system(size: 19)).foregroundStyle(tint).frame(width: 40, height: 40).background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 12)); Spacer(); Text("\(count)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(tint) }
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.subheadline.weight(.semibold)).lineLimit(1); Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
        }.padding(14).frame(maxWidth: .infinity, minHeight: 112, alignment: .leading).background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 14))
    }
    private func legend(_ name: String, _ tint: Color) -> some View { HStack(spacing: 5) { Circle().fill(tint).frame(width: 7, height: 7); Text(name).font(.caption).foregroundStyle(.secondary) } }

    @ViewBuilder private func detailView(_ item: StartupItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: item.isSystem ? "gearshape.2.fill" : "shippingbox.fill").font(.system(size: 24)).foregroundStyle(item.isSystem ? .orange : .blue).frame(width: 54, height: 54).background((item.isSystem ? Color.orange : Color.blue).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) { Text(item.label).font(.title2.bold()); Text("\(item.isSystem ? "系统服务" : "我的服务")  ·  \(item.kind.rawValue)").font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
                Label(item.status.rawValue, systemImage: "circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(color(item.status)).padding(.horizontal, 12).padding(.vertical, 8).background(color(item.status).opacity(0.12), in: Capsule())
            }.padding(22)
            HStack(spacing: 3) { ForEach(["概览", "运行日志"], id: \.self) { tab in Button { detailTab = tab; if tab == "运行日志" { logs = store.logText(for: item, channel: logChannel) } } label: { Text(tab).font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8).background(detailTab == tab ? Color.accentColor.opacity(0.13) : .clear, in: Capsule()) }.buttonStyle(.plain) }; Spacer() }.padding(.horizontal, 22).padding(.bottom, 8)
            Divider()
            if detailTab == "概览" { overview(item) } else { logView(item) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)).navigationTitle(item.label)
    }
    private func itemRow(_ item: StartupItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isSystem ? "gearshape.2.fill" : "shippingbox.fill").foregroundStyle(item.isSystem ? .orange : .blue).frame(width: 25)
            VStack(alignment: .leading, spacing: 4) { Text(item.label).font(.system(size: 13, weight: .medium)).lineLimit(1); Text(item.developer).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 2)
            Label(item.status.rawValue, systemImage: statusSymbol(item.status)).font(.caption2.weight(.medium)).foregroundStyle(color(item.status)).lineLimit(1)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
    private func overview(_ item: StartupItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    actionButton("开始", icon: "play.fill", enabled: item.manageable && (item.status == .stopped || item.status == .unknown))
                    actionButton("停止", icon: "stop.fill", enabled: item.manageable && item.status == .running)
                    actionButton("启用", icon: "checkmark.circle", enabled: item.manageable && item.status == .disabled)
                    actionButton("禁用", icon: "slash.circle", enabled: item.manageable && item.status != .disabled)
                    Spacer()
                    actionButton("删除", icon: "trash", enabled: item.manageable, destructive: true)
                }.buttonStyle(.bordered)
                infoCard("服务信息", icon: "info.circle") {
                    infoRow("类型", item.kind.rawValue); infoRow("开发者", item.developer); infoRow("程序", item.program ?? "未知", selectable: true); infoRow("配置文件", item.path.path, selectable: true)
                }
                if !item.isSystem {
                    infoCard("归属分类", icon: "person.crop.circle") {
                        HStack { VStack(alignment: .leading, spacing: 4) { Text(item.ownership.rawValue).font(.subheadline.weight(.semibold)); Text(item.ownershipHint).font(.caption).foregroundStyle(.secondary) }; Spacer(); Menu("更改归属") { ForEach(ServiceOwnership.allCases) { ownership in Button(ownership.rawValue) { store.setOwnership(ownership, for: item) } } }.menuStyle(.borderedButton) }
                    }
                }
                if let note = item.note { Label(note, systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
                Text("停止会暂时卸载服务，KeepAlive 不会在当前会话内将它重新拉起；下次登录仍可启动。").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
    }
    private func logView(_ item: StartupItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill").font(.system(size: 18)).foregroundStyle(.cyan).frame(width: 42, height: 42).background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) { Text("运行日志").font(.title3.bold()); Text("查看服务输出、错误信息与 launchd 诊断").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { logs = store.logText(for: item, channel: logChannel) } label: { Label("刷新", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(logs, forType: .string) } label: { Label("复制", systemImage: "doc.on.doc") }.buttonStyle(.bordered).disabled(logs.isEmpty)
                if let path = store.logPath(for: item, channel: logChannel) { Button { NSWorkspace.shared.activateFileViewerSelecting([path]) } label: { Image(systemName: "folder") }.buttonStyle(.bordered).help("在访达中显示日志文件") }
            }
            HStack(spacing: 8) {
                ForEach(LogChannel.allCases) { channel in
                    Button { logChannel = channel; logs = store.logText(for: item, channel: channel) } label: {
                        Label(channel.rawValue, systemImage: channel == .output ? "text.alignleft" : (channel == .errors ? "exclamationmark.triangle" : "gearshape.2"))
                            .font(.subheadline.weight(logChannel == channel ? .semibold : .regular)).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(logChannel == channel ? Color.accentColor.opacity(0.13) : .clear, in: Capsule())
                    }.buttonStyle(.plain).foregroundStyle(logChannel == channel ? Color.accentColor : Color.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Circle().fill(logSourceColor).frame(width: 7, height: 7)
                Text(logSourceLabel).font(.caption.weight(.medium))
                Text("·").foregroundStyle(.tertiary)
                Text("\(logLines.count) 行").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text("最新 350 行").font(.caption).foregroundStyle(.tertiary)
            }
            if let path = store.logPath(for: item, channel: logChannel) {
                HStack(spacing: 7) { Image(systemName: "doc.text").foregroundStyle(.cyan); Text(path.path).lineLimit(1).textSelection(.enabled); Spacer(); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path.path, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("复制路径") }.font(.caption.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 9).background(.quaternary.opacity(0.34), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if logLines.isEmpty {
                        VStack(spacing: 10) { Image(systemName: logs.contains("尚未生成") || logs.contains("未配置") ? "clock.badge.questionmark" : "text.page").font(.system(size: 30)).foregroundStyle(.tertiary); Text(logs.isEmpty ? "正在读取日志…" : logs).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled) }.frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 12) {
                                Text(String(format: "%03d", index + 1)).foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                                RoundedRectangle(cornerRadius: 1).fill(severityColor(line).opacity(0.85)).frame(width: 2)
                                Text(line).foregroundStyle(severityColor(line)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: 11, design: .monospaced)).padding(.horizontal, 12).padding(.vertical, 5).background(index.isMultiple(of: 2) ? Color.primary.opacity(0.018) : .clear)
                        }
                    }
                }.padding(.vertical, 8)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            HStack { Label(logChannel == .launchd ? "实时读取 launchd 服务定义与运行状态。" : "日志按配置文件中的 \(logChannel == .output ? "StandardOutPath" : "StandardErrorPath") 路径读取。", systemImage: "info.circle"); Spacer(); Text("更新于 \(Date.now.formatted(date: .omitted, time: .standard))") }.font(.caption2).foregroundStyle(.tertiary)
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var logLines: [String] { logs.components(separatedBy: .newlines).filter { !$0.isEmpty } }
    private var logSourceLabel: String {
        if logs.contains("尚未生成") || logs.contains("未配置") { return "等待日志文件" }
        if logChannel == .launchd { return "launchd 状态快照" }
        if logs.contains("暂无日志内容") { return "日志文件已连接 · 暂无新内容" }
        return "日志文件已连接"
    }
    private var logSourceColor: Color {
        if logs.contains("尚未生成") || logs.contains("未配置") { return .orange }
        if logChannel == .launchd { return .cyan }
        if logs.contains("暂无日志内容") { return .secondary }
        return .green
    }
    private func severityColor(_ line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("fatal") || lower.contains("panic") || lower.contains("错误") { return .red }
        if lower.contains("warn") || lower.contains("warning") || lower.contains("警告") { return .orange }
        if lower.contains("success") || lower.contains("started") || lower.contains("ready") || lower.contains("成功") { return .green }
        return Color.primary.opacity(0.82)
    }
    private func infoCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { Label(title, systemImage: icon).font(.headline); content() }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
    private func infoRow(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading); infoValue(value, selectable: selectable); Spacer(minLength: 0) }.font(.callout)
    }
    @ViewBuilder private func infoValue(_ value: String, selectable: Bool) -> some View {
        if selectable { Text(value).textSelection(.enabled).lineLimit(3) } else { Text(value).lineLimit(3) }
    }
    private func actionButton(_ title: String, icon: String, enabled: Bool, destructive: Bool = false) -> some View {
        Button { guard let item = selected else { return }; pending = PendingAction(action: title, item: item, message: explanation(title, item)) } label: { Label(title, systemImage: icon) }.disabled(!enabled).tint(destructive ? .red : nil)
    }
    private func explanation(_ action: String, _ item: StartupItem) -> String {
        switch action {
        case "开始": return "将尝试立即启动「\(item.label)」。"
        case "停止": return "将从当前登录会话卸载「\(item.label)」。启动配置文件会保留，下次登录仍可自动启动。"
        case "启用": return "允许「\(item.label)」再次加载，并尝试立即加载其 LaunchAgent。"
        case "禁用": return "卸载「\(item.label)」并阻止它之后自动加载。"
        default: return "将「\(item.path.path)」移至废纸篓，并卸载该启动项。"
        }
    }
    private func color(_ status: ItemStatus) -> Color { switch status { case .running: .green; case .stopped: .blue; case .disabled: .orange; case .unknown: .gray } }
    private func statusSymbol(_ status: ItemStatus) -> String { switch status { case .running: "checkmark.circle.fill"; case .stopped: "pause.circle.fill"; case .disabled: "slash.circle.fill"; case .unknown: "questionmark.circle.fill" } }
}

private struct PendingAction { let action: String; let item: StartupItem; let message: String }
private struct StatusSlice: Identifiable { let name: String; let count: Int; let color: Color; var id: String { name } }

private struct MenuBarPanel: View {
    @ObservedObject var store: StartupStore
    let onOpenManager: () -> Void
    private var userServices: [StartupItem] {
        store.items.filter { $0.kind == .userAgent }.sorted {
            if $0.status == .running && $1.status != .running { return true }
            if $1.status == .running && $0.status != .running { return false }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                AppLogo().frame(width: 39, height: 39)
                VStack(alignment: .leading, spacing: 3) { Text("Standup").font(.headline); Text("菜单栏快速状态").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("刷新服务状态")
            }
            HStack(spacing: 10) {
                miniMetric("运行中", count: store.runningCount, color: .green, icon: "waveform.path")
                miniMetric("已停止", count: store.stoppedCount, color: .blue, icon: "pause.circle")
                miniMetric("全部", count: store.items.count, color: .cyan, icon: "square.stack.3d.up")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("个人服务").font(.subheadline.weight(.semibold)); Spacer(); Text("自动刷新 · 10 秒").font(.caption2).foregroundStyle(.tertiary) }
                if userServices.isEmpty {
                    Text("没有发现用户级服务").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    ForEach(userServices.prefix(5)) { item in
                        HStack(spacing: 9) {
                            Circle().fill(statusColor(item.status)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) { Text(item.label).font(.system(size: 12, weight: .medium)).lineLimit(1); Text(item.developer).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Text(item.status.rawValue).font(.caption2.weight(.medium)).foregroundStyle(statusColor(item.status))
                        }.padding(.vertical, 3)
                    }
                    if userServices.count > 5 { Text("还有 \(userServices.count - 5) 个服务…").font(.caption2).foregroundStyle(.tertiary) }
                }
            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) })) {
                    VStack(alignment: .leading, spacing: 2) { Text("登录时自动打开").font(.subheadline.weight(.medium)); Text("启动后常驻菜单栏").font(.caption2).foregroundStyle(.secondary) }
                }.toggleStyle(.switch)
                if store.loginItemNeedsApproval { Label("请到系统设置的登录项中允许此应用。", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange) }
            }
            if let message = store.message { Text(message).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Button(action: onOpenManager) { Label("打开管理器", systemImage: "rectangle.inset.filled") }.buttonStyle(.borderless)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }.font(.caption.weight(.medium))
        }.padding(16).frame(width: 330).onAppear { store.refresh(); store.refreshLoginItemStatus() }
    }
    private func miniMetric(_ label: String, count: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 7) { Image(systemName: icon).foregroundStyle(color); VStack(alignment: .leading, spacing: 1) { Text("\(count)").font(.system(.headline, design: .rounded)); Text(label).font(.caption2).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
    private func statusColor(_ status: ItemStatus) -> Color { switch status { case .running: .green; case .stopped: .blue; case .disabled: .orange; case .unknown: .gray } }
}

private struct DonutChartView: View {
    let slices: [StatusSlice]
    let total: Int
    private var sum: Double { Double(max(1, slices.reduce(0) { $0 + $1.count })) }
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: 16)
            ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                Circle().trim(from: start(for: index), to: end(for: index)).stroke(slice.color, style: StrokeStyle(lineWidth: 16, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) { Text("\(total)").font(.system(size: 27, weight: .bold, design: .rounded)); Text("SERVICES").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.1).foregroundStyle(.secondary) }
        }.padding(6).animation(.easeInOut(duration: 0.35), value: slices.map(\.count))
    }
    private func start(for index: Int) -> CGFloat { CGFloat(slices.prefix(index).reduce(0) { $0 + $1.count }) / CGFloat(sum) }
    private func end(for index: Int) -> CGFloat { CGFloat(slices.prefix(index + 1).reduce(0) { $0 + $1.count }) / CGFloat(sum) }
}

private struct AddServiceSheet: View {
    let onCreate: (String, URL, [String], URL?, Bool, Bool, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var executable = ""
    @State private var arguments = ""
    @State private var workingDirectory = ""
    @State private var runAtLoad = true
    @State private var keepAlive = false
    @State private var advanced = false
    @State private var customLogs = false
    @State private var stdout = ""
    @State private var stderr = ""
    @State private var showingPlist = false
    private var displayName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return executable.isEmpty ? "新后台服务" : URL(fileURLWithPath: executable).deletingPathExtension().lastPathComponent
    }
    private var safeName: String {
        let value = displayName.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "service" : value
    }
    private var label: String { "local.startup.\(safeName).xxxxxxxx" }
    private var logFolder: String { "~/Library/Logs/StartupManager/\(safeName)" }
    private var outputPath: String { customLogs && !stdout.isEmpty ? stdout : "\(logFolder)/output.log" }
    private var errorPath: String { customLogs && !stderr.isEmpty ? stderr : "\(logFolder)/error.log" }
    private var plistPreview: String {
        var plist: [String: Any] = ["Label": label, "ProgramArguments": [executable.isEmpty ? "/path/to/program" : executable] + parsedArguments, "RunAtLoad": runAtLoad, "KeepAlive": keepAlive,
                                    "StandardOutPath": (outputPath as NSString).expandingTildeInPath, "StandardErrorPath": (errorPath as NSString).expandingTildeInPath]
        if !workingDirectory.isEmpty { plist["WorkingDirectory"] = workingDirectory }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return "无法生成配置预览" }
        return String(decoding: data, as: UTF8.self)
    }
    private var parsedArguments: [String] { arguments.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private var canCreate: Bool { !executable.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppLogo().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) { Text("添加启动服务").font(.title2.bold()); Text("选择一个程序，其余配置会自动生成。 ").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.callout.weight(.semibold)).foregroundStyle(.secondary).frame(width: 30, height: 30).background(.quaternary, in: Circle()) }.buttonStyle(.plain)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("程序").font(.headline)
                        Button { chooseExecutable() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: executable.isEmpty ? "app.badge.plus" : "app.fill").font(.system(size: 19)).foregroundStyle(.cyan).frame(width: 40, height: 40).background(Color.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                                VStack(alignment: .leading, spacing: 3) { Text(executable.isEmpty ? "选择应用、脚本或可执行文件" : URL(fileURLWithPath: executable).lastPathComponent).font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Text(executable.isEmpty ? "选择后会自动填写服务名称" : executable).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                            }.padding(12).background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        TextField("服务名称", text: $name, prompt: Text(executable.isEmpty ? "例如：Mango Worker" : displayName)).textFieldStyle(.roundedBorder)
                    }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.quaternary))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("启动行为").font(.headline)
                        settingRow("登录时自动启动", subtitle: "当前用户登录后运行", icon: "power", isOn: $runAtLoad)
                        Divider()
                        settingRow("意外退出后重启", subtitle: "适合需要持续运行的后台服务", icon: "arrow.clockwise", isOn: $keepAlive)
                    }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.quaternary))
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { advanced.toggle() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .semibold)).foregroundStyle(.cyan).frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("高级设置").font(.subheadline.weight(.semibold))
                                Text("启动参数、工作目录和日志路径").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: advanced ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.quaternary))
                    if advanced {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("启动参数 · 每行一个参数").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            TextEditor(text: $arguments).font(.system(.body, design: .monospaced)).frame(height: 58).padding(4).overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
                            HStack { TextField("工作目录（可选）", text: $workingDirectory).textFieldStyle(.roundedBorder); Button { workingDirectory = chooseFolder() ?? workingDirectory } label: { Image(systemName: "folder") }.buttonStyle(.bordered) }
                            Toggle("自定义日志文件位置", isOn: $customLogs).toggleStyle(.checkbox)
                            if customLogs {
                                TextField("标准输出路径", text: $stdout).textFieldStyle(.roundedBorder)
                                TextField("错误输出路径", text: $stderr).textFieldStyle(.roundedBorder)
                            }
                        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.quaternary))
                    }
                    Button { showingPlist = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "curlybraces").font(.system(size: 16, weight: .semibold)).foregroundStyle(.cyan).frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("预览生成的 plist").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text("查看或复制将写入 LaunchAgents 的配置").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.quaternary))
                    VStack(alignment: .leading, spacing: 10) {
                        Label("配置摘要", systemImage: "checkmark.seal.fill").font(.subheadline.weight(.semibold))
                        summaryRow("保存位置", "~/Library/LaunchAgents", icon: "folder")
                        summaryRow("服务标识", label, icon: "number")
                        summaryRow("日志", customLogs ? "使用自定义路径" : "~/Library/Logs/StartupManager/\(safeName)/", icon: "doc.text")
                    }.padding(16).background(LinearGradient(colors: [Color.cyan.opacity(0.08), Color.blue.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.cyan.opacity(0.15)))
                    Label("仅在当前用户范围创建，不需要管理员权限。", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 2)
                }.padding(18)
            }
            Divider()
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button { create() } label: { Label("创建服务", systemImage: "plus") }.buttonStyle(.borderedProminent).disabled(!canCreate).keyboardShortcut(.defaultAction) }.padding(16)
        }.frame(width: 590, height: 690).background(Color(nsColor: .windowBackgroundColor))
            .sheet(isPresented: $showingPlist) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Label("生成的 LaunchAgent 配置", systemImage: "curlybraces").font(.headline); Spacer(); Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(plistPreview, forType: .string) }.buttonStyle(.bordered) }
                    Text("系统将保存为 plist 文件，可随时打开查看或编辑。").font(.caption).foregroundStyle(.secondary)
                    ScrollViewReader { proxy in
                        ScrollView([.vertical, .horizontal]) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(plistPreview.components(separatedBy: .newlines).enumerated()), id: \.offset) { index, line in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(String(format: "%02d", index + 1))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 28, alignment: .trailing)
                                        Text(line.isEmpty ? " " : line)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(line.trimmingCharacters(in: .whitespaces).hasPrefix("<") ? Color.cyan : Color.primary)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .textSelection(.enabled)
                                    }
                                    .frame(minHeight: 20, alignment: .leading)
                                    .id(index)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onAppear { proxy.scrollTo(0, anchor: .topLeading) }
                        .onChange(of: plistPreview) { _ in proxy.scrollTo(0, anchor: .topLeading) }
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                    HStack { Spacer(); Button("完成") { showingPlist = false }.keyboardShortcut(.defaultAction) }
                }.padding(18).frame(width: 560, height: 470)
            }
    }
    private func settingRow(_ title: String, subtitle: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 11) { Image(systemName: icon).foregroundStyle(.cyan).frame(width: 28); VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.weight(.medium)); Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch) }
    }
    private func summaryRow(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 8) { Image(systemName: icon).frame(width: 14).foregroundStyle(.secondary); Text(label).foregroundStyle(.secondary); Spacer(); Text(value).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled) }.font(.caption)
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.application, .executable, .shellScript]
        if panel.runModal() == .OK, let url = panel.url {
            let resolved = url.pathExtension == "app" ? (Bundle(url: url)?.executableURL ?? url) : url
            executable = resolved.path
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = url.deletingPathExtension().lastPathComponent }
            if workingDirectory.isEmpty { workingDirectory = resolved.deletingLastPathComponent().path }
        }
    }
    private func chooseFolder() -> String? { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; return panel.runModal() == .OK ? panel.url?.path : nil }
    private func create() {
        var url = URL(fileURLWithPath: executable)
        if url.pathExtension == "app", let bundledExecutable = Bundle(url: url)?.executableURL { url = bundledExecutable }
        onCreate(displayName, url, parsedArguments, workingDirectory.isEmpty ? nil : URL(fileURLWithPath: workingDirectory), runAtLoad, keepAlive, customLogs ? stdout : "", customLogs ? stderr : "")
        dismiss()
    }
}

private struct AppLogo: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "StartupManagerLogo", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "power.circle.fill").resizable().foregroundStyle(.cyan)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous)).accessibilityLabel("启动项管理器标志")
    }
}
