import AppKit
import SwiftUI
import Foundation

@MainActor
final class DewyStore: ObservableObject {
    @Published private(set) var data: DewyData
    @Published private(set) var persistenceError: String?
    @Published private(set) var messages: [ChatLine] = []
    @Published var focusIsRunning = false
    @Published var focusSeconds = 0
    @Published var orbIsDragging = false
    @Published var apiKey: String
    @Published var status = "idle"
    @Published var settingsRequested = false
    @Published var recordsRequested = false
    @Published private(set) var proactiveNotice: DewyProactiveNotice?
    var onProactiveMessage: ((DewyProactiveNotice) -> Void)?
    private var focusTimer: Timer?
    private var weeklySummaryTimer: Timer?
    private var weeklyCleanupTimer: Timer?
    private var lastSave: Date = Date() // 新增：上次自动保存时间
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

        var shouldSaveAfterLoad = false
        var needsSettingsMigration = false
        if let bytes = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(DewyData.self, from: bytes) {
            data = saved
            let todaysMessages = data.chatHistory.filter { Calendar.current.isDateInToday($0.date) }
            if todaysMessages.count != data.chatHistory.count {
                data.chatHistory = todaysMessages
                shouldSaveAfterLoad = true
            }
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

        messages = data.chatHistory
        if messages.isEmpty {
            let greeting = ChatLine(role: .assistant, text: Self.dailyGreeting)
            messages = [greeting]
            data.chatHistory = messages
            shouldSaveAfterLoad = true
        }
        if needsSettingsMigration { shouldSaveAfterLoad = true }
        if shouldSaveAfterLoad { save() }

        if let active = data.focus.last, active.endedAt == nil {
            focusIsRunning = true
            focusSeconds = max(0, Int(Date().timeIntervalSince(active.startedAt)))
            startTicking()
        }
    }

    private static let dailyGreeting = "早安。今天想从哪件事开始？我会陪你一步一步来。\n\n可以直接说“喝水”“新增待办：…”，“开始专注”或“今日总结”。"

    func appendMessage(_ message: ChatLine) {
        if !messages.contains(where: { Calendar.current.isDateInToday($0.date) }) {
            messages = [ChatLine(role: .assistant, text: Self.dailyGreeting)]
        }
        messages.append(message)
        data.chatHistory = messages.filter { Calendar.current.isDateInToday($0.date) }
        save()
    }
    var waterToday: Int { data.water.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.milliliters } }
    var openTasksToday: [DewyTask] { data.tasks.filter { $0.status == "待办" || $0.status == "进行中" } }
    var completedToday: Int { data.tasks.filter { $0.status == "已完成" && Calendar.current.isDateInToday($0.createdAt) }.count }

    var habitCompletionRateLast30Days: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let firstDay = calendar.date(byAdding: .day, value: -29, to: today) else { return 0 }
        var planned = 0
        var completed = 0
        for habit in data.habits {
            var day = max(firstDay, calendar.startOfDay(for: habit.createdAt))
            while day <= today {
                let weekday = calendar.component(.weekday, from: day)
                let dayIndex = weekday == 1 ? 7 : weekday - 1
                let schedule = habit.schedule(on: day)
                if schedule.weekdays.contains(dayIndex) && !schedule.restDays.contains(dayIndex) {
                    planned += 1
                    if data.habitCheckIns.contains(where: { $0.habitID == habit.id && calendar.isDate($0.date, inSameDayAs: day) }) { completed += 1 }
                }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
        }
        return planned == 0 ? 0 : Int((Double(completed) / Double(planned) * 100).rounded())
    }

    var highestHabitStreak: Int { data.habits.map(historicalStreak(for:)).max() ?? 0 }

    func historicalStreak(for habit: DewyHabit) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: habit.createdAt)
        let end = calendar.startOfDay(for: Date())
        var day = start
        var current = 0
        var highest = 0
        while day <= end {
            let weekday = calendar.component(.weekday, from: day)
            let dayIndex = weekday == 1 ? 7 : weekday - 1
            let schedule = habit.schedule(on: day)
            if schedule.weekdays.contains(dayIndex) && !schedule.restDays.contains(dayIndex) {
                if data.habitCheckIns.contains(where: { $0.habitID == habit.id && calendar.isDate($0.date, inSameDayAs: day) }) {
                    current += 1
                    highest = max(highest, current)
                } else {
                    current = 0
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return highest
    }

    func addHabit(
        _ title: String,
        weekdays: Set<Int> = Set(1...7),
        restDays: Set<Int> = [],
        reminderHour: Int? = nil,
        reminderMinute: Int? = nil
    ) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var habit = DewyHabit(title: clean, weekdays: weekdays.isEmpty ? Set(1...7) : weekdays, restDays: restDays)
        habit.reminderHour = reminderHour
        habit.reminderMinute = reminderMinute
        data.habits.append(habit)
        save()
    }

    @discardableResult
    func setHabitReminder(id: UUID, hour: Int?, minute: Int?) -> Bool {
        guard let index = data.habits.firstIndex(where: { $0.id == id }) else { return false }
        guard (hour == nil && minute == nil) || (hour.map { (0...23).contains($0) } == true && minute.map { (0...59).contains($0) } == true) else { return false }
        data.habits[index].reminderHour = hour
        data.habits[index].reminderMinute = minute
        data.habits[index].lastReminderDate = nil
        save()
        return true
    }

    func setHabitReminder(named title: String, hour: Int?, minute: Int?) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = data.habits.filter { $0.title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame }
        guard matches.count == 1, let habit = matches.first else {
            return matches.isEmpty ? "没有找到名为「\(cleanTitle)」的习惯。" : "有多个同名习惯，请提供更明确的名称。"
        }
        guard setHabitReminder(id: habit.id, hour: hour, minute: minute) else { return "提醒时间无效，请使用 00:00 到 23:59。" }
        guard let hour, let minute else { return "习惯「\(habit.title)」的提醒已关闭。" }
        return String(format: "习惯「%@」的提醒时间已设为 %02d:%02d；只会在计划日且当天未打卡时提醒。", habit.title, hour, minute)
    }

    func deleteHabit(_ id: UUID) {
        data.habits.removeAll { $0.id == id }
        data.habitCheckIns.removeAll { $0.habitID == id }
        save()
    }

    func habitListText() -> String {
        guard !data.habits.isEmpty else { return "目前还没有习惯。" }
        let rows = data.habits.map { habit -> String in
            let schedule = habit.schedule(on: Date())
            let weekdays = weekdayText(schedule.weekdays.subtracting(schedule.restDays))
            let completedToday = isHabitCheckedIn(habit.id, on: Date()) ? "今日已打卡" : "今日未打卡"
            let rests = weekdayText(schedule.restDays)
            let restLabel = rests.isEmpty ? "" : "；休息日 \(rests)"
            let reminder = habit.reminderHour.flatMap { hour in habit.reminderMinute.map { String(format: "；提醒 %02d:%02d", hour, $0) } } ?? "；未设提醒"
            return "- \(habit.title)：计划日 \(weekdays.isEmpty ? "无" : weekdays)\(restLabel)；\(completedToday)；历史最高连续 \(historicalStreak(for: habit)) 个计划日\(reminder)"
        }
        return "习惯列表（近30天完成率 \(habitCompletionRateLast30Days)%，历史最高连续 \(highestHabitStreak) 个计划日）：\n" + rows.joined(separator: "\n")
    }

    func weekdayText(_ weekdays: Set<Int>) -> String {
        let labels = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return weekdays.sorted().filter { (1...7).contains($0) }.map { labels[$0] }.joined(separator: "、")
    }

    func updateHabit(named title: String, newTitle: String?, weekdays: Set<Int>?, restDays: Set<Int>? = nil) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = data.habits.indices.filter { data.habits[$0].title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame }
        guard matches.count == 1, let index = matches.first else {
            return matches.isEmpty ? "没有找到名为「\(cleanTitle)」的习惯。" : "有多个同名习惯，请提供更明确的名称。"
        }
        let cleanNewTitle = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanNewTitle?.isEmpty == false || weekdays != nil || restDays != nil else {
            return "请提供新的习惯名称、计划日或休息日。"
        }
        if let weekdays, weekdays.isEmpty || !weekdays.allSatisfy({ (1...7).contains($0) }) {
            return "计划日无效，请使用 1 到 7（周一到周日）。"
        }
        if let restDays, !restDays.allSatisfy({ (1...7).contains($0) }) {
            return "休息日无效，请使用 1 到 7（周一到周日）。"
        }
        if let cleanNewTitle, !cleanNewTitle.isEmpty { data.habits[index].title = cleanNewTitle }
        if weekdays != nil || restDays != nil {
            let effectiveFrom = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
            let previous = data.habits[index].schedule(on: effectiveFrom)
            let nextWeekdays = weekdays ?? previous.weekdays
            let nextRestDays = restDays ?? previous.restDays
            let next = HabitScheduleVersion(effectiveFrom: effectiveFrom, weekdays: nextWeekdays, restDays: nextRestDays)
            if let lastIndex = data.habits[index].scheduleHistory.indices.last,
               data.habits[index].scheduleHistory[lastIndex].effectiveFrom == effectiveFrom {
                data.habits[index].scheduleHistory[lastIndex] = next
            } else {
                data.habits[index].scheduleHistory.append(next)
            }
            data.habits[index].weekdays = nextWeekdays
            data.habits[index].restDays = nextRestDays
        }
        save()
        return "习惯「\(cleanTitle)」已更新。计划或休息日变更从明天起生效，历史统计按当时的计划保留。"
    }

    func deleteHabit(named title: String) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = data.habits.filter { $0.title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame }
        guard matches.count == 1, let habit = matches.first else {
            return matches.isEmpty ? "没有找到名为「\(cleanTitle)」的习惯。" : "有多个同名习惯，请提供更明确的名称。"
        }
        deleteHabit(habit.id)
        return "习惯「\(cleanTitle)」及其打卡记录已删除。"
    }

    func recordHabitCheckIn(named title: String, on date: Date = Date()) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = data.habits.filter { $0.title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame }
        guard matches.count == 1, let habit = matches.first else {
            return matches.isEmpty ? "没有找到名为「\(cleanTitle)」的习惯。" : "有多个同名习惯，请提供更明确的名称。"
        }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        guard day <= calendar.startOfDay(for: Date()) else { return "不能为未来日期打卡。" }
        let schedule = habit.schedule(on: day)
        let weekday = calendar.component(.weekday, from: day)
        let index = weekday == 1 ? 7 : weekday - 1
        guard schedule.weekdays.contains(index) && !schedule.restDays.contains(index) else { return "这一天不是「\(cleanTitle)」的计划打卡日。" }
        if isHabitCheckedIn(habit.id, on: day) { return "「\(cleanTitle)」在该日已经打卡，无需重复记录。" }
        data.habitCheckIns.append(HabitCheckIn(habitID: habit.id, date: day, isBackfill: !calendar.isDateInToday(day)))
        save()
        let label = calendar.isDateInToday(day) ? "今日" : "补记（\(day.formatted(date: .abbreviated, time: .omitted))）"
        return "「\(cleanTitle)」\(label)打卡已记录。"
    }

    func setHabitCheckIn(_ habitID: UUID, on date: Date) {
        let calendar = Calendar.current
        if let index = data.habitCheckIns.firstIndex(where: { $0.habitID == habitID && calendar.isDate($0.date, inSameDayAs: date) }) {
            data.habitCheckIns.remove(at: index)
        } else {
            let day = calendar.startOfDay(for: date)
            data.habitCheckIns.append(HabitCheckIn(habitID: habitID, date: day, isBackfill: !calendar.isDateInToday(day)))
        }
        save()
    }

    func isHabitCheckedIn(_ habitID: UUID, on date: Date) -> Bool {
        data.habitCheckIns.contains { $0.habitID == habitID && Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    @discardableResult
    func save() -> Bool {
        do {
            var snapshot = data
            snapshot.schemaVersion = 3
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: fileURL, options: .atomic)
            data.schemaVersion = 3
            persistenceError = nil
            return true
        } catch {
            persistenceError = "本地记录保存失败：\(error.localizedDescription)"
            return false
        }
    }

    func reportPersistenceError(_ message: String) { persistenceError = message }
    func clearPersistenceError() { persistenceError = nil }

    func addProfileFact(category: String, content: String) -> Bool {
        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCategory.isEmpty, !cleanContent.isEmpty, cleanContent.count <= 500 else { return false }
        guard !data.profileFacts.contains(where: { profileFingerprint($0.content) == profileFingerprint(cleanContent) }) else { return false }
        let oldData = data
        data.profileFacts.append(DewyProfileFact(category: cleanCategory, content: cleanContent))
        guard save() else { data = oldData; return false }
        return true
    }

    private func profileFingerprint(_ value: String) -> String {
        let allowed = CharacterSet.letters.union(.decimalDigits)
        return String(value.lowercased().unicodeScalars.filter { allowed.contains($0) })
    }

    private func profileNgrams(_ value: String) -> Set<String> {
        let chars = Array(profileFingerprint(value))
        guard chars.count > 1 else { return Set(chars.map(String.init)) }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
    }

    private func profileSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = profileNgrams(lhs), right = profileNgrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(min(left.count, right.count))
    }

    func profileFactsContext(for query: String) -> String {
        let lower = query.lowercased()
        let managementTerms = ["画像", "记住", "记忆", "忘掉", "偏好", "作息", "长期目标", "用户画像"]
        let facts = managementTerms.contains(where: { lower.contains($0) })
            ? data.profileFacts
            : relevantProfileFacts(for: query)
        return facts.isEmpty ? "目前没有已确认的用户画像。" : facts.map { "- [\($0.category)] \($0.content)" }.joined(separator: "\n")
    }

    func userProfileText() -> String {
        let facts = data.profileFacts.isEmpty ? "目前还没有已确认的长期画像。" : data.profileFacts.map { "- [\($0.category)] \($0.content)" }.joined(separator: "\n")
        let candidates = data.profileCandidates.isEmpty ? "无待确认候选。" : data.profileCandidates.map { "- [\($0.category)] \($0.content)（尚未保存）" }.joined(separator: "\n")
        return "你目前的长期画像：\n\(facts)\n\n待确认候选：\n\(candidates)"
    }

    private func profileMatches(selector: String) -> [DewyProfileFact] {
        let key = profileFingerprint(selector)
        let exact = data.profileFacts.filter { profileFingerprint($0.content) == key }
        if !exact.isEmpty { return exact }
        return data.profileFacts.filter { profileFingerprint($0.category) == key }
    }

    private func profileMatchPrompt(_ matches: [DewyProfileFact], action: String) -> String {
        let options = matches.map { "- [\($0.category)] \($0.content)" }.joined(separator: "\n")
        return "我找到多条可能需要\(action)的画像，请告诉我具体是哪一条：\n\(options)"
    }

    func updateProfileFact(matching selector: String, newCategory: String?, newContent: String) -> String {
        let matches = profileMatches(selector: selector)
        guard matches.count == 1, let fact = matches.first else {
            return matches.isEmpty ? "没有找到与「\(selector)」完全匹配的画像。请告诉我想修改的原内容，或先问我当前保存了哪些画像。" : profileMatchPrompt(matches, action: "修改")
        }
        let proposedCategory = newCategory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let category = proposedCategory.isEmpty ? fact.category : proposedCategory
        guard updateProfileFact(fact.id, category: category, content: newContent) else { return "画像修改没有保存成功；原画像仍保留。" }
        return "画像已更新： [\(category)] \(newContent)"
    }

    func deleteProfileFact(matching selector: String) -> String {
        let matches = profileMatches(selector: selector)
        guard matches.count == 1, let fact = matches.first else {
            return matches.isEmpty ? "没有找到与「\(selector)」完全匹配的画像，没有删除任何内容。" : profileMatchPrompt(matches, action: "删除")
        }
        deleteProfileFact(fact.id)
        if data.profileFacts.contains(where: { $0.id == fact.id }) { return "画像删除失败，原内容仍保留。" }
        return "已删除画像： [\(fact.category)] \(fact.content)"
    }

    func handleProfileCandidateReply(_ raw: String) -> String? {
        guard let candidate = data.profileCandidates.first else { return nil }
        let allowed = CharacterSet.letters.union(.decimalDigits)
        let answer = String(raw.lowercased().unicodeScalars.filter { allowed.contains($0) })
        let noWords = ["忽略", "不要", "不记", "不保存", "不要记", "不需要", "不用", "不用了", "先不要", "算了", "取消", "拒绝", "不必", "不是", "我不想保存这条候选"]
        if noWords.contains(where: { answer == $0 || answer == "我" + $0 }) {
            dismissProfileCandidate(candidate.id)
            return "好的，这条候选我不会保存。"
        }
        if let existingID = candidate.possibleExistingFactID,
           let existing = data.profileFacts.first(where: { $0.id == existingID }) {
            let replaceWords = ["更新", "更新原来的", "替换", "替换旧的", "覆盖", "修改旧的", "用新的"]
            let keepWords = ["另存", "新增", "都保留", "保留两条", "作为新条目"]
            let wantsReplace = replaceWords.contains(where: { answer == $0 || answer == "我" + $0 })
            let wantsKeep = keepWords.contains(where: { answer == $0 || answer == "我" + $0 })
            if wantsReplace && wantsKeep {
                return "请只选一种处理方式：回复“更新”替换原画像，或“另存”保留两条；也可以回复“忽略”。"
            }
            if wantsKeep {
                let success = confirmProfileCandidate(candidate.id)
                return success ? "已将这条内容另存为新的画像。" : "保存失败，候选仍保留待确认。"
            }
            if wantsReplace {
                let success = confirmProfileCandidate(candidate.id, replacing: existing.id)
                return success ? "已用新内容更新原画像。" : "保存失败，原画像和候选都还保留着。"
            }
            let yesWords = ["是", "是的", "好", "好的", "好呀", "确认", "确认保存", "记住", "记住吧", "同意", "可以", "可以的", "要", "当然", "当然可以", "没问题", "我同意", "我确认", "我确认保存", "我确认保存刚才那条画像候选"]
            if yesWords.contains(where: { answer == $0 || answer == "我" + $0 }) {
                return "这条内容和已有画像相似。你希望“更新”原画像，还是“另存”一条？也可以回复“忽略”。"
            }
            return nil
        }
        let yesWords = ["是", "是的", "好", "好的", "好呀", "确认", "确认保存", "记住", "记住吧", "同意", "可以", "可以的", "要", "保存", "当然", "当然可以", "没问题", "我同意", "我确认", "我确认保存", "我确认保存刚才那条画像候选", "保存这条候选", "记住这条候选"]
        if yesWords.contains(where: { answer == $0 || answer == "我" + $0 || answer == "请" + $0 }) {
            let success = confirmProfileCandidate(candidate.id)
            return success ? "记下了，已加入你的长期画像。你随时可以让我查看、修改或忘掉它。" : "保存失败，候选还在；你可以稍后再确认。"
        }
        if noWords.contains(where: { answer == $0 || answer == "我" + $0 }) {
            dismissProfileCandidate(candidate.id)
            return "好的，这条候选我不会保存。"
        }
        return nil
    }

    func proposeProfileFact(category: String, content: String) -> String {
        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCategory.isEmpty, cleanCategory.count <= 40, !cleanContent.isEmpty, cleanContent.count <= 500 else {
            return "画像候选内容无效，没有保存。"
        }
        if data.profileFacts.contains(where: { profileFingerprint($0.content) == profileFingerprint(cleanContent) }) {
            return "这条内容已在长期画像中，不需要重复添加。"
        }
        if data.profileCandidates.contains(where: { profileFingerprint($0.content) == profileFingerprint(cleanContent) }) {
            return "这条画像候选已经在聊天中等待你确认。"
        }
        if let pending = data.profileCandidates.first {
            return "还有一条画像候选等待你处理：「\(pending.content)」。请先回复“记住”或“忽略”；如果它与已有内容相似，请回复“更新”“另存”或“忽略”。"
        }
        let sameCategory = data.profileFacts.filter { profileFingerprint($0.category) == profileFingerprint(cleanCategory) }
        let possibleMatch = sameCategory
            .map { ($0, profileSimilarity($0.content, cleanContent)) }
            .filter { $0.1 >= 0.55 }
            .max { $0.1 < $1.1 }?.0
        let candidate = DewyProfileCandidate(category: cleanCategory, content: cleanContent, possibleExistingFactID: possibleMatch?.id)
        data.profileCandidates.append(candidate)
        guard save() else {
            data.profileCandidates.removeAll { $0.id == candidate.id }
            return "候选画像没有保存成功；请检查本地存储。"
        }
        if let possibleMatch {
            return "我发现一条可能与现有画像相似的内容：「\(cleanContent)」。回复“更新”替换「\(possibleMatch.content)」，回复“另存”保留两条，或回复“忽略”。"
        }
        return "我觉得这条信息以后可能有用：「\(cleanContent)」。要我记住吗？回复“记住”保存，或回复“忽略”。"
    }

    func confirmProfileCandidate(_ id: UUID, replacing factID: UUID? = nil) -> Bool {
        guard let candidateIndex = data.profileCandidates.firstIndex(where: { $0.id == id }) else { return false }
        let candidate = data.profileCandidates[candidateIndex]
        let oldData = data
        if let factID, let index = data.profileFacts.firstIndex(where: { $0.id == factID }) {
            data.profileFacts[index].category = candidate.category
            data.profileFacts[index].content = candidate.content
            data.profileFacts[index].updatedAt = Date()
            data.profileFacts[index].confirmedAt = Date()
        } else {
            data.profileFacts.append(DewyProfileFact(category: candidate.category, content: candidate.content))
        }
        data.profileCandidates.remove(at: candidateIndex)
        guard save() else { data = oldData; return false }
        return true
    }

    func dismissProfileCandidate(_ id: UUID) {
        let oldData = data
        data.profileCandidates.removeAll { $0.id == id }
        if !save() { data = oldData }
    }

    func confirmProfileFactReviewed(_ id: UUID) {
        guard let index = data.profileFacts.firstIndex(where: { $0.id == id }) else { return }
        let oldData = data
        data.profileFacts[index].confirmedAt = Date()
        data.profileFacts[index].updatedAt = Date()
        if !save() { data = oldData }
    }

    func relevantProfileFacts(for query: String, limit: Int = 4) -> [DewyProfileFact] {
        let queryNgrams = profileNgrams(query)
        guard !queryNgrams.isEmpty else { return [] }
        let categoryHints: [(Set<String>, Set<String>)] = [
            (["工作", "职业", "求职", "实习", "简历", "面试"], ["工作", "职业", "长期目标"]),
            (["学习", "课程", "考试", "研究", "学校"], ["学习", "教育", "长期目标"]),
            (["睡眠", "作息", "起床", "早上", "晚上"], ["作息", "习惯"]),
            (["回答", "语气", "风格", "喜欢", "偏好"], ["偏好", "沟通"])
        ]
        return data.profileFacts.map { fact -> (DewyProfileFact, Double) in
            let contentNgrams = profileNgrams(fact.content)
            let overlap = Double(queryNgrams.intersection(contentNgrams).count) / Double(max(1, queryNgrams.count))
            let hinted = categoryHints.contains { words, categories in
                words.contains(where: { query.localizedCaseInsensitiveContains($0) })
                    && categories.contains(where: { fact.category.localizedCaseInsensitiveContains($0) })
            }
            return (fact, overlap + (hinted ? 0.25 : 0))
        }
        .filter { $0.1 >= 0.08 }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    func needsProfileReview(_ fact: DewyProfileFact, now: Date = Date()) -> Bool {
        now.timeIntervalSince(fact.confirmedAt) >= 180 * 24 * 60 * 60
    }

    func updateProfileFact(_ id: UUID, category: String, content: String) -> Bool {
        guard let index = data.profileFacts.firstIndex(where: { $0.id == id }) else { return false }
        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCategory.isEmpty, !cleanContent.isEmpty, cleanContent.count <= 500 else { return false }
        let oldData = data
        data.profileFacts[index].category = cleanCategory
        data.profileFacts[index].content = cleanContent
        data.profileFacts[index].updatedAt = Date()
        data.profileFacts[index].confirmedAt = Date()
        guard save() else { data = oldData; return false }
        return true
    }

    func deleteProfileFact(_ id: UUID) {
        let oldData = data
        data.profileFacts.removeAll { $0.id == id }
        if !save() { data = oldData }
    }

    func markdownReport(period: String) -> String {
        let heading = period == "month" ? "Dewy 月度复盘" : "Dewy 周复盘"
        let range: String
        let body: String
        if period == "month" {
            let calendar = Calendar.current
            let start = calendar.dateInterval(of: .month, for: Date.now)?.start ?? Date.now
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? Date.now
            range = Date.now.formatted(.dateTime.year().month())
            let savedWeeks = data.weeklyReviews.filter { $0.weekStart < end && $0.weekEnd > start }.sorted { $0.weekStart < $1.weekStart }
            let reviews = savedWeeks.isEmpty ? "本月尚无已保存的周复盘。" : savedWeeks.map { $0.facts }.joined(separator: "\n\n---\n\n")
            body = "## 已保存的周复盘\n\n\(reviews)\n\n## 本月尚在本地的详细记录\n\n\(dailySummary(period: "month"))"
        } else if let review = data.weeklyReviews.max(by: { $0.weekStart < $1.weekStart }) {
            range = "\(review.weekStart.formatted(date: .numeric, time: .omitted)) 至 \(review.weekEnd.addingTimeInterval(-1).formatted(date: .numeric, time: .omitted))"
            body = review.facts
        } else {
            range = Date.now.formatted(date: .numeric, time: .omitted)
            body = "尚无已保存的周复盘。"
        }
        return "---\ntitle: \"\(heading)\"\nperiod: \"\(range)\"\ngenerated: \"\(Date.now.formatted(date: .numeric, time: .shortened))\"\nsource: Dewy\n---\n\n# \(heading)\n\n周期：\(range)\n\n\(body)\n"
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

    /// 标记某个 task 为已完成（并保存）
    func markTaskCompleted(_ id: UUID) {
        guard let index = data.tasks.firstIndex(where: { $0.id == id }),
              data.tasks[index].status != "已完成" else { return }
        data.tasks[index].status = "已完成"
        recordTaskCompletion(data.tasks[index])
        refreshStatus()
    }

    private func recordTaskCompletion(_ task: DewyTask) {
        guard task.category == "工作" else { return }
        _ = addWork("完成待办：\(task.title)", source: "task_completion", sourceID: "task-completed:\(task.id.uuidString)")
    }

    func setGoalProgress(id: UUID, progress: String) {
        guard let index = data.goals.firstIndex(where: { $0.id == id }) else { return }
        let cleanProgress = progress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanProgress.isEmpty, data.goals[index].progress != cleanProgress else { return }
        let title = data.goals[index].title
        data.goals[index].progress = cleanProgress
        _ = addWork("目标「\(title)」进展：\(cleanProgress)", source: "goal_progress", sourceID: "goal-progress:\(UUID().uuidString)")
    }

    /// 切换某个 task 的完成状态（已完成 <-> 待办）
    func toggleTaskCompletion(_ id: UUID) {
        guard let index = data.tasks.firstIndex(where: { $0.id == id }) else { return }
        if data.tasks[index].status == "已完成" {
            data.tasks[index].status = "待办"
            save()
        } else {
            data.tasks[index].status = "已完成"
            recordTaskCompletion(data.tasks[index])
        }
        refreshStatus()
    }

    @discardableResult
    func clearCompletedTasks() -> Int {
        let completedCount = data.tasks.filter { $0.status == "已完成" }.count
        guard completedCount > 0 else { return 0 }
        data.tasks.removeAll { $0.status == "已完成" }
        save()
        refreshStatus()
        return completedCount
    }

    func addActivity(_ title: String, category: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "告诉我想安排的活动，我会帮你记下来。" }
        data.tasks.append(DewyTask(title: clean, category: category)); save()
        return "\(category)安排记下啦：\(clean)。工作和休息都值得留出位置。"
    }

    func startFocus(task: String = "未关联任务", taskID: UUID? = nil) -> String {
        guard !focusIsRunning else { return "专注时段还在进行中。已经专注 \(formatDuration(focusSeconds))，我会安静陪着你。" }
        let linkedTask = data.tasks.first(where: { $0.id == taskID })
        let taskTitle = linkedTask?.title ?? task
        data.focus.append(FocusLog(startedAt: Date(), task: taskTitle, taskID: linkedTask?.id)); focusIsRunning = true; focusSeconds = 0; status = "focus"; startTicking(); save()
        return "好，我们开始一个 \(data.settings.focusMinutes) 分钟的专注时段。我会安静陪着你。"
    }

    func setFocusTask(sessionID: UUID, taskID: UUID?) {
        guard let index = data.focus.firstIndex(where: { $0.id == sessionID }) else { return }
        let task = data.tasks.first(where: { $0.id == taskID })
        data.focus[index].taskID = task?.id
        data.focus[index].task = task?.title ?? "未关联任务"
        let session = data.focus[index]
        save()
        if session.endedAt != nil { recordFocusWork(session) }
    }

    func linkFocusTask(taskTitle: String, sessionScope: String? = nil) -> String {
        let cleanTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return "请告诉我想关联的待办名称。" }

        // let matchingTasks = data.tasks.filter {
        //     $0.title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame
        // }
        // guard matchingTasks.count == 1, let task = matchingTasks.first else {
        //     return matchingTasks.isEmpty
        //         ? "没有找到标题为“\(cleanTitle)”的待办，请确认待办名称。"
        //         : "找到多条同名待办，请先在记录面板中区分或重命名。"
        // }

        let activeSessions = data.focus
            .filter { $0.endedAt == nil }
            .sorted { $0.startedAt > $1.startedAt }
        let endedSessions = data.focus
            .filter { $0.endedAt != nil }
            .sorted { $0.startedAt > $1.startedAt }

        let session: FocusLog?
        switch sessionScope {
        case "current":
            session = activeSessions.first
        case "latest_ended":
            session = endedSessions.first
        case nil, "":
            session = activeSessions.first ?? endedSessions.first
        default:
            return "专注记录范围无效，请指定当前专注或最近结束的专注。"
        }

        guard let session else {
            return sessionScope == "current"
                ? "现在没有正在进行的专注时段。"
                : "还没有可以关联的专注记录。"
        }

        let matchingTasks = data.tasks.filter {
            $0.title.localizedCaseInsensitiveCompare(cleanTitle) == .orderedSame
        }

        let task: DewyTask
        let createdTask: Bool

        if matchingTasks.count == 1, let existingTask = matchingTasks.first {
            task = existingTask
            createdTask = false
        } else if matchingTasks.isEmpty {
            let newTask = DewyTask(title: cleanTitle)
            data.tasks.append(newTask)
            task = newTask
            createdTask = true
        } else {
            return "找到多条同名待办，请先在记录面板中区分或重命名。"
        }

        setFocusTask(sessionID: session.id, taskID: task.id)
        let timing = session.endedAt == nil ? "当前专注" : "最近结束的专注"
        // return "已将\(timing)关联到待办「\(task.title)」。"
        if createdTask {
        return "没有找到现有待办，已新建「\(task.title)」并关联到\(timing)。"
        }
        return "已将\(timing)关联到待办「\(task.title)」。"
    }

    private func recordFocusWork(_ session: FocusLog) {
        let sourceID = "focus-session:\(session.id.uuidString)"
        guard session.taskID != nil, session.task != "未关联任务" else {
            data.work.removeAll { $0.sourceID == sourceID }
            save()
            return
        }
        _ = addWork("围绕待办「\(session.task)」进行了专注推进", source: "focus_task", sourceID: sourceID)
    }

    @discardableResult
    func deleteFocusSession(_ id: UUID) -> Bool {
        guard let index = data.focus.firstIndex(where: { $0.id == id }), data.focus[index].endedAt != nil else { return false }
        data.focus.remove(at: index)
        save()
        return true
    }

    func stopFocus(cancel: Bool = false) -> String {
        guard focusIsRunning, let index = data.focus.lastIndex(where: { $0.endedAt == nil }) else { return "现在没有正在进行的专注时段。" }
        data.focus[index].endedAt = Date()
        let completedSession = data.focus[index]
        focusIsRunning = false
        refreshStatus()
        focusTimer?.invalidate()
        focusTimer = nil
        if completedSession.taskID != nil { recordFocusWork(completedSession) }
        save()
        processWeeklyMaintenance(at: Date())
        let elapsed = focusSeconds
        return cancel ? "专注时段已结束，记录了实际的 \(formatDuration(elapsed))。没关系，专注本来就需要练习，下次再试试？" : "这一段专注完成啦，记录了 \(formatDuration(elapsed))。做得很好，给自己一点小小的休息吧。"
    }

    private func enforceFocusTimeLimit(at now: Date = Date()) {
    guard focusIsRunning,
          let session = data.focus.last(where: { $0.endedAt == nil }) else {
        return
    }

    let elapsed = max(0, Int(now.timeIntervalSince(session.startedAt)))
    focusSeconds = elapsed

    guard elapsed >= 2 * 60 * 60 else { return }

    _ = stopFocus()
    postProactiveMessage("已经连续专注两小时啦。这段专注已自动结束，先喝杯水、起来活动一下，舒展舒展身体吧。")
}

    // 计算一个 FocusLog 在给定时间区间 (start .. end) 内的重叠秒数
    private static func secondsOverlap(of session: FocusLog, inRange start: Date, _ end: Date) -> Int {
        let s = session.startedAt
        let e = session.endedAt ?? Date()
        // 计算重叠区间 [overlapStart, overlapEnd)
        let overlapStart = (s < start) ? start : s
        let overlapEnd = (e > end) ? end : e
        if overlapEnd <= overlapStart { return 0 }
        return Int(overlapEnd.timeIntervalSince(overlapStart))
    }

    var focusTodaySeconds: Int {
    let startOfDay = Calendar.current.startOfDay(for: Date())
    return DewyStore.secondsOverlapAggregate(inRange: startOfDay, end: Date(), sessions: data.focus)
    }

    private static func secondsOverlapAggregate(inRange start: Date, end: Date, sessions: [FocusLog]) -> Int {
    sessions.reduce(0) { $0 + secondsOverlap(of: $1, inRange: start, end) }
    }


    private func startTicking() {
    focusTimer?.invalidate()
    focusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        Task { @MainActor in
            guard let self else { return }

            let now = Date()
            self.enforceFocusTimeLimit(at: now)

            guard self.focusIsRunning else { return }

            if now.timeIntervalSince(self.lastSave) >= 30 {
                self.save()
                self.lastSave = now
            }
        }
    }
}

    func startMonitoring() {
        monitorTimer?.invalidate()
        processWeeklyMaintenance(at: Date())
        enforceFocusTimeLimit()
        checkHabitReminders()
        scheduleNextWeeklySummary()
        scheduleNextWeeklyCleanup()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHydrationReminder() }
            Task { @MainActor in self?.checkHabitReminders() }
        }
        refreshStatus()
    }

    private func weekEventDate(for interval: DateInterval, hour: Int, minute: Int) -> Date? {
        let calendar = Calendar.current
        let lastDay = interval.end.addingTimeInterval(-1)
        var components = calendar.dateComponents([.era, .year, .month, .day], from: lastDay)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    private func nextWeekEventDate(hour: Int, minute: Int, after now: Date) -> Date? {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: now),
              let eventDate = weekEventDate(for: interval, hour: hour, minute: minute) else { return nil }
        if eventDate > now { return eventDate }
        guard let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: interval.start),
              let nextInterval = calendar.dateInterval(of: .weekOfYear, for: nextWeek) else { return nil }
        return weekEventDate(for: nextInterval, hour: hour, minute: minute)
    }

    private func scheduleNextWeeklySummary() {
        weeklySummaryTimer?.invalidate()
        guard let eventDate = nextWeekEventDate(hour: 22, minute: 0, after: Date()) else { return }
        weeklySummaryTimer = Timer.scheduledTimer(withTimeInterval: max(1, eventDate.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.processWeeklyMaintenance(at: Date())
                self.postProactiveMessage("本周复盘已生成并保存在本机。你可以打开 Dewy 查看事实汇总，或让我基于记录提供建议。")
                self.scheduleNextWeeklySummary()
            }
        }
    }

    private func scheduleNextWeeklyCleanup() {
        weeklyCleanupTimer?.invalidate()
        guard let eventDate = nextWeekEventDate(hour: 23, minute: 59, after: Date()) else { return }
        weeklyCleanupTimer = Timer.scheduledTimer(withTimeInterval: max(1, eventDate.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.processWeeklyMaintenance(at: Date())
                self.scheduleNextWeeklyCleanup()
            }
        }
    }

    private func processWeeklyMaintenance(at now: Date) {
        let calendar = Calendar.current
        var intervalsByStart: [Date: DateInterval] = [:]
        let recordDates = data.work.map(\.date) + data.meals.map(\.date) + data.focus.map(\.startedAt)
            + data.water.map(\.date) + data.sleep.map(\.wakeTime) + data.habitCheckIns.map(\.date)
        for date in recordDates {
            if let interval = calendar.dateInterval(of: .weekOfYear, for: date) { intervalsByStart[interval.start] = interval }
        }
        if let current = calendar.dateInterval(of: .weekOfYear, for: now),
           let summaryTime = weekEventDate(for: current, hour: 22, minute: 0), now >= summaryTime {
            intervalsByStart[current.start] = current
        }

        for interval in intervalsByStart.values.sorted(by: { $0.start < $1.start }) {
            guard let summaryTime = weekEventDate(for: interval, hour: 22, minute: 0), now >= summaryTime,
                  let cleanupTime = weekEventDate(for: interval, hour: 23, minute: 59) else { continue }
            let hasDetails = data.work.contains { $0.date >= interval.start && $0.date < interval.end }
                || data.meals.contains { $0.date >= interval.start && $0.date < interval.end }
                || data.focus.contains { $0.startedAt < interval.end && ($0.endedAt ?? now) > interval.start }
            let reviewIndex = data.weeklyReviews.firstIndex(where: { $0.weekStart == interval.start })
            if reviewIndex == nil || now < cleanupTime || hasDetails {
                let prior = data
                let review = makeWeeklyReview(for: interval, generatedAt: now)
                if let reviewIndex { data.weeklyReviews[reviewIndex] = review } else { data.weeklyReviews.append(review) }
                guard save() else { data = prior; return }
            }

            guard now >= cleanupTime, data.weeklyReviews.contains(where: { $0.weekStart == interval.start }) else { continue }
            let backupDirectory = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: interval.start).replacingOccurrences(of: ":", with: "-")
                let backupURL = backupDirectory.appendingPathComponent("records-before-cleanup-\(stamp).json")
                if !FileManager.default.fileExists(atPath: backupURL.path) { try FileManager.default.copyItem(at: fileURL, to: backupURL) }
            } catch {
                persistenceError = "周复盘已保存，但创建清理备份失败，明细暂未清理：\(error.localizedDescription)"
                return
            }
            let prior = data
            data.work.removeAll { $0.date >= interval.start && $0.date < interval.end }
            data.meals.removeAll { $0.date >= interval.start && $0.date < interval.end }
            data.focus.removeAll { $0.startedAt >= interval.start && $0.startedAt < interval.end && $0.endedAt != nil }
            guard save() else { data = prior; return }
        }
    }

    private func makeWeeklyReview(for interval: DateInterval, generatedAt: Date) -> WeeklyReview {
        let reportEnd = min(interval.end, generatedAt)
        let workLogs = data.work.filter { $0.date >= interval.start && $0.date < reportEnd }.sorted { $0.date < $1.date }
        let mealLogs = data.meals.filter { $0.date >= interval.start && $0.date < reportEnd }.sorted { $0.date < $1.date }
        let focusLogs = data.focus.filter { $0.startedAt < reportEnd && ($0.endedAt ?? reportEnd) > interval.start }
        let focusSeconds = focusLogs.reduce(0) { $0 + Self.secondsOverlap(of: $1, inRange: interval.start, reportEnd) }
        let lastDay = interval.end.addingTimeInterval(-1)
        let weekLabel = "\(interval.start.formatted(date: .abbreviated, time: .omitted)) 至 \(lastDay.formatted(date: .abbreviated, time: .omitted))"
        let workText = workLogs.isEmpty ? "暂无工作记录" : workLogs.map { "· \($0.date.formatted(date: .abbreviated, time: .shortened))  \($0.details)" }.joined(separator: "\n")
        let mealText = mealLogs.isEmpty ? "暂无饮食记录" : mealLogs.map { "· \($0.date.formatted(date: .abbreviated, time: .shortened))  \($0.details)" }.joined(separator: "\n")
        let focusText = focusLogs.isEmpty ? "暂无专注记录" : focusLogs.map { session in
            let duration = Self.secondsOverlap(of: session, inRange: interval.start, reportEnd)
            let active = session.endedAt == nil ? "（汇总时仍在进行）" : ""
            return "· \(session.startedAt.formatted(date: .abbreviated, time: .shortened))  \(session.task) · \(formatDuration(duration))\(active)"
        }.joined(separator: "\n")
        let waterLogs = data.water.filter { $0.date >= interval.start && $0.date < reportEnd }
        let sleepLogs = data.sleep.filter { $0.wakeTime >= interval.start && $0.wakeTime < reportEnd }
        let checkIns = data.habitCheckIns.filter { $0.date >= interval.start && $0.date < reportEnd }
        var plannedDays = 0
        for habit in data.habits {
            var day = max(interval.start, Calendar.current.startOfDay(for: habit.createdAt))
            while day < reportEnd {
                let weekday = Calendar.current.component(.weekday, from: day)
                let index = weekday == 1 ? 7 : weekday - 1
                let schedule = habit.schedule(on: day)
                if schedule.weekdays.contains(index) && !schedule.restDays.contains(index) { plannedDays += 1 }
                day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? reportEnd
            }
        }
        let metrics = WeeklyReviewMetrics(workCount: workLogs.count, mealCount: mealLogs.count, focusCount: focusLogs.count,
            focusSeconds: focusSeconds, waterMilliliters: waterLogs.reduce(0) { $0 + $1.milliliters }, sleepCount: sleepLogs.count,
            habitPlannedDays: plannedDays, habitCompletedDays: checkIns.count)
        let metricText = "\n\n## 本周统计\n\n- 工作记录：\(metrics.workCount) 条\n- 饮食记录：\(metrics.mealCount) 条\n- 专注：\(metrics.focusCount) 段，共 \(formatDuration(focusSeconds))\n- 饮水：\(metrics.waterMilliliters) ml\n- 睡眠记录：\(metrics.sleepCount) 条\n- 习惯打卡：\(metrics.habitCompletedDays) / \(metrics.habitPlannedDays) 个计划日"
        let facts = "周复盘事实汇总（\(weekLabel)）\n\n工作记录：\n\(workText)\n\n饮食记录：\n\(mealText)\n\n专注记录：\n\(focusText)\n专注总时长：\(formatDuration(focusSeconds))\(metricText)"
        return WeeklyReview(weekStart: interval.start, weekEnd: interval.end, generatedAt: generatedAt, facts: facts, metrics: metrics)
    }

    private func previousWeekInterval(from date: Date = Date()) -> DateInterval? {
        let calendar = Calendar.current
        guard let current = calendar.dateInterval(of: .weekOfYear, for: date),
              let previousDate = calendar.date(byAdding: .second, value: -1, to: current.start) else { return nil }
        return calendar.dateInterval(of: .weekOfYear, for: previousDate)
    }

    func previousWeekReviewText() -> String {
        guard let interval = previousWeekInterval(),
              let review = data.weeklyReviews.first(where: { $0.weekStart == interval.start }) else {
            return "还没有找到上周已保存的复盘汇总。"
        }
        return review.facts
    }

    private func checkHydrationReminder() {
        guard !isQuietTime(), !focusIsRunning else { refreshStatus(); return }
        let baseline = data.water.last(where: { Calendar.current.isDateInToday($0.date) })?.date ?? launchedAt
        let nextAllowed = lastReminderAt.map { max(baseline, $0) } ?? baseline
        guard Date().timeIntervalSince(nextAllowed) >= 2 * 60 * 60, status != "hydration" else { return }
        status = "hydration"; lastReminderAt = Date()
        postProactiveMessage("喝水提醒：已经有一段时间没有记录饮水了，方便时喝几口水吧。")
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    private func checkHabitReminders(at now: Date = Date()) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let weekdayIndex = weekday == 1 ? 7 : weekday - 1
        var dueHabitIndices: [Int] = []

        for index in data.habits.indices {
            let habit = data.habits[index]
            guard let reminderHour = habit.reminderHour,
                  let reminderMinute = habit.reminderMinute,
                  let reminderDate = calendar.date(bySettingHour: reminderHour, minute: reminderMinute, second: 0, of: today),
                  now >= reminderDate,
                  now.timeIntervalSince(reminderDate) < 5 * 60,
                  habit.schedule(on: today).weekdays.contains(weekdayIndex),
                  !habit.schedule(on: today).restDays.contains(weekdayIndex),
                  !isHabitCheckedIn(habit.id, on: today),
                  !(habit.lastReminderDate.map { calendar.isDate($0, inSameDayAs: today) } ?? false) else { continue }
            dueHabitIndices.append(index)
        }

        guard !dueHabitIndices.isEmpty else { return }
        let titles = dueHabitIndices.map { data.habits[$0].title }
        for index in dueHabitIndices { data.habits[index].lastReminderDate = now }
        save()
        let habitsText = titles.joined(separator: "、")
        postProactiveMessage("习惯打卡提醒：\(habitsText)。完成后可以在习惯页打卡，也可以告诉我“\(titles[0])已完成”。")
    }

    func postProactiveMessage(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let notice = DewyProactiveNotice(text: clean)
        proactiveNotice = notice
        appendMessage(ChatLine(role: .assistant, text: clean))
        onProactiveMessage?(notice)
    }

    func clearProactiveNotice(id: UUID) {
        guard proactiveNotice?.id == id else { return }
        proactiveNotice = nil
    }

    private func isQuietTime() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        let start = data.settings.quietStart; let end = data.settings.quietEnd
        return start > end ? (hour >= start || hour < end) : (hour >= start && hour < end)
    }

    private func refreshStatus() { status = focusIsRunning ? "focus" : (isQuietTime() ? "sleepy" : "idle") }

    func addWork(_ detail: String, source: String = "manual", sourceID: String? = nil) -> String {
        let clean = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "可以告诉我今天完成了什么，或遇到了什么问题。" }
        if let sourceID, let index = data.work.firstIndex(where: { $0.sourceID == sourceID }) {
            data.work[index].details = clean
            data.work[index].source = source
        } else {
            data.work.append(WorkLog(details: clean, source: source, sourceID: sourceID))
        }
        save()
        return "工作记录保存好了。今天做过的事，都会慢慢成为你的积累。"
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
        if hrs < 6 { return String(format: "睡眠记下啦：%.1f 小时。睡眠时间太短了，建议保证至少 6 小时的休息, 8 小时比较健康噢。", hrs) }
        if hrs > 10 { return String(format: "睡眠记下啦：%.1f 小时。睡眠时间过长可能影响健康，建议保持在 7-8 小时之间。", hrs) }
        else { return String(format: "睡眠记下啦：%.1f 小时。谢谢你照顾了自己的休息", hrs) }
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
        if period == "week" {
            let now = Date()
            processWeeklyMaintenance(at: now)
            if let interval = Calendar.current.dateInterval(of: .weekOfYear, for: now),
               let cleanupTime = weekEventDate(for: interval, hour: 23, minute: 59), now >= cleanupTime,
               let savedReview = data.weeklyReviews.first(where: { $0.weekStart == interval.start }) {
                return savedReview.facts
            }
        }
        let component: Calendar.Component = period == "week" ? .weekOfYear : (period == "month" ? .month : .day)
        let start = Calendar.current.dateInterval(of: component, for: Date())?.start ?? Calendar.current.startOfDay(for: Date())
        let tasks = data.tasks.filter { $0.createdAt >= start }
        let done = tasks.filter { $0.status == "已完成" }.count
        let water = data.water.filter { $0.date >= start }.reduce(0) { $0 + $1.milliliters }
        let logs = data.work.filter { $0.date >= start }
        let meals = data.meals.filter { $0.date >= start }
        let sleepLogs = data.sleep.filter { $0.wakeTime >= start }
        let goals = data.goals.filter { $0.status == "进行中" }
        // let focus = data.focus.filter { $0.startedAt >= start }.reduce(0) { $0 + Int(($1.endedAt ?? Date()).timeIntervalSince($1.startedAt)) }
        // 统计专注时长：把每个 focus session 在 period 开始到现在的重叠时长累加
        let endDate = Date()
        let focusSecondsTotal = data.focus.reduce(0) { acc, session in
            acc + Self.secondsOverlap(of: session, inRange: start, endDate)
        }
        // 注意 dailySummary 输出使用 formatDuration(focusSecondsTotal)
        let periodLabel = period == "day" ? "今天" : (period == "week" ? "本周" : "本月")
        let workText = logs.isEmpty ? "尚无工作内容记录" : logs.map { "· \($0.details)" }.joined(separator: "\n")
        let mealText = meals.isEmpty ? "未记录" : meals.map(\.details).joined(separator: "、")
        let sleepText = sleepLogs.isEmpty ? "未记录" : sleepLogs.map { formatDuration(Int($0.wakeTime.timeIntervalSince($0.bedtime))) }.joined(separator: "、")
        let goalText = goals.isEmpty ? "暂无进行中的目标" : goals.map { "\($0.title)：\($0.progress)" }.joined(separator: "；")
        let pending = tasks.filter { $0.status == "待办" || $0.status == "进行中" }.map { $0.title }.prefix(3).joined(separator: "、")
        let next = pending.isEmpty ? "目前没有未完成待办" : "还可以留意：\(pending)"
        return "\(periodLabel)回顾\n待办完成：\(done) / \(tasks.count)\n专注时长：\(formatDuration(focusSecondsTotal))\n饮水记录：\(water) ml\n饮食记录：\(mealText)\n睡眠记录：\(sleepText)\n工作记录：\n\(workText)\n目标进度：\(goalText)\n\(next)\n\n这些总结只基于已经记录的内容；未记录的部分我不会替你猜测。"
    }
}
