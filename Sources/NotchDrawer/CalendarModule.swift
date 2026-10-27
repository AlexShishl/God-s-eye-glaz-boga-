import AppKit
import EventKit
import SwiftUI

struct DayGroup: Identifiable {
    let day: Date
    let events: [EKEvent]
    var id: Date { day }
}

/// Встречи и задачи из системного Календаря и Напоминаний.
/// Google Календарь появляется тут сам, если добавить Google-аккаунт в настройках macOS.
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()

    let store = EKEventStore()
    @Published var eventsStatus = EKEventStore.authorizationStatus(for: .event)
    @Published var remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
    @Published var today: [EKEvent] = []
    @Published var week: [DayGroup] = []
    @Published var tasks: [EKReminder] = []
    @Published var calendars: [EKCalendar] = []
    @Published var error: String?
    /// Откуда берутся встречи: «iCloud, Google» — видно, подключился ли Google.
    @Published var sourcesSummary = ""

    var hasEvents: Bool { eventsStatus == .fullAccess }
    var hasReminders: Bool { remindersStatus == .fullAccess }
    var needsRequest: Bool { eventsStatus == .notDetermined || remindersStatus == .notDetermined }

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    func requestAccess() {
        Task { @MainActor in
            _ = try? await store.requestFullAccessToEvents()
            _ = try? await store.requestFullAccessToReminders()
            store.reset()
            reload()
        }
    }

    func reload() {
        let wasAllowed = hasEvents
        eventsStatus = EKEventStore.authorizationStatus(for: .event)
        remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
        // Доступ дали, пока приложение работало: без reset хранилище не видит календари.
        if hasEvents && !wasAllowed { store.reset() }
        store.refreshSourcesIfNecessary()
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let endToday = cal.date(byAdding: .day, value: 1, to: start)!
        let endWeek = cal.date(byAdding: .day, value: 8, to: start)!

        if hasEvents {
            let all = store.calendars(for: .event)
            calendars = all.filter(\.allowsContentModifications)
            let names = Dictionary(grouping: all) { $0.source?.title ?? "?" }
                .map { "\($0.key) (\($0.value.count))" }
                .sorted()
            sourcesSummary = names.isEmpty ? "Календарей не видно" : "Календари: " + names.joined(separator: ", ")
            let predicate = store.predicateForEvents(withStart: start, end: endWeek, calendars: nil)
            let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            today = events.filter { $0.startDate < endToday }
            let later = events.filter { $0.startDate >= endToday }
            week = Dictionary(grouping: later) { cal.startOfDay(for: $0.startDate) }
                .map { DayGroup(day: $0.key, events: $0.value) }
                .sorted { $0.day < $1.day }
        }

        if hasReminders {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { [weak self] reminders in
                let sorted = (reminders ?? []).sorted { Self.due($0) < Self.due($1) }
                DispatchQueue.main.async { self?.tasks = Array(sorted.prefix(40)) }
            }
        }
    }

    static func due(_ r: EKReminder) -> Date {
        guard let c = r.dueDateComponents else { return .distantFuture }
        return Calendar.current.date(from: c) ?? .distantFuture
    }

    func addTask(_ title: String) {
        guard hasReminders, let list = store.defaultCalendarForNewReminders() else {
            error = "Нет доступа к Напоминаниям"
            return
        }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = list
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        save { try store.save(r, commit: true) }
    }

    func addEvent(_ title: String, at date: Date, calendarID: String) {
        guard hasEvents, let target = store.calendar(withIdentifier: calendarID) ?? store.defaultCalendarForNewEvents else {
            error = "Нет доступа к Календарю"
            return
        }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = date
        e.endDate = date.addingTimeInterval(3600)
        e.calendar = target
        save { try store.save(e, span: .thisEvent, commit: true) }
    }

    func complete(_ r: EKReminder) {
        r.isCompleted = true
        save { try store.save(r, commit: true) }
    }

    private func save(_ block: () throws -> Void) {
        do {
            try block()
            error = nil
        } catch {
            self.error = "Не получилось сохранить: \(error.localizedDescription)"
        }
        reload()
    }
}

struct CalendarView: View {
    @ObservedObject private var cal = CalendarStore.shared

    var body: some View {
        Group {
            if cal.needsRequest {
                AccessCard(text: "Разреши Глазу Бога смотреть твой Календарь и Напоминания, чтобы видеть встречи и задачи.",
                           button: "Разрешить доступ") { cal.requestAccess() }
            } else if !cal.hasEvents && !cal.hasReminders {
                AccessCard(text: "Доступ к Календарю выключен. Включи его в Настройках → Конфиденциальность → Календари.",
                           button: "Открыть настройки") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    TodayColumn()
                        .frame(maxWidth: .infinity)
                    WeekColumn()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { cal.reload() }
    }
}

private struct AccessCard: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 26)).foregroundStyle(.secondary)
            Text(text).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 400)
            Button(button, action: action).buttonStyle(PillButton())
            GoogleHint()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GoogleHint: View {
    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
        } label: {
            Label("Подключить Google Календарь", systemImage: "link")
        }
        .buttonStyle(PillButton())
        .help("Настройки → Интернет-аккаунты → Google → включи «Календари»")
    }
}

/// Слева: планы на сегодня (встречи + задачи) и быстрое добавление.
private struct TodayColumn: View {
    @ObservedObject private var cal = CalendarStore.shared
    @AppStorage("eventCalendarID") private var calendarID = ""
    @State private var newTitle = ""
    @State private var isMeeting = false
    @State private var when = Calendar.current.date(bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600)) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Сегодня").font(.system(size: 14, weight: .bold))
                    Text(RuDate.day.string(from: Date()).capitalized).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                GoogleHint()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(cal.today.enumerated()), id: \.offset) { _, e in EventRow(event: e) }
                    ForEach(cal.tasks, id: \.calendarItemIdentifier) { r in TaskRow(reminder: r) }
                    if cal.today.isEmpty && cal.tasks.isEmpty {
                        Text("На сегодня пусто — можно отдыхать ✨").font(.callout).foregroundStyle(.secondary).padding(.top, 20)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            if let err = cal.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Picker("", selection: $isMeeting) {
                        Text("Задача").tag(false)
                        Text("Встреча").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 130)
                    if isMeeting {
                        DatePicker("", selection: $when)
                            .datePickerStyle(.field)
                            .labelsHidden()
                    }
                    Spacer(minLength: 0)
                }
                if isMeeting && !cal.calendars.isEmpty {
                    Picker("Календарь", selection: $calendarID) {
                        ForEach(cal.calendars, id: \.calendarIdentifier) { c in
                            Text(c.title).tag(c.calendarIdentifier)
                        }
                    }
                    .font(.caption)
                }
                HStack(spacing: 6) {
                    TextField(isMeeting ? "Название встречи" : "Новая задача…", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit(add)
                    Button(action: add) { Image(systemName: "plus") }
                        .buttonStyle(PillButton())
                        .disabled(newTitle.trimmed.isEmpty)
                }
            }
        }
        .onAppear {
            if calendarID.isEmpty || !cal.calendars.contains(where: { $0.calendarIdentifier == calendarID }) {
                calendarID = cal.store.defaultCalendarForNewEvents?.calendarIdentifier ?? cal.calendars.first?.calendarIdentifier ?? ""
            }
        }
    }

    private func add() {
        let title = newTitle.trimmed
        guard !title.isEmpty else { return }
        if isMeeting {
            cal.addEvent(title, at: when, calendarID: calendarID)
        } else {
            cal.addTask(title)
        }
        newTitle = ""
    }
}

/// Справа: встречи на ближайшую неделю по дням.
private struct WeekColumn: View {
    @ObservedObject private var cal = CalendarStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("На неделе").font(.system(size: 14, weight: .bold))
            if cal.week.isEmpty {
                EmptyState(icon: "calendar", text: "Встреч на неделе нет")
                Text(cal.sourcesSummary).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(cal.week) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(RuDate.shortDay.string(from: group.day).capitalized)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(Array(group.events.enumerated()), id: \.offset) { _, e in EventRow(event: e) }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

private struct EventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: event.calendar?.color ?? .systemBlue))
                .frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Без названия").font(.caption.weight(.medium)).lineLimit(1)
                Text(timeText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }
    }

    private var timeText: String {
        if event.isAllDay { return "весь день" }
        return "\(RuDate.time.string(from: event.startDate)) – \(RuDate.time.string(from: event.endDate))"
    }
}

private struct TaskRow: View {
    let reminder: EKReminder
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button { withAnimation { CalendarStore.shared.complete(reminder) } } label: {
                Image(systemName: hover ? "checkmark.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: reminder.calendar?.color ?? .systemOrange))
            }
            .buttonStyle(.plain)
            .help("Готово")
            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title ?? "").font(.caption).lineLimit(1)
                if let due = reminder.dueDateComponents, let d = Calendar.current.date(from: due) {
                    Text(dueText(d, hasTime: due.hour != nil)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .onHover { hover = $0 }
    }

    private func dueText(_ d: Date, hasTime: Bool) -> String {
        let day = Calendar.current.isDateInToday(d) ? "сегодня" : RuDate.shortDay.string(from: d)
        return hasTime ? "\(day), \(RuDate.time.string(from: d))" : day
    }
}
