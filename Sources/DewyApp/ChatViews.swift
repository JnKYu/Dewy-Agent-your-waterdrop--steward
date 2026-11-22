import AppKit
import SwiftUI
import MarkdownUI
import UniformTypeIdentifiers

struct ChatWindowView: View {
    @EnvironmentObject var store: DewyStore
    var minimize: () -> Void
    @State private var draft = ""
    @State private var showingSettings = false
    @State private var showingData = false
    @State private var showingPlanning = false
    @State private var scrollID = UUID()
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        if store.messages.isEmpty { welcomeSummary }
                        ForEach(store.messages) { line in
                            ChatBubble(line: line)
                                .id(line.id)
                        }
                        if store.focusIsRunning { focusBanner }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
                .onChange(of: store.messages.count) { _ in
                    if let last = store.messages.last { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            shortcuts
            composer
        }
        .frame(width: 420, height: 420)
        .background(.ultraThinMaterial.opacity(0.96))
        .background(Color(red: 0.94, green: 0.97, blue: 0.99).opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.88), lineWidth: 1))
        .sheet(isPresented: $showingSettings) { SettingsView().frame(width: 420, height: 510) }
        .sheet(isPresented: $showingData) { RecordView().frame(width: 420, height: 500) }
        .sheet(isPresented: $showingPlanning) { PlanningView() }
        .onChange(of: store.settingsRequested) { requested in if requested { showingSettings = true; store.settingsRequested = false } }
        .onChange(of: store.recordsRequested) { requested in if requested { showingData = true; store.recordsRequested = false } }
        .alert("本地数据提示", isPresented: Binding(get: { store.persistenceError != nil }, set: { if !$0 { store.clearPersistenceError() } })) {
            Button("好") { store.clearPersistenceError() }
        } message: { Text(store.persistenceError ?? "") }
    }

    private var header: some View {
        HStack(spacing: 9) {
            WaterOrb(status: store.status, size: 24, animated: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dewy").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                Text("深呼吸，我们一步一步来。").font(.system(size: 9)).foregroundStyle(muted)
            }
            Spacer()
            Button { showingData = true } label: { Image(systemName: "square.grid.2x2").font(.system(size: 11, weight: .light)) }.buttonStyle(.plain).help("查看记录")
            Button { showingPlanning = true } label: { Image(systemName: "calendar").font(.system(size: 11, weight: .light)) }.buttonStyle(.plain).help("日历与习惯")
            Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .light)) }.buttonStyle(.plain).help("设置")
            Button(action: minimize) { Image(systemName: "minus").font(.system(size: 11, weight: .light)) }.buttonStyle(.plain).help("最小化")
            Button(action: minimize) { Image(systemName: "xmark").font(.system(size: 10, weight: .light)) }.buttonStyle(.plain).help("关闭")
        }
        .foregroundStyle(muted).padding(.horizontal, 15).frame(height: 57)
        .background(.white.opacity(0.34))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.55)).frame(height: 0.6) }
    }

    private var welcomeSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TODAY · \(Date.now.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(muted)
            Text("待办 \(store.openTasksToday.count) 项  ·  饮水 \(store.waterToday) / \(store.data.settings.dailyWaterGoal) ml").font(.system(size: 11)).foregroundStyle(ink)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.37), in: RoundedRectangle(cornerRadius: 10))
    }

    private var focusBanner: some View {
        HStack { Circle().fill(Color(red: 0.42, green: 0.66, blue: 0.79)).frame(width: 6, height: 6); Text("专注中  ·  \(store.formatDuration(store.focusSeconds))").font(.system(size: 10, weight: .medium)); Spacer(); Button("结束") { store.appendMessage(ChatLine(role: .assistant, text: store.stopFocus())) }.buttonStyle(.plain).font(.system(size: 10)) }
            .foregroundStyle(muted).padding(9).background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
    }

    private var shortcuts: some View {
        HStack(spacing: 5) {
            shortcut("喝水", "喝水")
            shortcut(store.focusIsRunning ? "结束专注" : "专注", store.focusIsRunning ? "结束专注" : "开始专注")
            shortcut("待办", "新增待办：")
            shortcut("目标", "目标：")
            shortcut("总结", "今日总结")
        }.padding(.horizontal, 11).frame(height: 33)
    }
    private func shortcut(_ title: String, _ command: String) -> some View {
        Button(title) { if command.hasSuffix("：") { draft = command } else { store.send(command) } }
            .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(muted).padding(.horizontal, 8).padding(.vertical, 5)
            .background(.white.opacity(0.38), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.55), lineWidth: 0.6))
    }
    private var composer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 11, weight: .light)).foregroundStyle(muted)
                TextField("想和 Dewy 记点什么...", text: $draft, onCommit: send)
                    .focused($composerFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(ink)
                Button("SEND", action: send).buttonStyle(.plain).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(muted)
            }.padding(.horizontal, 10).frame(height: 37).background(.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.78), lineWidth: 0.7))
            Text("记录仅保存在这台设备上").font(.system(size: 8)).foregroundStyle(muted.opacity(0.88))
        }.padding(.horizontal, 12).padding(.bottom, 9)
    }
    private func send() {
        let submitted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        draft = ""
        store.send(submitted)
        // SwiftUI may publish the final Return-key edit after onSubmit runs.
        // Clear once more on the next main-loop turn so the sent text stays gone.
        DispatchQueue.main.async {
            if draft == submitted { draft = "" }
        }
    }
}

struct ChatBubble: View {
    let line: ChatLine
    var body: some View {
        HStack {
            if line.role == .user { Spacer(minLength: 40) }
            VStack(alignment: line.role == .user ? .trailing : .leading, spacing: 3) {
                Text(line.role == .user ? "我 · \(line.date.formatted(date: .omitted, time: .shortened))" : "Dewy · \(line.date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 8)).foregroundStyle(muted.opacity(0.9))
                Group {
                    if line.role == .assistant {
                        Markdown(normalizedText)
                            .markdownTextStyle {
                                FontSize(10.5)
                                ForegroundColor(ink)
                            }
                            .markdownBlockStyle(\.paragraph) { configuration in
                                configuration.label.relativeLineSpacing(.em(0.2))
                            }
                    } else {
                        Text(line.text)
                            .font(.system(size: 10.5))
                            .foregroundStyle(ink)
                            .lineSpacing(2)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 8).background(line.role == .user ? ice.opacity(0.79) : .white.opacity(0.86), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(line.role == .user ? 0.45 : 0.8), lineWidth: 0.5))
            }.frame(maxWidth: 335, alignment: line.role == .user ? .trailing : .leading)
            if line.role == .assistant { Spacer(minLength: 20) }
        }
    }

    private var normalizedText: String {
    Self.separateInlineStageHeadings(in: Self.separateBoldWeekHeadings(in: line.text))
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: #"(?<!\n)\n(?!\n)"#, with: "  \n", options: .regularExpression)
}

    private static func separateBoldWeekHeadings(in text: String) -> String {
        let pattern = #"\*\*(第\s*[^*\n]{1,50}?周[：:][^*\n]{1,100})\*\*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let headingRange = match.range(at: 1)
            let fullRange = match.range(at: 0)
            let lineStart = nsText.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: fullRange.location)).location
            let prefixStart = lineStart == NSNotFound ? 0 : lineStart + 1
            let prefixRange = NSRange(location: prefixStart, length: fullRange.location - prefixStart)
            let prefix = nsText.substring(with: prefixRange).trimmingCharacters(in: .whitespaces)
            if prefix.hasPrefix("###") { continue }

            let heading = nsText.substring(with: headingRange)
            if let range = Range(fullRange, in: result) {
                result.replaceSubrange(range, with: "\n\n### \(heading)\n\n")
            }
        }
        return result
    }

    private static func separateInlineStageHeadings(in text: String) -> String {
        let pattern = #"(第[一二三四五六七八九十\d]+阶段[：:][^。！？\n]{1,100}?(?:（第\s*[一二三四五六七八九十\d]+\s*周）|\(第\s*[一二三四五六七八九十\d]+\s*周\)))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let headingRange = match.range(at: 1)
            let heading = nsText.substring(with: headingRange)
            if let range = Range(headingRange, in: result) {
                result.replaceSubrange(range, with: "\n\n### \(heading)\n\n")
            }
        }
        return result
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: DewyStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings = DewySettings()
    @State private var key = ""

    private var maskedKeyBinding: Binding<String> {
        Binding(
            get: {
                guard !key.isEmpty else { return "" }
                let prefix = String(key.prefix(3))
                let hidden = String(repeating: "*", count: max(0, key.count - prefix.count))
                return prefix + hidden
            },
            set: { newValue in
                key = newValue.filter { $0 != "*" }
            }
        )
    }

    private func pasteAPIKey() {
        if let pasted = NSPasteboard.general.string(forType: .string) {
            key = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text("设置").font(.system(size: 17, weight: .semibold)); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11)) }.buttonStyle(.plain) }
            Form {
                Section("个人偏好") {
                    TextField("怎么称呼你", text: $settings.preferredName)
                    Stepper("杯子容量  \(settings.cupMilliliters) ml", value: $settings.cupMilliliters, in: 100...1000, step: 50)
                    Stepper("每日饮水目标  \(settings.dailyWaterGoal) ml", value: $settings.dailyWaterGoal, in: 500...5000, step: 100)
                }
                Section("专注计时") {
                    Stepper("专注  \(settings.focusMinutes) 分钟", value: $settings.focusMinutes, in: 5...90, step: 5)
                    Stepper("短休息  \(settings.shortBreakMinutes) 分钟", value: $settings.shortBreakMinutes, in: 1...30)
                    Stepper("长休息  \(settings.longBreakMinutes) 分钟", value: $settings.longBreakMinutes, in: 5...60)
                }
                Section("可选语言模型") {
                    Text("Google Gemini API").font(.system(size: 11, weight: .medium))
                    Link("前往 Google AI Studio 创建或查看 API Key", destination: URL(string: "https://aistudio.google.com/api-keys")!)
                        .font(.system(size: 10))
                    TextField("模型名称（默认 gemini-3.8-flash）", text: $settings.modelName)
                    HStack {
                        TextField("API Key（前 3 位可见，其他为 *）", text: maskedKeyBinding)
                        Button("粘贴") { pasteAPIKey() }
                            .buttonStyle(.borderless)
                            .font(.system(size: 9, weight: .medium))
                    }
                    Text("已输入 \(key.count) 个字符；你可以直接粘贴完整 API Key，界面只显示前 3 位与遮罩。")
                        .font(.system(size: 9)).foregroundStyle(muted)
                    Text("密钥保存在此 Mac 的钥匙串中，并通过加密连接发送给 Google。留空时使用本地指令；连接后可进行开放式对话；普通回复不会写入记录，画像和本地数据只通过明确的本地操作更新。")
                        .font(.system(size: 9)).foregroundStyle(muted)
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("保存设置") { store.updateSettings(settings, newAPIKey: key); dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .onAppear { settings = store.data.settings; key = store.apiKey }
    }
}

struct RecordView: View {
    @EnvironmentObject var store: DewyStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingFocusDeletion = false
    @State private var confirmingCompletedTaskClear = false
    @State private var focusSessionToDelete: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("今天的记录").font(.system(size: 17, weight: .semibold)); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11)) }.buttonStyle(.plain) }
            Text("饮水  \(store.waterToday) / \(store.data.settings.dailyWaterGoal) ml     ·     待办  \(store.openTasksToday.count) 项").font(.system(size: 11)).foregroundStyle(muted)
            List {
                // Section("待办") { ForEach(store.data.tasks) { task in HStack { Text(task.title); Spacer(); Text(task.status).foregroundStyle(muted) } } }
                // --- 替换 RecordView 中 Section("待办") 的内容为下面这段 ---

                Section {
                    ForEach(store.data.tasks) { task in
                        HStack {
                            // 左侧显示任务标题
                            Text(task.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .strikethrough(task.status == "已完成", color: muted)
                                .foregroundStyle(task.status == "已完成" ? muted : ink)

                            Spacer()

                            // 右侧：可点的状态图标（已完成显示实心勾）
                            Button {
                                // 切换完成状态
                                store.toggleTaskCompletion(task.id)
                            } label: {
                                if task.status == "已完成" {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(muted)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(task.status == "已完成" ? "取消标记完成" : "标记完成")
                        }
                        .padding(.vertical, 6)
                        .contextMenu {
                            // 右键菜单也提供标记完成选项
                            if task.status != "已完成" {
                                Button("标记完成") { store.markTaskCompleted(task.id) }
                            } else {
                                Button("标记为未完成") { store.toggleTaskCompletion(task.id) }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("待办")
                        Spacer()
                        Button("清除已完成") { confirmingCompletedTaskClear = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 9))
                            .disabled(!store.data.tasks.contains { $0.status == "已完成" })
                    }
                }
                Section("目标") { ForEach(store.data.goals) { goal in HStack { Text(goal.title); Spacer(); Text(goal.progress).foregroundStyle(muted) } } }
                Section("工作记录") {
                    ForEach(store.data.work.filter { Calendar.current.isDateInToday($0.date) }.suffix(12)) { Text($0.details) }
                }
                Section("饮食记录") {
                    ForEach(store.data.meals.filter { Calendar.current.isDateInToday($0.date) }.suffix(12)) { Text("\($0.date.formatted(date: .omitted, time: .shortened))  \($0.details)") }
                }
                Section {
                    ForEach(store.data.focus.filter { Calendar.current.isDateInToday($0.startedAt) }.sorted(by: { $0.startedAt > $1.startedAt }).prefix(30)) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(session.task).lineLimit(1)
                                Spacer()
                                Text("\(Int(((session.endedAt ?? Date()).timeIntervalSince(session.startedAt)) / 60)) 分钟")
                                    .foregroundStyle(muted)
                            }
                            HStack(spacing: 5) {
                                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 9)).foregroundStyle(muted)
                                if session.endedAt == nil {
                                    Text("进行中").font(.system(size: 9)).foregroundStyle(muted)
                                }
                                Spacer()
                                Picker("关联待办", selection: Binding(
                                    get: { session.taskID },
                                    set: { store.setFocusTask(sessionID: session.id, taskID: $0) }
                                )) {
                                    Text("未关联任务").tag(Optional<UUID>.none)
                                    ForEach(store.data.tasks) { task in
                                        Text(task.title).tag(Optional(task.id))
                                    }
                                }
                                .labelsHidden()
                                .font(.system(size: 9))
                                .frame(maxWidth: 150)
                                .help("将此专注时段关联到待办")
                            }
                        }
                        .padding(.vertical, 3)
                        .contextMenu {
                            if session.endedAt != nil {
                                Button("删除这条专注记录", role: .destructive) {
                                    focusSessionToDelete = session.id
                                    confirmingFocusDeletion = true
                                }
                            }
                        }
                    }
                } header: {
                    Text("专注记录")
                }
            }.listStyle(.inset)
            HStack(spacing: 8) {
                Button("导出 JSON") { exportRecords() }
                Button("导出周报") { exportMarkdown(period: "week") }
                Button("导出月报") { exportMarkdown(period: "month") }
                Spacer(); Button("关闭") { dismiss() }
            }
        }
        .padding(15)
        .background(.ultraThinMaterial)
        .confirmationDialog("清除所有已完成待办？", isPresented: $confirmingCompletedTaskClear, titleVisibility: .visible) {
            Button("清除已完成待办", role: .destructive) { store.clearCompletedTasks() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("未完成待办会保留。已完成待办将从待办列表中删除。")
        }
        .confirmationDialog("删除这条专注记录？", isPresented: $confirmingFocusDeletion, titleVisibility: .visible) {
            Button("删除记录", role: .destructive) {
                if let id = focusSessionToDelete { store.deleteFocusSession(id) }
                focusSessionToDelete = nil
            }
            Button("取消", role: .cancel) { focusSessionToDelete = nil }
        }
    }
    func exportRecords() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Dewy-记录.json"; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(store.data).write(to: url, options: .atomic) }
            catch { store.reportPersistenceError("导出 JSON 失败：\(error.localizedDescription)") }
        }
    }

    func exportMarkdown(period: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = period == "month" ? "Dewy-月报.md" : "Dewy-周报.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.markdownReport(period: period).write(to: url, atomically: true, encoding: .utf8) }
            catch { store.reportPersistenceError("导出 Markdown 失败：\(error.localizedDescription)") }
        }
    }
}
