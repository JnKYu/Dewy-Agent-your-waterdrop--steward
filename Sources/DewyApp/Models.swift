import Foundation

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
    var source: String? = nil
    var sourceID: String? = nil
}

struct FocusLog: Codable, Identifiable {
    var id = UUID()
    var startedAt: Date
    var endedAt: Date? = nil
    var task: String = "未关联任务"
    var taskID: UUID? = nil
    var note: String = ""
}

struct WeeklyReviewMetrics: Codable {
    var workCount: Int = 0
    var mealCount: Int = 0
    var focusCount: Int = 0
    var focusSeconds: Int = 0
    var waterMilliliters: Int = 0
    var sleepCount: Int = 0
    var habitPlannedDays: Int = 0
    var habitCompletedDays: Int = 0
}

struct WeeklyReview: Codable, Identifiable {
    var weekStart: Date
    var weekEnd: Date
    var generatedAt: Date
    var facts: String
    var metrics: WeeklyReviewMetrics? = nil
    var id: Date { weekStart }
}

struct DewyProfileFact: Codable, Identifiable {
    var id = UUID()
    var category: String
    var content: String
    var createdAt = Date()
    var updatedAt = Date()
    var confirmedAt = Date()
}

struct DewyProfileCandidate: Codable, Identifiable {
    var id = UUID()
    var category: String
    var content: String
    var createdAt = Date()
    var possibleExistingFactID: UUID? = nil
}

struct DewyGoal: Codable, Identifiable {
    var id = UUID()
    var title: String
    var detail: String = ""
    var deadline: Date? = nil
    var progress: String = "尚未更新"
    var status = "进行中"
}

struct HabitScheduleVersion: Codable, Identifiable {
    var id = UUID()
    var effectiveFrom: Date
    var weekdays: Set<Int>
    var restDays: Set<Int>
}

struct DewyHabit: Codable, Identifiable {
    var id: UUID
    var title: String
    var weekdays: Set<Int>
    var reminderHour: Int?
    var reminderMinute: Int?
    var lastReminderDate: Date?
    var restDays: Set<Int>
    var createdAt: Date
    var scheduleHistory: [HabitScheduleVersion]

    init(title: String, weekdays: Set<Int> = Set(1...7), restDays: Set<Int> = [], createdAt: Date = Date()) {
        self.id = UUID()
        self.title = title
        self.weekdays = weekdays
        self.reminderHour = nil
        self.reminderMinute = nil
        self.lastReminderDate = nil
        self.restDays = restDays
        self.createdAt = createdAt
        self.scheduleHistory = [HabitScheduleVersion(
            effectiveFrom: Calendar.current.startOfDay(for: createdAt),
            weekdays: weekdays,
            restDays: restDays
        )]
    }

    func schedule(on date: Date) -> HabitScheduleVersion {
        scheduleHistory
            .filter { $0.effectiveFrom <= date }
            .max { $0.effectiveFrom < $1.effectiveFrom }
            ?? HabitScheduleVersion(effectiveFrom: createdAt, weekdays: weekdays, restDays: restDays)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, weekdays, reminderHour, reminderMinute, lastReminderDate, restDays, createdAt, scheduleHistory
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decode(String.self, forKey: .title)
        weekdays = try values.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? Set(1...7)
        reminderHour = try values.decodeIfPresent(Int.self, forKey: .reminderHour)
        reminderMinute = try values.decodeIfPresent(Int.self, forKey: .reminderMinute)
        lastReminderDate = try values.decodeIfPresent(Date.self, forKey: .lastReminderDate)
        restDays = try values.decodeIfPresent(Set<Int>.self, forKey: .restDays) ?? []
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        scheduleHistory = try values.decodeIfPresent([HabitScheduleVersion].self, forKey: .scheduleHistory)
            ?? [HabitScheduleVersion(effectiveFrom: Calendar.current.startOfDay(for: createdAt), weekdays: weekdays, restDays: restDays)]
    }
}

struct DewyProactiveNotice: Identifiable {
    var id = UUID()
    var text: String
}

struct HabitCheckIn: Codable, Identifiable {
    var id = UUID()
    var habitID: UUID
    var date: Date
    var recordedAt = Date()
    var isBackfill = false
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
    var schemaVersion = 3
    var profileFacts: [DewyProfileFact] = []
    var profileCandidates: [DewyProfileCandidate] = []
    var settings = DewySettings()
    var tasks: [DewyTask] = []
    var water: [WaterLog] = []
    var meals: [MealLog] = []
    var sleep: [SleepLog] = []
    var work: [WorkLog] = []
    var focus: [FocusLog] = []
    var goals: [DewyGoal] = []
    var habits: [DewyHabit] = []
    var habitCheckIns: [HabitCheckIn] = []
    var weeklyReviews: [WeeklyReview] = []
    var chatHistory: [ChatLine] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profileFacts, profileCandidates, settings, tasks, water, meals, sleep, work, focus, goals, habits, habitCheckIns, weeklyReviews, chatHistory
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        profileFacts = try values.decodeIfPresent([DewyProfileFact].self, forKey: .profileFacts) ?? []
        profileCandidates = try values.decodeIfPresent([DewyProfileCandidate].self, forKey: .profileCandidates) ?? []
        settings = try values.decodeIfPresent(DewySettings.self, forKey: .settings) ?? DewySettings()
        tasks = try values.decodeIfPresent([DewyTask].self, forKey: .tasks) ?? []
        water = try values.decodeIfPresent([WaterLog].self, forKey: .water) ?? []
        meals = try values.decodeIfPresent([MealLog].self, forKey: .meals) ?? []
        sleep = try values.decodeIfPresent([SleepLog].self, forKey: .sleep) ?? []
        work = try values.decodeIfPresent([WorkLog].self, forKey: .work) ?? []
        focus = try values.decodeIfPresent([FocusLog].self, forKey: .focus) ?? []
        goals = try values.decodeIfPresent([DewyGoal].self, forKey: .goals) ?? []
        habits = try values.decodeIfPresent([DewyHabit].self, forKey: .habits) ?? []
        habitCheckIns = try values.decodeIfPresent([HabitCheckIn].self, forKey: .habitCheckIns) ?? []
        weeklyReviews = try values.decodeIfPresent([WeeklyReview].self, forKey: .weeklyReviews) ?? []
        chatHistory = try values.decodeIfPresent([ChatLine].self, forKey: .chatHistory) ?? []
    }
}

struct ChatLine: Codable, Identifiable {
    enum Role: String, Codable { case assistant, user }
    var id: UUID
    var role: Role
    var text: String
    var date: Date

    init(id: UUID = UUID(), role: Role, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}
