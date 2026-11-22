import EventKit
import SwiftUI

@MainActor
final class DewyCalendarStore: ObservableObject {
    static let shared = DewyCalendarStore()

    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var accessMessage: String?
    private let eventStore = EKEventStore()
    private var visibleRange: (start: Date, end: Date)?

    func load(from start: Date, to end: Date) {
        visibleRange = (start, end)
        Task { await refreshVisibleRange() }
    }

    func requestAccessIfNeeded() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .authorized { return true }
        if #available(macOS 14.0, *), status == .fullAccess { return true }
        guard status == .notDetermined else {
            accessMessage = "请在系统设置中允许 Dewy 访问日历。"
            return false
        }
        let granted = await withCheckedContinuation { continuation in
            let completion: (Bool, Error?) -> Void = { allowed, _ in continuation.resume(returning: allowed) }
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToEvents(completion: completion)
            } else {
                eventStore.requestAccess(to: .event, completion: completion)
            }
        }
        accessMessage = granted ? nil : "请在系统设置中允许 Dewy 访问日历。"
        return granted
    }

    func listEvents(from start: Date, to end: Date) async -> [EKEvent]? {
        guard end > start, await requestAccessIfNeeded() else { return nil }
        return fetch(from: start, to: end)
    }

    func createEvent(title: String, start: Date, end: Date) async -> String {
        guard await requestAccessIfNeeded() else { return "没有日历访问权限；请在系统设置中允许 Dewy 访问日历。" }
        guard end > start else { return "结束时间必须晚于开始时间。" }
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        guard let calendar = eventStore.defaultCalendarForNewEvents else { return "系统中没有可写入的默认日历。" }
        event.calendar = calendar
        do {
            try eventStore.save(event, span: .thisEvent)
            await refreshVisibleRange()
            return "日历事件已创建：\(event.title ?? title)，\(Self.timeText(start))–\(Self.timeText(end))。"
        } catch { return "日历事件创建失败：\(error.localizedDescription)" }
    }

    func updateEvent(title: String, on date: Date, newTitle: String?, newStart: Date?, newEnd: Date?) async -> String {
        guard await requestAccessIfNeeded() else { return "没有日历访问权限；请在系统设置中允许 Dewy 访问日历。" }
        guard let interval = Calendar.current.dateInterval(of: .day, for: date) else { return "日期无效。" }
        let matches = fetch(from: interval.start, to: interval.end).filter { ($0.title ?? "").localizedCaseInsensitiveCompare(title) == .orderedSame }
        guard matches.count == 1, let event = matches.first else {
            return matches.isEmpty ? "没有找到 \(date.formatted(date: .abbreviated, time: .omitted)) 的「\(title)」日历事件。" : "当天有多条同名事件，请提供更明确的标题。"
        }
        guard newTitle != nil || newStart != nil || newEnd != nil else { return "请提供要修改的新标题、开始时间或结束时间。" }
        let currentStart = event.startDate ?? date
        let currentEnd = event.endDate ?? currentStart.addingTimeInterval(3600)
        let start = newStart ?? currentStart
        let end = newEnd ?? currentEnd
        guard end > start else { return "结束时间必须晚于开始时间。" }
        if let newTitle { event.title = newTitle }
        event.startDate = start
        event.endDate = end
        do {
            try eventStore.save(event, span: .thisEvent)
            await refreshVisibleRange()
            return "日历事件已更新：\(event.title ?? title)，\(Self.timeText(start))–\(Self.timeText(end))。"
        } catch { return "日历事件更新失败：\(error.localizedDescription)" }
    }

    func deleteEvent(title: String, on date: Date) async -> String {
        guard await requestAccessIfNeeded() else { return "没有日历访问权限；请在系统设置中允许 Dewy 访问日历。" }
        guard let interval = Calendar.current.dateInterval(of: .day, for: date) else { return "日期无效。" }
        let matches = fetch(from: interval.start, to: interval.end).filter { ($0.title ?? "").localizedCaseInsensitiveCompare(title) == .orderedSame }
        guard matches.count == 1, let event = matches.first else {
            return matches.isEmpty ? "没有找到 \(date.formatted(date: .abbreviated, time: .omitted)) 的「\(title)」日历事件。" : "当天有多条同名事件，请提供更明确的标题。"
        }
        do {
            try eventStore.remove(event, span: .thisEvent)
            await refreshVisibleRange()
            return "日历事件已删除：\(title)。"
        } catch { return "日历事件删除失败：\(error.localizedDescription)" }
    }

    @discardableResult
    private func fetch(from start: Date, to end: Date) -> [EKEvent] {
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let result = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if visibleRange?.start == start && visibleRange?.end == end { events = result }
        return result
    }

    private func refreshVisibleRange() async {
        guard await requestAccessIfNeeded(), let visibleRange else { return }
        _ = fetch(from: visibleRange.start, to: visibleRange.end)
    }

    func save(title: String, start: Date, end: Date, identifier: String? = nil) {
        let event = identifier.flatMap { eventStore.calendarItem(withIdentifier: $0) as? EKEvent } ?? EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = max(end, start.addingTimeInterval(15 * 60))
        event.calendar = event.calendar ?? eventStore.defaultCalendarForNewEvents
        do {
            try eventStore.save(event, span: .thisEvent)
            load(from: startOfMonth(start), to: endOfMonth(start))
        }
        catch { accessMessage = "日历保存失败：\(error.localizedDescription)" }
    }

    func delete(_ event: EKEvent) {
        do {
            try eventStore.remove(event, span: .thisEvent)
            load(from: startOfMonth(event.startDate), to: endOfMonth(event.startDate))
        }
        catch { accessMessage = "日历删除失败：\(error.localizedDescription)" }
    }

    private static func timeText(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    private func startOfMonth(_ date: Date) -> Date { Calendar.current.dateInterval(of: .month, for: date)?.start ?? date }
    private func endOfMonth(_ date: Date) -> Date { Calendar.current.dateInterval(of: .month, for: date)?.end ?? date.addingTimeInterval(31 * 86400) }
}

struct PlanningView: View {
    @EnvironmentObject private var store: DewyStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var calendarStore = DewyCalendarStore.shared
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("日历与习惯").font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11)) }.buttonStyle(.plain)
            }.padding(.horizontal, 15).frame(height: 48)
            HStack(spacing: 0) {
                tab("日历", index: 0)
                tab("习惯", index: 1)
            }.padding(.horizontal, 14).padding(.bottom, 8)
            if page == 0 { calendarPage } else { HabitPage() }
        }
        .frame(width: 420, height: 500)
        .background(.ultraThinMaterial)
    }

    private func tab(_ title: String, index: Int) -> some View {
        Button { page = index } label: {
            Text(title).font(.system(size: 11, weight: page == index ? .semibold : .regular))
                .foregroundStyle(page == index ? ink : muted)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(page == index ? Color.white.opacity(0.78) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private var calendarPage: some View { SystemCalendarPage(store: calendarStore) }
}

private struct SystemCalendarPage: View {
    @ObservedObject var store: DewyCalendarStore
    @State private var month = Calendar.current.startOfMonth(for: Date())
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var showingEditor = false
    @State private var editingEvent: EKEvent?

    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private var calendar: Calendar { Calendar.current }
    private var monthDays: Int { calendar.range(of: .day, in: .month, for: month)?.count ?? 30 }
    private var firstOffset: Int { ((calendar.component(.weekday, from: month) + 5) % 7) }
    private var selectedEvents: [EKEvent] { store.events.filter { calendar.isDate($0.startDate, inSameDayAs: selectedDate) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("‹") { shiftMonth(-1) }.buttonStyle(.plain)
                Text(month.formatted(.dateTime.year().month())).font(.system(size: 13, weight: .semibold))
                Button("›") { shiftMonth(1) }.buttonStyle(.plain)
                Spacer()
                Button { editingEvent = nil; showingEditor = true } label: { Label("添加事件", systemImage: "plus").font(.system(size: 10)) }.buttonStyle(.plain)
            }.foregroundStyle(ink)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(weekdays, id: \.self) { Text($0).font(.system(size: 9)).foregroundStyle(muted).frame(maxWidth: .infinity) }
                ForEach(0..<(firstOffset + monthDays), id: \.self) { index in
                    if index < firstOffset { Color.clear.frame(height: 28) }
                    else {
                        let day = index - firstOffset + 1
                        let date = calendar.date(byAdding: .day, value: day - 1, to: month) ?? month
                        Button { selectedDate = date } label: {
                            VStack(spacing: 2) {
                                Text("\(day)").font(.system(size: 10, weight: calendar.isDate(date, inSameDayAs: selectedDate) ? .semibold : .regular))
                                Circle().fill(store.events.contains(where: { calendar.isDate($0.startDate, inSameDayAs: date) }) ? Color(red: 0.48, green: 0.68, blue: 0.80) : .clear).frame(width: 3, height: 3)
                            }.frame(maxWidth: .infinity).frame(height: 28)
                                .background(calendar.isDate(date, inSameDayAs: selectedDate) ? Color(red: 0.88, green: 0.94, blue: 0.97) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).foregroundStyle(ink)
                    }
                }
            }
            Divider().overlay(Color.white.opacity(0.8))
            HStack {
                Text(selectedDate.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                if let message = store.accessMessage { Text(message).font(.system(size: 9)).foregroundStyle(muted).lineLimit(2) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if selectedEvents.isEmpty { Text(store.accessMessage == nil ? "这一天还没有安排" : "日历尚未连接或没有访问权限").font(.system(size: 10)).foregroundStyle(muted).padding(.vertical, 8) }
                    ForEach(selectedEvents, id: \.eventIdentifier) { event in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.53, green: 0.70, blue: 0.81)).frame(width: 3, height: 25)
                            Text(event.startDate.formatted(date: .omitted, time: .shortened)).font(.system(size: 9)).foregroundStyle(muted)
                            Text(event.title ?? "无标题事件").font(.system(size: 10)).foregroundStyle(ink).lineLimit(1)
                            Spacer()
                            Button { editingEvent = event; showingEditor = true } label: { Image(systemName: "pencil").font(.system(size: 9)) }.buttonStyle(.plain)
                            Button { store.delete(event) } label: { Image(systemName: "trash").font(.system(size: 9)) }.buttonStyle(.plain)
                        }.padding(6).background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15).padding(.bottom, 12)
        .onAppear(perform: reload)
        .onChange(of: month) { _ in reload() }
        .sheet(isPresented: $showingEditor) {
            EventEditor(event: editingEvent, defaultDate: selectedDate) { title, start, end in
                store.save(title: title, start: start, end: end, identifier: editingEvent?.eventIdentifier)
                reload()
            }.frame(width: 320, height: 220).padding(16)
        }
    }

    private func reload() {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return }
        store.load(from: interval.start, to: interval.end)
    }
    private func shiftMonth(_ amount: Int) {
        month = calendar.date(byAdding: .month, value: amount, to: month) ?? month
        selectedDate = month
    }
}

private struct EventEditor: View {
    @Environment(\.dismiss) private var dismiss
    let event: EKEvent?
    let defaultDate: Date
    let onSave: (String, Date, Date) -> Void
    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(event == nil ? "新建日历事件" : "编辑日历事件").font(.system(size: 14, weight: .semibold))
            TextField("事件名称", text: $title).textFieldStyle(.roundedBorder)
            DatePicker("开始", selection: $start)
            DatePicker("结束", selection: $end)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") { onSave(title, start, end); dismiss() }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.onAppear {
            if let event { title = event.title ?? ""; start = event.startDate; end = event.endDate }
            else { start = defaultDate; end = defaultDate.addingTimeInterval(3600) }
        }
    }
}

private struct HabitPage: View {
    @EnvironmentObject private var store: DewyStore
    @State private var overview = false
    @State private var habitSheet: HabitSheet?
    private var calendar: Calendar { Calendar.current }
    private var monthDays: Int { 31 }
    private var actualMonthDays: Int { calendar.range(of: .day, in: .month, for: Date())?.count ?? 30 }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(overview ? "本月习惯" : "今日习惯").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                Picker("", selection: $overview) { Text("今日").tag(false); Text("月总览").tag(true) }.pickerStyle(.segmented).frame(width: 112)
                Spacer()
                Button { habitSheet = .add } label: { Label("添加", systemImage: "plus").font(.system(size: 10)) }.buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                metric("近30天", "\(store.habitCompletionRateLast30Days)%")
                metric("历史最高连续", "\(store.highestHabitStreak) 天")
                Spacer()
            }.padding(9).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            Group {
                if overview { monthlyGrid }
                else { todayList }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $habitSheet) { sheet in
            switch sheet {
            case .add:
                HabitEditor { title, weekdays, hour, minute in
                    store.addHabit(title, weekdays: weekdays, reminderHour: hour, reminderMinute: minute)
                }
                .frame(width: 330, height: 300).padding(16)
            case .reminder(let habit):
                HabitReminderEditor(habit: habit) { hour, minute in
                    _ = store.setHabitReminder(id: habit.id, hour: hour, minute: minute)
                }
                .frame(width: 330, height: 190).padding(16)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 8)).foregroundStyle(muted)
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
        }
    }

    private var todayList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(store.data.habits) { habit in
                    HStack(spacing: 8) {
                        Button { store.setHabitCheckIn(habit.id, on: Date()) } label: {
                            Image(systemName: store.isHabitCheckedIn(habit.id, on: Date()) ? "checkmark" : "plus")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                                .frame(width: 25, height: 25).background(Color(red: 0.90, green: 0.95, blue: 0.98), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(!isScheduled(habit, on: Date()))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(habit.title).font(.system(size: 11, weight: .medium)).foregroundStyle(ink)
                            Text("历史最高连续 \(store.historicalStreak(for: habit)) 个计划日\(reminderLabel(for: habit))").font(.system(size: 9)).foregroundStyle(muted)
                        }
                        Spacer()
                        if store.isHabitCheckedIn(habit.id, on: Date()) { Text("已完成").font(.system(size: 9)).foregroundStyle(Color(red: 0.42, green: 0.64, blue: 0.55)) }
                        else if isScheduled(habit, on: Date()) { Button("打卡") { store.setHabitCheckIn(habit.id, on: Date()) }.font(.system(size: 9)).buttonStyle(.bordered).tint(Color(red: 0.58, green: 0.76, blue: 0.87)) }
                        else { Text("今日未安排").font(.system(size: 9)).foregroundStyle(muted) }
                    }.padding(7).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                        .contextMenu {
                            Button("设置提醒") { habitSheet = .reminder(habit) }
                            Button("删除习惯", role: .destructive) { store.deleteHabit(habit.id) }
                        }
                }
                if store.data.habits.isEmpty { Text("添加一个习惯，开始记录你的节奏。").font(.system(size: 10)).foregroundStyle(muted).padding(.top, 24) }
            }
        }
    }

    private var monthlyGrid: some View {
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("习惯").frame(width: 98, alignment: .leading).padding(.leading, 6)
                        ForEach(1...monthDays, id: \.self) { day in Text("\(day)").frame(width: 24) }
                    }.font(.system(size: 8, weight: .medium)).foregroundStyle(muted).frame(height: 23).background(Color.white.opacity(0.7))
                    ForEach(store.data.habits) { habit in
                        HStack(spacing: 0) {
                            Text(habit.title).lineLimit(1).frame(width: 98, alignment: .leading).padding(.leading, 6)
                            ForEach(1...monthDays, id: \.self) { day in
                                let date = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())).flatMap { calendar.date(byAdding: .day, value: day - 1, to: $0) } ?? Date()
                                let validDay = day <= actualMonthDays && date <= calendar.startOfDay(for: Date())
                                let scheduled = isScheduled(habit, on: date)
                                Button { store.setHabitCheckIn(habit.id, on: date) } label: {
                                    Text(store.isHabitCheckedIn(habit.id, on: date) ? "✓" : "")
                                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(Color(red: 0.34, green: 0.54, blue: 0.67))
                                        .frame(width: 22, height: 23).background(store.isHabitCheckedIn(habit.id, on: date) ? Color(red: 0.87, green: 0.94, blue: 0.97) : .clear)
                                        .overlay(Rectangle().stroke(Color.gray.opacity(0.12), lineWidth: 0.4))
                                }.buttonStyle(.plain).disabled(!validDay || !scheduled).opacity(day > actualMonthDays ? 0.35 : 1)
                            }
                        }.font(.system(size: 9)).foregroundStyle(ink).frame(height: 25)
                    }
                }
                .frame(minHeight: viewport.size.height, alignment: .topLeading)
            }
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        }
        .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
    }

    private func isScheduled(_ habit: DewyHabit, on date: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        let index = weekday == 1 ? 7 : weekday - 1
        let schedule = habit.schedule(on: calendar.startOfDay(for: date))
        return schedule.weekdays.contains(index) && !schedule.restDays.contains(index)
    }

    private func reminderLabel(for habit: DewyHabit) -> String {
        guard let hour = habit.reminderHour, let minute = habit.reminderMinute else { return " · 未设提醒" }
        return String(format: " · 提醒 %02d:%02d", hour, minute)
    }
}

private enum HabitSheet: Identifiable {
    case add
    case reminder(DewyHabit)
    var id: String {
        switch self {
        case .add: "add"
        case .reminder(let habit): "reminder-\(habit.id.uuidString)"
        }
    }
}

private struct HabitEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, Set<Int>, Int?, Int?) -> Void
    @State private var title = ""
    @State private var weekdays = Set(1...7)
    @State private var reminderEnabled = false
    @State private var reminderTime = Calendar.current.date(from: DateComponents(hour: 20, minute: 30)) ?? Date()
    private let labels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("添加习惯").font(.system(size: 14, weight: .semibold))
            TextField("例如：每天阅读 20 分钟", text: $title).textFieldStyle(.roundedBorder)
            Text("计划打卡日").font(.system(size: 10)).foregroundStyle(muted)
            HStack(spacing: 5) {
                ForEach(1...7, id: \.self) { day in
                    let selected = weekdays.contains(day)
                    Button(labels[day - 1]) {
                        if selected { weekdays.remove(day) } else { weekdays.insert(day) }
                    }.buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                        .frame(width: 30, height: 27)
                        .background(selected ? Color(red: 0.86, green: 0.93, blue: 0.97) : Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(selected ? ink : muted)
                }
            }
            Text("默认每天打卡；可以选择每周的计划日。").font(.system(size: 9)).foregroundStyle(muted)
            Toggle("设置习惯提醒", isOn: $reminderEnabled).font(.system(size: 10)).toggleStyle(.switch).controlSize(.mini)
            if reminderEnabled {
                DatePicker("提醒时间", selection: $reminderTime, displayedComponents: .hourAndMinute).font(.system(size: 10)).datePickerStyle(.compact)
            }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("添加") {
                let time = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
                onSave(title, weekdays, reminderEnabled ? time.hour : nil, reminderEnabled ? time.minute : nil)
                dismiss()
            }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || weekdays.isEmpty) }
        }
    }
}

private struct HabitReminderEditor: View {
    @Environment(\.dismiss) private var dismiss
    let habit: DewyHabit
    let onSave: (Int?, Int?) -> Void
    @State private var enabled: Bool
    @State private var time: Date

    init(habit: DewyHabit, onSave: @escaping (Int?, Int?) -> Void) {
        self.habit = habit
        self.onSave = onSave
        _enabled = State(initialValue: habit.reminderHour != nil && habit.reminderMinute != nil)
        let components = DateComponents(hour: habit.reminderHour ?? 20, minute: habit.reminderMinute ?? 30)
        _time = State(initialValue: Calendar.current.date(from: components) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("提醒：\(habit.title)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Toggle("在计划打卡日提醒我", isOn: $enabled).font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
            DatePicker("提醒时间", selection: $time, displayedComponents: .hourAndMinute).font(.system(size: 10)).datePickerStyle(.compact).disabled(!enabled)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") {
                let components = Calendar.current.dateComponents([.hour, .minute], from: time)
                onSave(enabled ? components.hour : nil, enabled ? components.minute : nil)
                dismiss()
            }.keyboardShortcut(.defaultAction) }
        }
    }
}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date { dateInterval(of: .month, for: date)?.start ?? startOfDay(for: date) }
}
