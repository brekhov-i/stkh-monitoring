import Cocoa

// Окно «Автоматизация»: переключатель, рабочее время по дням недели и
// перерыв. Вынесено из main.swift отдельно, чтобы раскладку можно было
// собрать и посмотреть без запуска всего приложения.

// MARK: - Окно «Автоматизация»

final class AutomationSettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var enabledSwitch: NSSwitch!
    private var startPicker: NSDatePicker!
    private var stopPicker: NSDatePicker!
    private var breakCheckbox: NSButton!
    private var breakStartPicker: NSDatePicker!
    private var breakStopPicker: NSDatePicker!
    private var dayCheckboxes: [Int: NSButton] = [:]
    private var presetButtons: [NSButton] = []
    private var summaryLabel: NSTextField!

    var onSave: ((DaemonSchedule) -> Void)?

    func show(schedule: DaemonSchedule) {
        if window == nil { buildWindow() }
        populate(schedule: schedule)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Сборка окна

    private func makeFieldLabel(_ text: String, x: CGFloat, width: CGFloat, y: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: x, y: y, width: width, height: 20)
        field.alignment = .right
        return field
    }

    // Ширину задаём явно: рамка метки перехватывает клики на всей своей площади,
    // и растянутый на пол-окна заголовок откусывал бы их у соседнего чекбокса.
    private func makeSectionLabel(_ text: String, y: CGFloat, width: CGFloat = 240) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: 20, y: y, width: width, height: 20)
        field.font = .boldSystemFont(ofSize: 13)
        return field
    }

    private func makeSeparator(y: CGFloat) -> NSBox {
        let box = NSBox(frame: NSRect(x: 20, y: y, width: 480, height: 1))
        box.boxType = .separator
        return box
    }

    private func makeTimePicker(x: CGFloat, y: CGFloat) -> NSDatePicker {
        let picker = NSDatePicker(frame: NSRect(x: x, y: y, width: 90, height: 24))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.datePickerElements = [.hourMinute]
        picker.target = self
        picker.action = #selector(valueChanged)
        return picker
    }

    // Строка «С: [время]  До: [время]» — используется и для рабочего времени, и
    // для перерыва, чтобы обе пары читались одинаково.
    private func addTimeRow(to content: NSView,
                            y: CGFloat,
                            from: NSDatePicker,
                            to toPicker: NSDatePicker) {
        content.addSubview(makeFieldLabel("С:", x: 20, width: 110, y: y + 2))
        content.addSubview(from)
        content.addSubview(makeFieldLabel("до:", x: 250, width: 40, y: y + 2))
        content.addSubview(toPicker)
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Автоматизация"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = window.contentView!

        let title = NSTextField(labelWithString: "Управлять stkh-client по расписанию")
        title.frame = NSRect(x: 20, y: 402, width: 400, height: 22)
        title.font = .boldSystemFont(ofSize: 13)
        content.addSubview(title)

        enabledSwitch = NSSwitch(frame: NSRect(x: 452, y: 400, width: 48, height: 24))
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledChanged)
        content.addSubview(enabledSwitch)

        content.addSubview(makeSeparator(y: 388))

        content.addSubview(makeSectionLabel("Рабочее время", y: 358))

        content.addSubview(makeFieldLabel("Дни:", x: 20, width: 110, y: 330))
        for (position, weekday) in weekdayDisplayOrder.enumerated() {
            let checkbox = NSButton(checkboxWithTitle: weekdayShortNames[weekday] ?? "",
                                    target: self,
                                    action: #selector(valueChanged))
            let row = position / 4
            let column = position % 4
            checkbox.frame = NSRect(x: 150 + CGFloat(column) * 64,
                                    y: 330 - CGFloat(row) * 26,
                                    width: 60,
                                    height: 20)
            content.addSubview(checkbox)
            dayCheckboxes[weekday] = checkbox
        }

        let presetWeekdays = NSButton(title: "Будни", target: self, action: #selector(selectWeekdays))
        presetWeekdays.frame = NSRect(x: 150, y: 270, width: 90, height: 26)
        presetWeekdays.bezelStyle = .rounded
        let presetAll = NSButton(title: "Все дни", target: self, action: #selector(selectAllDays))
        presetAll.frame = NSRect(x: 246, y: 270, width: 90, height: 26)
        presetAll.bezelStyle = .rounded
        presetButtons = [presetWeekdays, presetAll]
        presetButtons.forEach { content.addSubview($0) }

        startPicker = makeTimePicker(x: 150, y: 234)
        stopPicker = makeTimePicker(x: 298, y: 234)
        addTimeRow(to: content, y: 234, from: startPicker, to: stopPicker)

        content.addSubview(makeSeparator(y: 212))

        content.addSubview(makeSectionLabel("Перерыв", y: 180, width: 120))
        breakCheckbox = NSButton(checkboxWithTitle: "Останавливать на перерыв",
                                 target: self,
                                 action: #selector(breakEnabledChanged))
        breakCheckbox.frame = NSRect(x: 150, y: 181, width: 260, height: 20)
        content.addSubview(breakCheckbox)

        breakStartPicker = makeTimePicker(x: 150, y: 146)
        breakStopPicker = makeTimePicker(x: 298, y: 146)
        addTimeRow(to: content, y: 146, from: breakStartPicker, to: breakStopPicker)

        content.addSubview(makeSeparator(y: 124))

        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.frame = NSRect(x: 20, y: 96, width: 480, height: 18)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        content.addSubview(summaryLabel)

        let note = NSTextField(wrappingLabelWithString:
            "Автоматика работает, пока запущено приложение, и проверяется каждые несколько секунд. "
            + "Если время окончания меньше времени начала, промежуток считается переходящим через полночь. "
            + "Без установленного helper'а каждый запуск и остановка будут спрашивать пароль администратора.")
        note.frame = NSRect(x: 20, y: 50, width: 480, height: 44)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        content.addSubview(note)

        let cancelButton = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        cancelButton.frame = NSRect(x: 308, y: 14, width: 90, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        content.addSubview(cancelButton)

        let saveButton = NSButton(title: "Сохранить", target: self, action: #selector(save))
        saveButton.frame = NSRect(x: 406, y: 14, width: 100, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        content.addSubview(saveButton)

        self.window = window
    }

    // MARK: Состояние

    // Пикеры работают с Date, а не с минутами, поэтому время кладём на
    // произвольный день — важны только часы и минуты.
    private func date(fromMinutes minutes: Int) -> Date {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: base) ?? base
    }

    private func populate(schedule: DaemonSchedule) {
        enabledSwitch.state = schedule.enabled ? .on : .off
        startPicker.dateValue = date(fromMinutes: schedule.startMinutes)
        stopPicker.dateValue = date(fromMinutes: schedule.stopMinutes)
        breakCheckbox.state = schedule.breakEnabled ? .on : .off
        breakStartPicker.dateValue = date(fromMinutes: schedule.breakStartMinutes)
        breakStopPicker.dateValue = date(fromMinutes: schedule.breakStopMinutes)
        for (weekday, checkbox) in dayCheckboxes {
            checkbox.state = schedule.weekdays.contains(weekday) ? .on : .off
        }
        updateEnabledState()
    }

    private func currentSchedule() -> DaemonSchedule {
        DaemonSchedule(
            enabled: enabledSwitch.state == .on,
            startMinutes: minutesOfDay(startPicker.dateValue),
            stopMinutes: minutesOfDay(stopPicker.dateValue),
            weekdays: Set(dayCheckboxes.filter { $0.value.state == .on }.keys),
            breakEnabled: breakCheckbox.state == .on,
            breakStartMinutes: minutesOfDay(breakStartPicker.dateValue),
            breakStopMinutes: minutesOfDay(breakStopPicker.dateValue)
        )
    }

    // Сводка — главная защита от молча неверной настройки: и окно через
    // полночь, и перерыв, заданный вне рабочего времени, выглядят в полях
    // совершенно нормально, и заметить их можно только по этой строке.
    private func updateEnabledState() {
        let active = enabledSwitch.state == .on
        let breakActive = active && breakCheckbox.state == .on
        startPicker.isEnabled = active
        stopPicker.isEnabled = active
        breakCheckbox.isEnabled = active
        breakStartPicker.isEnabled = breakActive
        breakStopPicker.isEnabled = breakActive
        for checkbox in dayCheckboxes.values { checkbox.isEnabled = active }
        presetButtons.forEach { $0.isEnabled = active }

        let schedule = currentSchedule()
        var warning = false
        var text: String
        if schedule.weekdays.isEmpty {
            text = "Выберите хотя бы один день"
            warning = active
        } else {
            text = describeSchedule(schedule)
            if schedule.crossesMidnight { text += " (через полночь)" }
            if schedule.hasBreak {
                text += ", \(describeBreak(schedule))"
                if !schedule.breakInsideWorkWindow {
                    text += " — вне рабочего времени, действовать не будет"
                    warning = active
                }
            }
        }
        summaryLabel.stringValue = text
        summaryLabel.textColor = warning ? .systemRed : .secondaryLabelColor
    }

    // MARK: Действия

    @objc private func enabledChanged() {
        updateEnabledState()
    }

    @objc private func breakEnabledChanged() {
        updateEnabledState()
    }

    @objc private func valueChanged() {
        updateEnabledState()
    }

    @objc private func selectWeekdays() {
        for (weekday, checkbox) in dayCheckboxes {
            checkbox.state = (2...6).contains(weekday) ? .on : .off
        }
        updateEnabledState()
    }

    @objc private func selectAllDays() {
        for checkbox in dayCheckboxes.values { checkbox.state = .on }
        updateEnabledState()
    }

    @objc private func save() {
        let schedule = currentSchedule()
        // Включённая автоматика без единого дня — единственное сочетание, в
        // котором переключатель обещает одно, а приложение не делает ничего.
        if schedule.enabled && schedule.weekdays.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Не выбран ни один день"
            alert.informativeText = "Отметьте дни недели, в которые должна работать автоматика, "
                + "либо выключите переключатель вверху окна."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        onSave?(schedule)
        close()
    }

    @objc private func cancel() {
        close()
    }

    private func close() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
