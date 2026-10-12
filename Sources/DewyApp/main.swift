import AppKit
import SwiftUI
import Security
import UniformTypeIdentifiers

// MARK: - Local data

struct DewyTask: Codable, Identifiable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var dueAt: Date? = nil
    var status = "待办"
    var category = "工作"
}

struct WaterLog: Codable, Identifiable {
    var id = UUID()
    var milliliters: Int
    var date = Date()
}

struct MealLog: Codable, Identifiable {
    var id = UUID()
    var details: String
    var date = Date()
}

struct SleepLog: Codable, Identifiable {
    var id = UUID()
    var bedtime: Date
    var wakeTime: Date
    var note: String = ""
}

struct WorkLog: Codable, Identifiable {
    var id = UUID()
    var details: String
    var date = Date()
}

struct FocusLog: Codable, Identifiable {
    var id = UUID()
    var startedAt: Date
    var endedAt: Date? = nil
    var task: String = "未关联任务"
    var note: String = ""
}

struct DewyGoal: Codable, Identifiable {
    var id = UUID()
    var title: String
    var detail: String = ""
    var deadline: Date? = nil
    var progress: String = "尚未更新"
    var status = "进行中"
}

struct DewySettings: Codable {
    var name = "Dewy"
    var preferredName = ""
    var cupMilliliters = 350
    var dailyWaterGoal = 1500
    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var longBreakEvery = 4
    var quietStart = 22
    var quietEnd = 8
    var apiEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent"
    var modelName = "gemini-3.8-flash"
}

struct DewyData: Codable {
    var settings = DewySettings()
    var tasks: [DewyTask] = []
    var water: [WaterLog] = []
    var meals: [MealLog] = []
    var sleep: [SleepLog] = []
    var work: [WorkLog] = []
    var focus: [FocusLog] = []
    var goals: [DewyGoal] = []
}

struct ChatLine: Identifiable {
    enum Role { case assistant, user }
    let id = UUID()
    let role: Role
    let text: String
    let date = Date()
}

@MainActor
final class DewyStore: ObservableObject {
    @Published private(set) var data: DewyData
    @Published var messages: [ChatLine] = []
    @Published var focusIsRunning = false
    @Published var focusSeconds = 0
    @Published var apiKey: String
    @Published var status = "idle"
    @Published var settingsRequested = false
    @Published var recordsRequested = false
    private var focusTimer: Timer?
    private var monitorTimer: Timer?
    private var lastReminderAt: Date?
    private let launchedAt = Date()
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dewy", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("records.json")
        apiKey = Keychain.read() ?? ""
        var needsSettingsMigration = false
        if let bytes = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(DewyData.self, from: bytes) {
            data = saved
            // Gemini 2.0 Flash has been shut down. Migrate old local settings to
            // the current stable Flash model while preserving the user's records.
            if data.settings.modelName == "gemini-2.0-flash" || data.settings.modelName.isEmpty {
                data.settings.modelName = "gemini-3.8-flash"
                data.settings.apiEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent"
                needsSettingsMigration = true
            }
        } else {
            data = DewyData()
        }
        if needsSettingsMigration { save() }
        messages = [ChatLine(role: .assistant, text: "早安。今天想从哪件事开始？我会陪你一步一步来。\n\n可以直接说“喝水”“新增待办：…”，“开始专注”或“今日总结”。")]
        if let active = data.focus.last, active.endedAt == nil {
            focusIsRunning = true
            focusSeconds = max(0, Int(Date().timeIntervalSince(active.startedAt)))
            startTicking()
        }
    }

    var waterToday: Int { data.water.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.milliliters } }
    var openTasksToday: [DewyTask] { data.tasks.filter { $0.status == "待办" || $0.status == "进行中" } }
    var completedToday: Int { data.tasks.filter { $0.status == "已完成" && Calendar.current.isDateInToday($0.createdAt) }.count }

    func save() {
        guard let bytes = try? JSONEncoder().encode(data) else { return }
        try? bytes.write(to: fileURL, options: .atomic)
    }

    func updateSettings(_ settings: DewySettings, newAPIKey: String) {
        data.settings = settings
        if data.settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            data.settings.modelName = "gemini-3.8-flash"
        }
        data.settings.apiEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(data.settings.modelName):generateContent"
        apiKey = newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty { Keychain.delete() } else { Keychain.write(apiKey) }
        save()
    }

    func addWater(_ amount: Int) -> String {
        let safeAmount = max(1, amount)
        data.water.append(WaterLog(milliliters: safeAmount)); save()
        refreshStatus()
        return "记下啦。今天已经喝了 \(waterToday) / \(data.settings.dailyWaterGoal) ml。忙碌之余，也记得慢慢补充水分。"
    }

    func addTask(_ title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "告诉我待办事项的内容，我来帮你记下。" }
        data.tasks.append(DewyTask(title: clean)); save()
        return "待办记下啦：\(clean)。你可以按自己的节奏来。"
    }

    func addActivity(_ title: String, category: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "告诉我想安排的活动，我会帮你记下来。" }
        data.tasks.append(DewyTask(title: clean, category: category)); save()
        return "\(category)安排记下啦：\(clean)。工作和休息都值得留出位置。"
    }

    func startFocus(task: String = "未关联任务") -> String {
        guard !focusIsRunning else { return "专注时段还在进行中。已经专注 \(formatDuration(focusSeconds))，我会安静陪着你。" }
        data.focus.append(FocusLog(startedAt: Date(), task: task)); focusIsRunning = true; focusSeconds = 0; status = "focus"; startTicking(); save()
        return "好，我们开始一个 \(data.settings.focusMinutes) 分钟的专注时段。我会安静陪着你。"
    }

    func stopFocus(cancel: Bool = false) -> String {
        guard focusIsRunning, let index = data.focus.lastIndex(where: { $0.endedAt == nil }) else { return "现在没有正在进行的专注时段。" }
        data.focus[index].endedAt = Date(); focusIsRunning = false; refreshStatus(); focusTimer?.invalidate(); focusTimer = nil; save()
        let elapsed = focusSeconds
        return cancel ? "专注时段已结束，记录了实际的 \(formatDuration(elapsed))。没关系，专注本来就需要练习，下次再试试？" : "这一段专注完成啦，记录了 \(formatDuration(elapsed))。做得很好，给自己一点小小的休息吧。"
    }

    private func startTicking() {
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.focusSeconds += 1 }
        }
    }

    func startMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHydrationReminder() }
        }
        refreshStatus()
    }

    private func checkHydrationReminder() {
        guard !isQuietTime(), !focusIsRunning else { refreshStatus(); return }
        let baseline = data.water.last(where: { Calendar.current.isDateInToday($0.date) })?.date ?? launchedAt
        let nextAllowed = lastReminderAt.map { max(baseline, $0) } ?? baseline
        guard Date().timeIntervalSince(nextAllowed) >= 2 * 60 * 60, status != "hydration" else { return }
        status = "hydration"; lastReminderAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    private func isQuietTime() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        let start = data.settings.quietStart; let end = data.settings.quietEnd
        return start > end ? (hour >= start || hour < end) : (hour >= start && hour < end)
    }

    private func refreshStatus() { status = focusIsRunning ? "focus" : (isQuietTime() ? "sleepy" : "idle") }

    func addWork(_ detail: String) -> String {
        let clean = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "可以告诉我今天完成了什么，或遇到了什么问题。" }
        data.work.append(WorkLog(details: clean)); save(); return "工作记录保存好了。今天做过的事，都会慢慢成为你的积累。"
    }

    func addMeal(_ detail: String) -> String {
        let clean = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "告诉我吃了什么，我会按现在的时间记下来。" }
        data.meals.append(MealLog(details: clean)); save(); return "饮食记录记下啦：\(clean)。"
    }

    func addSleep(bedtimeText: String, wakeText: String, note: String = "") -> String {
        guard let bed = Self.timeToday(bedtimeText), let wake0 = Self.timeToday(wakeText) else { return "可以这样记录睡眠：睡眠 23:00-07:00。" }
        let wake = wake0 < bed ? Calendar.current.date(byAdding: .day, value: 1, to: wake0)! : wake0
        data.sleep.append(SleepLog(bedtime: bed, wakeTime: wake, note: note)); save()
        let hrs = wake.timeIntervalSince(bed) / 3600
        return String(format: "睡眠记下啦：%.1f 小时。谢谢你照顾自己的休息。", hrs)
    }

    func addGoal(_ title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "告诉我你想达成的目标是什么。大目标也没关系，我们可以一起拆成小步骤。" }
        let lower = clean.lowercased()
        let hasDeadline = ["本周", "下周", "月底", "本月", "下个月", "年底", "天内", "周内", "个月内", "之前", "前", "截止"].contains(where: { lower.contains($0) }) || clean.range(of: #"20\d{2}[-年/]\d{1,2}([-/月]\d{1,2}日?)?"#, options: .regularExpression) != nil
        let hasMeasure = Self.firstNumber(in: clean) != nil || ["完成", "写完", "读完", "通过", "达到", "提交", "交付", "发布"].contains(where: { clean.contains($0) })
        if !hasDeadline && !hasMeasure {
            return "这个目标值得认真安排。我们先把它变得具体、可追踪：你希望达成什么结果？准备在什么时候前完成？"
        }
        if !hasDeadline { return "目标结果有了。你希望在什么时候前完成呢？确认期限后我再开始跟进。" }
        if !hasMeasure { return "期限记下了。我们再明确一下怎样算完成，比如完成几项、达到什么标准？确认后我再开始跟进。" }
        data.goals.append(DewyGoal(title: clean, detail: "以用户确认的目标描述作为衡量标准")); save()
        return "目标和期限都记下啦：\(clean)。接下来我们可以把它拆成几步；每次有进展时告诉我“进展：目标名称 - 进展内容”即可。"
    }

    func dailySummary(period: String = "day") -> String {
        let component: Calendar.Component = period == "week" ? .weekOfYear : (period == "month" ? .month : .day)
        let start = Calendar.current.dateInterval(of: component, for: Date())?.start ?? Calendar.current.startOfDay(for: Date())
        let tasks = data.tasks.filter { $0.createdAt >= start }
        let done = tasks.filter { $0.status == "已完成" }.count
        let water = data.water.filter { $0.date >= start }.reduce(0) { $0 + $1.milliliters }
        let logs = data.work.filter { $0.date >= start }
        let meals = data.meals.filter { $0.date >= start }
        let sleepLogs = data.sleep.filter { $0.wakeTime >= start }
        let goals = data.goals.filter { $0.status == "进行中" }
        let focus = data.focus.filter { $0.startedAt >= start }.reduce(0) { $0 + Int(($1.endedAt ?? Date()).timeIntervalSince($1.startedAt)) }
        let periodLabel = period == "day" ? "今天" : (period == "week" ? "本周" : "本月")
        let workText = logs.isEmpty ? "尚无工作内容记录" : logs.map { "· \($0.details)" }.joined(separator: "\n")
        let mealText = meals.isEmpty ? "未记录" : meals.map(\.details).joined(separator: "、")
        let sleepText = sleepLogs.isEmpty ? "未记录" : sleepLogs.map { formatDuration(Int($0.wakeTime.timeIntervalSince($0.bedtime))) }.joined(separator: "、")
        let goalText = goals.isEmpty ? "暂无进行中的目标" : goals.map { "\($0.title)：\($0.progress)" }.joined(separator: "；")
        let pending = tasks.filter { $0.status == "待办" || $0.status == "进行中" }.map { $0.title }.prefix(3).joined(separator: "、")
        let next = pending.isEmpty ? "目前没有未完成待办" : "还可以留意：\(pending)"
        return "\(periodLabel)回顾\n待办完成：\(done) / \(tasks.count)\n专注时长：\(formatDuration(focus))\n饮水记录：\(water) ml\n饮食记录：\(mealText)\n睡眠记录：\(sleepText)\n工作记录：\n\(workText)\n目标进度：\(goalText)\n\(next)\n\n这些总结只基于已经记录的内容；未记录的部分我不会替你猜测。"
    }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatLine(role: .user, text: text))
        if let answer = localAction(for: text) {
            messages.append(ChatLine(role: .assistant, text: answer)); return
        }
        if !apiKey.isEmpty, !data.settings.modelName.isEmpty {
            Task { await askModel(text) }
        } else {
            messages.append(ChatLine(role: .assistant, text: localReply(text)))
        }
    }

    private func localAction(for text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("帮助") || lower == "help" { return "你可以试试：\n· 喝水 / 喝了 350ml\n· 新增待办：整理资料\n· 完成：整理资料\n· 开始专注 / 结束专注\n· 工作记录：今天完成了…\n· 早餐：燕麦和牛奶\n· 睡眠 23:00-07:00\n· 目标：完成作品集\n· 今日总结 / 周总结 / 月总结" }
        if lower.contains("今日总结") || lower.contains("日报") { return dailySummary() }
        if lower.contains("周总结") || lower.contains("周报") { return dailySummary(period: "week") }
        if lower.contains("月总结") || lower.contains("月报") { return dailySummary(period: "month") }
        if lower.contains("结束专注") || lower.contains("停止专注") || lower.contains("完成专注") { return stopFocus() }
        if lower.contains("取消专注") || lower.contains("中断专注") { return stopFocus(cancel: true) }
        if lower.contains("开始专注") || lower == "专注" || lower.hasPrefix("专注：") || lower.hasPrefix("专注:") {
            let task = text.components(separatedBy: CharacterSet(charactersIn: ":：")).dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            return startFocus(task: task.isEmpty ? "未关联任务" : task)
        }
        if lower.contains("喝水") || lower.contains("喝了一杯") || lower.contains("饮水") {
            let amount = Self.firstNumber(in: text)
            let ml = amount.map { value in (lower.contains("杯") && !lower.contains("ml") && !lower.contains("毫升")) ? value * data.settings.cupMilliliters : value } ?? data.settings.cupMilliliters
            return addWater(ml)
        }
        if lower.hasPrefix("新增待办") || lower.hasPrefix("待办") || lower.hasPrefix("添加任务") {
            return addTask(Self.afterColonOrPrefix(text, prefixes: ["新增待办", "待办", "添加任务"]))
        }
        if lower.hasPrefix("完成：") || lower.hasPrefix("完成:") || lower.hasPrefix("完成 ") {
            let query = Self.afterColonOrPrefix(text, prefixes: ["完成"])
            if let index = data.tasks.firstIndex(where: { $0.status != "已完成" && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }) {
                data.tasks[index].status = "已完成"; save(); return "完成啦，真棒。\(data.tasks[index].title) 已标记完成，给自己一点小奖励吧。"
            }
            return "我暂时没找到这条待办。你可以告诉我完整的待办名称。"
        }
        if lower.hasPrefix("工作记录") || lower.hasPrefix("记录工作") || lower.hasPrefix("工作：") || lower.hasPrefix("工作:") {
            return addWork(Self.afterColonOrPrefix(text, prefixes: ["工作记录", "记录工作", "工作"]))
        }
        if ["娱乐", "运动", "休息", "社交"].contains(where: { lower.hasPrefix($0) }) {
            let category = ["娱乐", "运动", "休息", "社交"].first(where: { lower.hasPrefix($0) }) ?? "休息"
            return addActivity(Self.afterColonOrPrefix(text, prefixes: [category]), category: category)
        }
        if lower.hasPrefix("目标") || lower.hasPrefix("设定目标") {
            return addGoal(Self.afterColonOrPrefix(text, prefixes: ["设定目标", "目标"]))
        }
        if lower.hasPrefix("睡眠") {
            let matches = text.range(of: #"\d{1,2}:\d{2}\s*[-至~—]\s*\d{1,2}:\d{2}"#, options: .regularExpression).map { String(text[$0]) }
            if let span = matches {
                let times = span.components(separatedBy: CharacterSet(charactersIn: "-至~—")).map { $0.trimmingCharacters(in: .whitespaces) }
                if times.count == 2 { return addSleep(bedtimeText: times[0], wakeText: times[1]) }
            }
            return "可以这样记录睡眠：睡眠 23:00-07:00。"
        }
        if ["早餐", "午餐", "晚餐", "加餐", "吃了"].contains(where: { lower.hasPrefix($0) }) {
            let meal = Self.afterColonOrPrefix(text, prefixes: ["早餐", "午餐", "晚餐", "加餐", "吃了"])
            return addMeal(meal.isEmpty ? text : meal)
        }
        if (lower.contains("进度：") || lower.contains("进度:") || lower.contains("进展：") || lower.contains("进展:")), !data.goals.isEmpty {
            let update = Self.afterColonOrPrefix(text, prefixes: ["进度", "进展"])
            let parts = update.components(separatedBy: CharacterSet(charactersIn: "-—，,"))
            let query = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let progress = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if let index = data.goals.firstIndex(where: { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) {
                data.goals[index].progress = progress.isEmpty ? update : progress; save()
                return "目标进展记下啦：\(data.goals[index].title) · \(data.goals[index].progress)。"
            }
            return "我还没找到这个目标。可以告诉我目标名称和这次进展。"
        }
        if lower.contains("进度") && !data.goals.isEmpty {
            return "你可以这样更新目标：进展：\(data.goals[0].title) - 已完成第一步。"
        }
        return nil
    }

    private func localReply(_ text: String) -> String {
        let lower = text.lowercased()
        if ["自伤", "自残", "不想活", "想死"].contains(where: { lower.contains($0) }) {
            return "听到你现在这么难受，我很在意你的安全。请现在联系一位信任的人陪着你；如果你正处于立即伤害自己的危险，请联系当地紧急服务或前往最近的急诊。你现在身边有可以联系的人吗？"
        }
        if ["累", "疲惫", "焦虑", "沮丧", "难过", "烦", "压力", "撑不住"].contains(where: { lower.contains($0) }) {
            return "听起来今天真的消耗了你很多能量。你愿意多和我说一点吗？如果现在觉得很堵，也可以先离开任务几分钟，去窗边站一会儿、喝口水，等呼吸平复了我们再决定下一步。"
        }
        if lower.contains("你好") || lower.contains("早安") { return "早安。你想先看看今天的安排，还是先慢慢开始？" }
        if lower.contains("喝水") { return "我可以帮你记录饮水。直接说“喝水”或“喝了 350ml”就好。" }
        return "我在这里。你可以告诉我想记录或安排什么；输入“帮助”可以查看我现在支持的指令。\n\n如果在设置里接入兼容的语言模型，我也可以进行更开放的对话。"
    }

    private func askModel(_ text: String) async {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            messages.append(ChatLine(role: .assistant, text: "还没有设置 Google API Key。请先在设置里填入 API Key 后再试。"))
            return
        }

        let configuredModel = data.settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = configuredModel.isEmpty ? "gemini-3.8-flash" : configuredModel
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent") else {
            messages.append(ChatLine(role: .assistant, text: "模型服务地址看起来不太对，可以在设置里检查一下。"))
            return
        }

        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let system = "你是 Dewy，温柔而坚定的私人管家。使用简体中文，语气柔和、明确、简短，不说教，不编造用户记录。用户疲惫或焦虑时先共情倾听，暂停催促。当前本地记录摘要：今日饮水 \(waterToday) ml；未完成待办 \(openTasksToday.map(\.title).joined(separator: "、"))；专注计时 \(focusIsRunning ? "进行中" : "未进行")。你不可以声称写入记录，除非用户通过应用指令完成写入。"
        let recent = messages.suffix(12).map { message -> [String: String] in
            ["role": message.role == .assistant ? "model" : "user", "content": message.text]
        }
        let contentPayload = recent.map { item in
            ["role": item["role"] ?? "user", "parts": [["text": item["content"] ?? ""]]]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contentPayload
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Gemini 503 means temporary service overload, not an exhausted quota.
        // Retry only transient failures, with bounded exponential backoff and jitter.
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            do {
                let (bytes, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    messages.append(ChatLine(role: .assistant, text: "Gemini 没有返回有效的网络响应，请稍后重试。"))
                    return
                }
                if (200..<300).contains(http.statusCode) {
                    let parsed = try JSONDecoder().decode(GoogleModelResponse.self, from: bytes)
                    let answer = parsed.candidates?.first?.content?.parts?.compactMap { $0.text }.joined(separator: "\n")
                    messages.append(ChatLine(role: .assistant, text: answer.flatMap { $0.isEmpty ? nil : $0 } ?? "我暂时没有收到有效回复，可以稍后再试。"))
                    return
                }

                let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                let errorObject = payload?["error"] as? [String: Any]
                let detail = errorObject?["message"] as? String
                let apiStatus = (errorObject?["status"] as? String ?? "").uppercased()
                let transient429 = http.statusCode == 429 && (apiStatus.contains("RATE_LIMIT") || apiStatus.contains("TOO_MANY_REQUESTS"))
                let transientServerError = [500, 502, 503, 504].contains(http.statusCode)

                if (transientServerError || transient429), attempt < maxAttempts - 1 {
                    try await Self.waitBeforeRetry(attempt: attempt)
                    continue
                }
                if http.statusCode == 503 {
                    messages.append(ChatLine(role: .assistant, text: "Gemini 当前请求量较高，服务暂时繁忙。这不是 API 配额耗尽；我已稍候重试但仍未成功。请过一会儿再发，或在设置中换用 Google AI Studio 当前可用的 Flash 模型。"))
                } else if http.statusCode == 429 {
                    messages.append(ChatLine(role: .assistant, text: "Gemini 暂时拒绝了请求（429）。这通常是请求频率或每日配额限制；请在 Google AI Studio 查看此项目的用量与限额，再稍后重试。"))
                } else {
                    messages.append(ChatLine(role: .assistant, text: "Gemini 请求失败（\(http.statusCode)）。\(detail ?? "请检查 API Key、模型名称和 Google AI Studio 项目设置。")"))
                }
                return
            } catch is CancellationError {
                return
            } catch {
                if attempt < maxAttempts - 1 {
                    do { try await Self.waitBeforeRetry(attempt: attempt) } catch { return }
                    continue
                }
                messages.append(ChatLine(role: .assistant, text: "暂时连不上 Google Gemini 服务。你的本地记录仍然安全保存；请检查网络后再试。"))
                return
            }
        }
    }

    private static func waitBeforeRetry(attempt: Int) async throws {
        let baseSeconds = pow(2.0, Double(attempt))
        let delay = baseSeconds + Double.random(in: 0.1...0.6)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    static func firstNumber(in text: String) -> Int? {
        guard let range = text.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }
    static func afterColonOrPrefix(_ text: String, prefixes: [String]) -> String {
        if let range = text.range(of: #"[:：]"#, options: .regularExpression) { return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        for prefix in prefixes where text.lowercased().hasPrefix(prefix.lowercased()) {
            return String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ：:，,\t"))
        }
        return text
    }
    static func timeToday(_ text: String) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }
    func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        return mins < 60 ? "\(mins) 分钟" : "\(mins / 60) 小时 \(mins % 60) 分钟"
    }
}

struct GoogleModelResponse: Decodable {
    struct Candidate: Decodable {
        let content: Content?
    }
    struct Content: Decodable {
        let parts: [Part]?
    }
    struct Part: Decodable {
        let text: String?
    }
    let candidates: [Candidate]?
}

enum Keychain {
    static let service = "app.dewy.private-agent"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ value: String) {
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecValueData as String: Data(value.utf8)]
        SecItemAdd(item as CFDictionary, nil)
    }
    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Floating desktop panels

final class DewyChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class DewyAppDelegate: NSObject, NSApplicationDelegate {
    let store = DewyStore()
    var orbPanel: NSPanel!
    var hoverPanel: NSPanel!
    var chatPanel: NSPanel!
    var hideWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let otherInstance = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.dewy.private-agent")
            .first(where: { $0.processIdentifier != currentPID }) {
            _ = otherInstance.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        store.startMonitoring()
        buildPanels()
        positionPanels()
        orbPanel.orderFrontRegardless()
        NSApp.mainMenu = makeMenu()
    }

    func buildPanels() {
        orbPanel = panel(size: NSSize(width: 76, height: 76), view: OrbView(onHover: { [weak self] inside in self?.orbHover(inside) }, onClick: { [weak self] in self?.showChat() }))
        hoverPanel = panel(size: NSSize(width: 330, height: 156), view: HoverCardView(onEnter: { [weak self] in self?.cancelHide() }, onLeave: { [weak self] in self?.scheduleHide() }, openChat: { [weak self] in self?.showChat() }, focusInput: { [weak self] in self?.focusHoverInput() }), acceptsKeyboardInput: true)
        chatPanel = panel(size: NSSize(width: 420, height: 420), view: ChatWindowView(minimize: { [weak self] in self?.hideChat() }), acceptsKeyboardInput: true)
    }

    func panel<Content: View>(size: NSSize, view: Content, acceptsKeyboardInput: Bool = false) -> NSPanel {
        let result: NSPanel
        if acceptsKeyboardInput {
            result = DewyChatPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        } else {
            result = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        }
        result.isFloatingPanel = true; result.level = .floating; result.backgroundColor = .clear; result.isOpaque = false; result.hasShadow = false
        result.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        result.isReleasedWhenClosed = false
        result.contentView = NSHostingView(rootView: view.environmentObject(store))
        return result
    }

    func positionPanels() {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        orbPanel.setFrameOrigin(NSPoint(x: frame.maxX - 90, y: frame.minY + 24))
        hoverPanel.setFrameOrigin(NSPoint(x: frame.maxX - 356, y: frame.minY + 104))
        chatPanel.setFrameOrigin(NSPoint(x: frame.maxX - 444, y: frame.minY + 106))
    }

    func orbHover(_ inside: Bool) {
        if inside { cancelHide(); hoverPanel.orderFrontRegardless() }
        else { scheduleHide() }
    }
    func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hoverPanel.orderOut(nil) }
        hideWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    func cancelHide() { hideWork?.cancel(); hideWork = nil }
    func focusHoverInput() {
        NSApp.activate(ignoringOtherApps: true)
        hoverPanel.makeKeyAndOrderFront(nil)
    }
    func showChat() {
        cancelHide()
        hoverPanel.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        chatPanel.makeKeyAndOrderFront(nil)
    }
    func hideChat() { chatPanel.orderOut(nil); orbPanel.orderFrontRegardless() }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开 Dewy", action: #selector(openFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Dewy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }
    @objc func openFromMenu() { showChat() }
}

@main
struct DewyMain {
    @MainActor private static var retainedDelegate: DewyAppDelegate?
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = DewyAppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}

// MARK: - Design system

private let ink = Color(red: 0.12, green: 0.20, blue: 0.28)
private let muted = Color(red: 0.40, green: 0.51, blue: 0.60)
private let ice = Color(red: 0.85, green: 0.92, blue: 0.97)

struct WaterOrb: View {
    var status: String = "idle"
    var size: CGFloat = 58
    var animated = true
    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
                    let phase = (sin(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / breathPeriod) + 1) / 2
                    orb(phase: phase)
                }
            } else {
                orb(phase: 0.5)
            }
        }
        .accessibilityLabel("Dewy 蓝色水珠")
    }
    private func orb(phase: Double) -> some View {
        let scale = animated ? minimumScale + (maximumScale - minimumScale) * phase : 1
        return ZStack {
            Circle().fill(RadialGradient(colors: [.clear, Color(red: 0.43, green: 0.70, blue: 0.84).opacity(0.05), Color(red: 0.28, green: 0.56, blue: 0.73).opacity(0.24), .white.opacity(0.48)], center: .center, startRadius: size * 0.32, endRadius: size * 0.5))
            Circle().stroke(AngularGradient(colors: [.white.opacity(0.85), ice.opacity(0.55), Color.blue.opacity(0.5), .white.opacity(0.75)], center: .center), lineWidth: 1.2).padding(1)
            Circle().stroke(.white.opacity(animated ? 0.25 + 0.16 * phase : 0.33), lineWidth: 1).padding(size * 0.07)
            Ellipse().fill(.white.opacity(animated ? 0.52 + 0.18 * phase : 0.61)).frame(width: size * 0.17, height: size * 0.075).rotationEffect(.degrees(-38)).blur(radius: 1).offset(x: -size * 0.21, y: -size * 0.28)
            Circle().fill(.white.opacity(0.7)).frame(width: 2, height: 2).offset(x: size * 0.19, y: -size * 0.25)
        }
        .frame(width: size, height: size)
        .scaleEffect(scale)
        .offset(y: animated ? sin(phase * .pi * 2) * (status == "focus" ? 0.25 : 0.8) : 0)
    }
    private var breathPeriod: Double { status == "hydration" ? 1.45 : (status == "focus" ? 5.5 : (status == "sleepy" ? 6.2 : 4.8)) }
    private var minimumScale: CGFloat { status == "hydration" ? 0.955 : (status == "focus" ? 0.992 : (status == "sleepy" ? 0.986 : 0.968)) }
    private var maximumScale: CGFloat { status == "hydration" ? 1.05 : (status == "focus" ? 1.008 : (status == "sleepy" ? 1.014 : 1.032)) }
}

struct OrbView: View {
    @EnvironmentObject var store: DewyStore
    var onHover: (Bool) -> Void
    var onClick: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: onClick) {
            WaterOrb(status: store.status, size: 60)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("输入请求") { onClick() }
            Button("查看今日安排") { store.send("今日总结") ; onClick() }
            Button("开始专注") { store.messages.append(ChatLine(role: .assistant, text: store.startFocus())); onClick() }
            Button("记录喝水") { store.messages.append(ChatLine(role: .assistant, text: store.addWater(store.data.settings.cupMilliliters))); onClick() }
            Divider()
            Button("打开设置") { store.settingsRequested = true; onClick() }
            Divider()
            Button("退出 Dewy") { NSApp.terminate(nil) }
        }
        .onHover { inside in hovering = inside; onHover(inside) }
    }
}

struct HoverCardView: View {
    @EnvironmentObject var store: DewyStore
    var onEnter: () -> Void
    var onLeave: () -> Void
    var openChat: () -> Void
    var focusInput: () -> Void
    @State private var text = ""
    @FocusState private var inputFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("STATUS: \(statusTitle)").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.1).foregroundStyle(muted)
                Spacer()
                Button("OPEN") { openChat() }.buttonStyle(.plain).font(.system(size: 9, weight: .medium)).foregroundStyle(muted)
            }
            Text(careText).font(.system(size: 12)).foregroundStyle(ink).lineLimit(2)
            HStack(spacing: 7) {
                Image(systemName: "waveform").font(.system(size: 11, weight: .light)).foregroundStyle(muted)
                TextField("输入指令或内容...", text: $text, onCommit: submit).focused($inputFocused).textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(ink)
                Button("记下", action: recordNote).buttonStyle(.plain).font(.system(size: 9, weight: .medium)).foregroundStyle(muted).help("保存为今天的工作记录")
                Button("SEND", action: submit).buttonStyle(.plain).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(muted)
            }
            .padding(.horizontal, 10).frame(height: 34).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.7), lineWidth: 0.7))
        }
        .padding(14).frame(width: 330, height: 156)
        .background(.ultraThinMaterial.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.82), lineWidth: 0.8))
        .onHover { $0 ? onEnter() : onLeave() }
        .onChange(of: inputFocused) { focused in
            if focused { focusInput() }
        }
    }
    var statusTitle: String {
        switch store.status { case "focus": "FOCUS"; case "hydration": "HYDRATION REMINDED"; case "sleepy": "SLEEPY"; default: "GENTLE & IDLE" }
    }
    var careText: String {
        switch store.status { case "focus": "我会安静陪你专注，完成后再休息。"; case "hydration": "两个小时了，喝点水吧？"; case "sleepy": "夜深啦，眼睛该休息啦，明天再继续？"; default: "今天忙碌之余，也记得给自己一点休息时间。" }
    }
    func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        text = ""
        store.send(value)
    }
    func recordNote() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        text = ""
        store.messages.append(ChatLine(role: .user, text: "随手记：\(value)"))
        store.messages.append(ChatLine(role: .assistant, text: store.addWork(value)))
    }
}

struct ChatWindowView: View {
    @EnvironmentObject var store: DewyStore
    var minimize: () -> Void
    @State private var draft = ""
    @State private var showingSettings = false
    @State private var showingData = false
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
        .overlay { ChatClipboardShortcuts().frame(width: 0, height: 0) }
        .sheet(isPresented: $showingSettings) { SettingsView().frame(width: 420, height: 510) }
        .sheet(isPresented: $showingData) { RecordView().frame(width: 420, height: 500) }
        .onChange(of: store.settingsRequested) { requested in if requested { showingSettings = true; store.settingsRequested = false } }
        .onChange(of: store.recordsRequested) { requested in if requested { showingData = true; store.recordsRequested = false } }
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
        HStack { Circle().fill(Color(red: 0.42, green: 0.66, blue: 0.79)).frame(width: 6, height: 6); Text("专注中  ·  \(store.formatDuration(store.focusSeconds))").font(.system(size: 10, weight: .medium)); Spacer(); Button("结束") { store.messages.append(ChatLine(role: .assistant, text: store.stopFocus())) }.buttonStyle(.plain).font(.system(size: 10)) }
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
                Text(line.text).font(.system(size: 10.5)).foregroundStyle(ink).lineSpacing(2).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 8).background(line.role == .user ? ice.opacity(0.79) : .white.opacity(0.86), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(line.role == .user ? 0.45 : 0.8), lineWidth: 0.5))
            }.frame(maxWidth: 335, alignment: line.role == .user ? .trailing : .leading)
            if line.role == .assistant { Spacer(minLength: 20) }
        }
    }
}

/// Keeps the usual macOS Command shortcuts and adds Control+V / Control+C
/// for users who expect the common Windows/browser shortcuts.
private struct ChatClipboardShortcuts: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.install(for: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.install(for: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        private var monitor: Any?
        private weak var hostView: NSView?

        func install(for view: NSView) {
            hostView = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let host = self.hostView, event.window === host.window,
                      event.modifierFlags.contains(.control),
                      let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
                if key == "v" {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    return nil
                }
                if key == "c" {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    return nil
                }
                return event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            hostView = nil
        }
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
                    Text("密钥保存在此 Mac 的钥匙串中，并通过加密连接发送给 Google。留空时使用本地指令；连接后可进行开放式对话。模型回复不会自动写入记录。")
                        .font(.system(size: 9)).foregroundStyle(muted)
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("保存设置") { store.updateSettings(settings, newAPIKey: key); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(16).background(.ultraThinMaterial).onAppear { settings = store.data.settings; key = store.apiKey }
    }
}

struct RecordView: View {
    @EnvironmentObject var store: DewyStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("今天的记录").font(.system(size: 17, weight: .semibold)); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11)) }.buttonStyle(.plain) }
            Text("饮水  \(store.waterToday) / \(store.data.settings.dailyWaterGoal) ml     ·     待办  \(store.openTasksToday.count) 项").font(.system(size: 11)).foregroundStyle(muted)
            List {
                Section("待办") { ForEach(store.data.tasks) { task in HStack { Text(task.title); Spacer(); Text(task.status).foregroundStyle(muted) } } }
                Section("目标") { ForEach(store.data.goals) { goal in HStack { Text(goal.title); Spacer(); Text(goal.progress).foregroundStyle(muted) } } }
                Section("工作记录") { ForEach(store.data.work.suffix(12)) { Text($0.details) } }
                Section("饮食记录") { ForEach(store.data.meals.suffix(12)) { Text("\($0.date.formatted(date: .omitted, time: .shortened))  \($0.details)") } }
                Section("专注记录") { ForEach(store.data.focus.suffix(12)) { session in Text("\(session.task) · \(Int(((session.endedAt ?? Date()).timeIntervalSince(session.startedAt))/60)) 分钟") } }
            }.listStyle(.inset)
            HStack { Button("导出记录") { exportRecords() }; Spacer(); Button("关闭") { dismiss() } }
        }.padding(15).background(.ultraThinMaterial)
    }
    func exportRecords() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Dewy-记录.json"; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url, let bytes = try? JSONEncoder().encode(store.data) { try? bytes.write(to: url, options: .atomic) }
    }
}
