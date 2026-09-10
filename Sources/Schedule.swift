import Foundation

// Чистая логика расписания без AppKit: модель, хранение и вычисление окон.
// Отделена от интерфейса намеренно — здесь живут все краевые случаи (окно
// через полночь, переход на летнее время, поиск ближайшей границы), и их
// нужно уметь проверять отдельно от строки меню.

// MARK: - Расписание работы stkh-client: модель

// Дни недели храним в нумерации Calendar: 1 — воскресенье, 2 — понедельник,
// …, 7 — суббота. Та же нумерация возвращается из component(.weekday:), так что
// проверка «сегодня рабочий день?» обходится без пересчёта.
struct DaemonSchedule: Codable, Equatable {
    var enabled: Bool
    var startMinutes: Int
    var stopMinutes: Int
    var weekdays: Set<Int>
    var breakEnabled: Bool
    var breakStartMinutes: Int
    var breakStopMinutes: Int

    init(enabled: Bool = false,
         startMinutes: Int = 9 * 60,
         stopMinutes: Int = 18 * 60,
         weekdays: Set<Int> = [2, 3, 4, 5, 6],
         breakEnabled: Bool = false,
         breakStartMinutes: Int = 13 * 60,
         breakStopMinutes: Int = 14 * 60) {
        self.enabled = enabled
        self.startMinutes = DaemonSchedule.clamp(startMinutes)
        self.stopMinutes = DaemonSchedule.clamp(stopMinutes)
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.breakEnabled = breakEnabled
        self.breakStartMinutes = DaemonSchedule.clamp(breakStartMinutes)
        self.breakStopMinutes = DaemonSchedule.clamp(breakStopMinutes)
    }

    private static func clamp(_ minutes: Int) -> Int {
        min(max(minutes, 0), 24 * 60 - 1)
    }

    // Расписание имеет смысл только когда выбран хотя бы один день: пустой
    // список дней — это то же самое, что выключенное расписание, и трактовать
    // его иначе значило бы молча ничего не делать при включённой галочке.
    var isActive: Bool { enabled && !weekdays.isEmpty }

    // Окно, заданное «с 22:00 до 06:00», переходит через полночь. Считаем его
    // принадлежащим тому дню, в котором оно началось.
    var crossesMidnight: Bool { stopMinutes <= startMinutes }

    // Длительность перерыва в минутах. Одинаковые «от» и «до» — это не сутки
    // перерыва, а «перерыв не задан»: иначе случайно совпавшие поля бесшумно
    // отключали бы демона целиком.
    var breakLengthMinutes: Int {
        let raw = breakStopMinutes - breakStartMinutes
        return raw > 0 ? raw : raw + 24 * 60
    }

    var hasBreak: Bool { breakEnabled && breakStopMinutes != breakStartMinutes }

    var workLengthMinutes: Int {
        let raw = stopMinutes - startMinutes
        return raw > 0 ? raw : raw + 24 * 60
    }

    // Попадает ли перерыв в рабочее окно — в минутах от его начала, без
    // привязки к календарю. Нужно для подсказки в настройках: перерыв,
    // заданный на нерабочее время, в полях выглядит совершенно обычно.
    var breakInsideWorkWindow: Bool {
        guard hasBreak else { return false }
        let day = 24 * 60
        let offset = ((breakStartMinutes - startMinutes) % day + day) % day
        return offset < workLengthMinutes
    }

    enum CodingKeys: String, CodingKey {
        case enabled, startMinutes, stopMinutes, weekdays
        case breakEnabled, breakStartMinutes, breakStopMinutes
    }

    // Свой декодер по той же причине, что и у VPNConfig: частичный или старый
    // файл должен читаться, подставляя умолчания вместо падения. Благодаря
    // этому настройки, сохранённые до появления перерыва, читаются как есть.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DaemonSchedule()
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled,
            startMinutes: try c.decodeIfPresent(Int.self, forKey: .startMinutes) ?? defaults.startMinutes,
            stopMinutes: try c.decodeIfPresent(Int.self, forKey: .stopMinutes) ?? defaults.stopMinutes,
            weekdays: try c.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? defaults.weekdays,
            breakEnabled: try c.decodeIfPresent(Bool.self, forKey: .breakEnabled) ?? defaults.breakEnabled,
            breakStartMinutes: try c.decodeIfPresent(Int.self, forKey: .breakStartMinutes)
                ?? defaults.breakStartMinutes,
            breakStopMinutes: try c.decodeIfPresent(Int.self, forKey: .breakStopMinutes)
                ?? defaults.breakStopMinutes
        )
    }
}

enum DaemonScheduleStore {
    static let defaultsKey = "daemonSchedule"

    static func load() -> DaemonSchedule {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let schedule = try? JSONDecoder().decode(DaemonSchedule.self, from: data) else {
            return DaemonSchedule()
        }
        return schedule
    }

    static func save(_ schedule: DaemonSchedule) {
        guard let data = try? JSONEncoder().encode(schedule) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

// MARK: - Расписание работы stkh-client: дни и время

// Порядок для показа и для сжатия в диапазоны — с понедельника, а не с
// воскресенья, как в нумерации Calendar.
let weekdayDisplayOrder = [2, 3, 4, 5, 6, 7, 1]
let weekdayShortNames: [Int: String] = [
    2: "пн", 3: "вт", 4: "ср", 5: "чт", 6: "пт", 7: "сб", 1: "вс"
]

func formatTimeOfDay(minutes: Int) -> String {
    String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
}

func minutesOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
}

// «пн–пт», «пн–чт, сб», «ежедневно» — подряд идущие дни сжимаем в диапазон,
// иначе строка в меню превращается в нечитаемый список из семи сокращений.
func formatWeekdays(_ days: Set<Int>) -> String {
    let indices = weekdayDisplayOrder.indices.filter { days.contains(weekdayDisplayOrder[$0]) }
    guard let first = indices.first else { return "ни одного дня" }
    if indices.count == 7 { return "ежедневно" }

    var parts: [String] = []
    var runStart = first
    var previous = first
    func name(_ index: Int) -> String { weekdayShortNames[weekdayDisplayOrder[index]] ?? "" }
    func flushRun() {
        switch previous - runStart {
        case 0: parts.append(name(runStart))
        // Два дня подряд диапазоном не пишем: «пн–вт» длиннее и хуже читается,
        // чем «пн, вт».
        case 1: parts.append(name(runStart)); parts.append(name(previous))
        default: parts.append("\(name(runStart))–\(name(previous))")
        }
    }
    for index in indices.dropFirst() {
        if index == previous + 1 {
            previous = index
            continue
        }
        flushRun()
        runStart = index
        previous = index
    }
    flushRun()
    return parts.joined(separator: ", ")
}

func describeSchedule(_ schedule: DaemonSchedule) -> String {
    "\(formatWeekdays(schedule.weekdays)), "
        + "\(formatTimeOfDay(minutes: schedule.startMinutes))–"
        + "\(formatTimeOfDay(minutes: schedule.stopMinutes))"
}

extension String {
    // Описания собираются в нижнем регистре, чтобы подставляться в середину
    // фразы; в начале строки меню им нужна заглавная буква.
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}

func describeBreak(_ schedule: DaemonSchedule) -> String {
    guard schedule.hasBreak else { return "без перерыва" }
    return "перерыв \(formatTimeOfDay(minutes: schedule.breakStartMinutes))–"
        + "\(formatTimeOfDay(minutes: schedule.breakStopMinutes))"
}

// MARK: - Расписание работы stkh-client: вычисление окон

struct ScheduleWindow {
    let start: Date
    let end: Date

    // Полуинтервал: в момент остановки демон уже считается выключенным, иначе
    // на самой границе расписание одновременно хочет и запустить, и остановить.
    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

// Окно для конкретного дня, если этот день выбран в расписании. Время
// собираем через bySettingHour, а не прибавлением секунд: при переходе на
// зимнее/летнее время «09:00» должно оставаться девятью часами по часам
// пользователя.
func scheduleWindow(dayStart: Date, schedule: DaemonSchedule, calendar: Calendar) -> ScheduleWindow? {
    let weekday = calendar.component(.weekday, from: dayStart)
    guard schedule.weekdays.contains(weekday) else { return nil }
    guard let start = calendar.date(bySettingHour: schedule.startMinutes / 60,
                                    minute: schedule.startMinutes % 60,
                                    second: 0,
                                    of: dayStart) else { return nil }
    let stopDayStart = schedule.crossesMidnight
        ? calendar.date(byAdding: .day, value: 1, to: dayStart)
        : dayStart
    guard let stopDayStart = stopDayStart,
          let end = calendar.date(bySettingHour: schedule.stopMinutes / 60,
                                  minute: schedule.stopMinutes % 60,
                                  second: 0,
                                  of: stopDayStart),
          end > start else { return nil }
    return ScheduleWindow(start: start, end: end)
}

// Перерыв задан временем суток, но привязать его нужно к рабочему окну, а не к
// календарному дню: при ночной смене (пт 22:00 → сб 06:00) перерыв «02:00–03:00»
// приходится на субботу, хотя окно принадлежит пятнице. Поэтому берём первое
// вхождение времени начала перерыва не раньше начала окна.
func breakWindow(in window: ScheduleWindow,
                 schedule: DaemonSchedule,
                 calendar: Calendar) -> ScheduleWindow? {
    guard schedule.hasBreak else { return nil }
    let dayStart = calendar.startOfDay(for: window.start)
    guard var start = calendar.date(bySettingHour: schedule.breakStartMinutes / 60,
                                    minute: schedule.breakStartMinutes % 60,
                                    second: 0,
                                    of: dayStart) else { return nil }
    if start < window.start {
        guard let shifted = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        start = shifted
    }
    // Перерыв целиком вне рабочего окна просто игнорируем: это не ошибка, а
    // безобидная настройка (например, обед, заданный на нерабочее время).
    guard start < window.end,
          let rawEnd = calendar.date(byAdding: .minute, value: schedule.breakLengthMinutes, to: start) else {
        return nil
    }
    return ScheduleWindow(start: start, end: min(rawEnd, window.end))
}

// Проверяем не только сегодняшнее окно, но и вчерашнее: ночное окно
// (22:00–06:00) в два часа ночи принадлежит вчерашнему дню недели.
func scheduleDesiredRunning(_ schedule: DaemonSchedule,
                            at date: Date,
                            calendar: Calendar = .current) -> Bool {
    guard schedule.isActive else { return false }
    let today = calendar.startOfDay(for: date)
    for offset in [0, -1] {
        guard let dayStart = calendar.date(byAdding: .day, value: offset, to: today),
              let window = scheduleWindow(dayStart: dayStart, schedule: schedule, calendar: calendar),
              window.contains(date) else {
            continue
        }
        // Внутри рабочего окна перерыв перекрывает его: демон на это время
        // останавливается и потом поднимается снова.
        if let pause = breakWindow(in: window, schedule: schedule, calendar: calendar),
           pause.contains(date) {
            return false
        }
        return true
    }
    return false
}

struct ScheduleTransition {
    let date: Date
    let starts: Bool
}

// Ближайшая граница окна после `date` — нужна только для подписи в меню.
// Восьми дней хватает с запасом: при любом непустом наборе дней следующая
// граница наступает не позже чем через неделю.
func nextScheduleTransition(_ schedule: DaemonSchedule,
                            after date: Date,
                            calendar: Calendar = .current) -> ScheduleTransition? {
    guard schedule.isActive else { return nil }
    let today = calendar.startOfDay(for: date)
    var best: ScheduleTransition?
    for offset in -1...8 {
        guard let dayStart = calendar.date(byAdding: .day, value: offset, to: today),
              let window = scheduleWindow(dayStart: dayStart, schedule: schedule, calendar: calendar) else {
            continue
        }
        var candidates = [ScheduleTransition(date: window.start, starts: true),
                          ScheduleTransition(date: window.end, starts: false)]
        if let pause = breakWindow(in: window, schedule: schedule, calendar: calendar) {
            candidates.append(ScheduleTransition(date: pause.start, starts: false))
            // Если перерыв упирается в конец рабочего окна, запуска после него
            // не будет — граница там ровно одна, и она уже в списке.
            if pause.end < window.end {
                candidates.append(ScheduleTransition(date: pause.end, starts: true))
            }
        }
        for candidate in candidates {
            guard candidate.date > date else { continue }
            if best == nil || candidate.date < best!.date { best = candidate }
        }
    }
    return best
}
