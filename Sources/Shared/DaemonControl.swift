import Foundation

// Общий код приложения и привилегированного helper'а. Компилируется в оба
// бинарника: только так команды управления демоном и описание XPC-протокола
// физически не могут разъехаться между клиентом и сервером.

// MARK: - Демон stkh-client

let targetPath = "/usr/local/libexec/stkh-client.app/Contents/MacOS/stkh-client"
let daemonLabel = "stkh-client-daemon"
let agentLabel = "stkh-client-agent"
let daemonPlist = "/Library/LaunchDaemons/\(daemonLabel).plist"
let agentPlist = "/Library/LaunchAgents/\(agentLabel).plist"

// MARK: - Запуск процессов

struct ProcessResult {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
    // status == -1 ставим сами, когда процесс вообще не удалось запустить.
    // Это принципиально другой случай, чем «команда отработала и вернула
    // ошибку»: helper по нему отличает свой сбой от штатного отказа launchctl.
    var launched: Bool { status != -1 }
}

@discardableResult
func runProcess(_ path: String, _ arguments: [String], captureError: Bool = false) -> ProcessResult {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    // stderr по умолчанию отбрасываем: вывод многих вызовов разбирается
    // построчно, и подмешанные туда предупреждения ломали бы разбор.
    task.standardError = captureError ? pipe : Pipe()
    do {
        try task.run()
    } catch {
        return ProcessResult(status: -1, output: "\(error)")
    }
    // Читаем до EOF раньше waitUntilExit — иначе процесс с большим выводом
    // заблокируется на заполненном пайпе.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return ProcessResult(status: task.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Графические сеансы

// При быстром переключении пользователей одновременно открыто несколько
// графических сеансов, и у каждого свой домен launchd — gui/<uid>. Опознаём их
// по loginwindow: этот процесс существует ровно по одному на сеанс.
//
// Это принципиально: stkh-client-agent лежит в /Library/LaunchAgents, то есть
// загружается в каждый сеанс и держит KeepAlive. Выгрузить его только в своём
// сеансе недостаточно — чужой launchd тут же поднимет демона обратно.
func activeGUISessionUIDs() -> [Int32] {
    let result = runProcess("/bin/ps", ["-axo", "uid=,comm="])
    guard result.ok else { return [] }
    var uids: [Int32] = []
    for line in result.output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("/loginwindow") else { continue }
        guard let uid = Int32(trimmed.prefix(while: { $0.isNumber })) else { continue }
        if !uids.contains(uid) { uids.append(uid) }
    }
    return uids
}

// Служебные uid (< 500) отсекаем: в системные домены launchd мы не лезем ни в
// одном сценарии, а _windowserver и подобные в этот список попадать не должны.
func normalizedSessionUIDs(_ uids: [Int32]) -> [Int32] {
    var result: [Int32] = []
    for uid in uids where uid >= 500 && !result.contains(uid) {
        result.append(uid)
    }
    return result.sorted()
}

// MARK: - Команды управления демоном

struct DaemonCommand {
    let path: String
    let arguments: [String]
    // Ненулевой код у большинства команд — норма: bootout ругается на не
    // загруженную службу, bootstrap — на уже загруженную. У критичных команд
    // (запись плиста) это не так: там ошибка означает, что ничего не вышло, и
    // выдавать её за успех нельзя.
    var critical: Bool = false

    // Для запасного пути через `do shell script`: та же команда, но строкой.
    var shellLine: String {
        ([path] + arguments).map { argument in
            "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

// Единственный источник правды о том, что значит «запустить» и «остановить»
// stkh-client. Одним и тем же списком пользуются helper (выполняет напрямую от
// root) и запасной путь через запрос пароля.
func daemonControlCommands(shouldRun: Bool, uids: [Int32]) -> [DaemonCommand] {
    let sessions = normalizedSessionUIDs(uids)
    guard shouldRun else {
        var commands = [DaemonCommand(path: "/bin/launchctl", arguments: ["bootout", "system/\(daemonLabel)"])]
        // Сначала выгружаем агенты во всех сеансах и только потом добиваем
        // процесс: у агента KeepAlive, и убитый раньше времени демон был бы
        // немедленно поднят заново.
        commands += sessions.map {
            DaemonCommand(path: "/bin/launchctl", arguments: ["bootout", "gui/\($0)/\(agentLabel)"])
        }
        // Демон может пережить bootout, если launchd не успел его добить.
        commands.append(DaemonCommand(path: "/usr/bin/pkill", arguments: ["-9", "-f", targetPath]))
        return commands
    }
    return [DaemonCommand(path: "/bin/launchctl", arguments: ["bootstrap", "system", daemonPlist])]
        + sessions.map {
            DaemonCommand(path: "/bin/launchctl", arguments: ["bootstrap", "gui/\($0)", agentPlist])
        }
}

// Ненулевой код возврата здесь — норма: bootout ругается, когда служба и так не
// загружена, bootstrap — когда она уже загружена. Реальное состояние всё равно
// проверяется опросом pgrep, поэтому наружу отдаём только диагностику.
func describeCommandFailure(_ command: DaemonCommand, _ result: ProcessResult) -> String {
    let name = ([command.path] + command.arguments).joined(separator: " ")
    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? "\(name): код \(result.status)" : "\(name): \(output)"
}

// Выполняет список от имени текущего процесса (у helper'а это root). Провалом
// считается либо ошибка критичной команды, либо невозможность запустить вообще
// ни одну из них — остальные ненулевые коды идут только в диагностику.
func runDaemonCommands(_ commands: [DaemonCommand]) -> (ok: Bool, message: String) {
    var diagnostics: [String] = []
    var launchFailures = 0
    var criticalFailed = false
    for command in commands {
        let result = runProcess(command.path, command.arguments, captureError: true)
        guard !result.ok else { continue }
        if !result.launched { launchFailures += 1 }
        if command.critical { criticalFailed = true }
        diagnostics.append(describeCommandFailure(command, result))
    }
    let ok = !criticalFailed && launchFailures < max(commands.count, 1)
    return (ok, diagnostics.joined(separator: "; "))
}

// Тот же список команд, но одним скриптом для `do shell script … with
// administrator privileges`. Некритичные коды глушим: `do shell script` считает
// ошибкой любой ненулевой код и показал бы пользователю лишний диалог.
func adminScript(for commands: [DaemonCommand]) -> String {
    let lines = commands.map { command in
        command.critical ? command.shellLine : "\(command.shellLine) >/dev/null 2>&1 || true"
    }
    return (lines + ["true"]).joined(separator: "\n")
}

// MARK: - Автозапуск приложения во всех сеансах

let appLaunchAgentLabel = "com.ilya.stkhmonitor"
let userLaunchAgentRelativePath = "Library/LaunchAgents/\(appLaunchAgentLabel).plist"
let sharedLaunchAgentPath = "/Library/LaunchAgents/\(appLaunchAgentLabel).plist"
let appExecutableName = "StkhMonitor"

// Плист в /Library/LaunchAgents launchd грузит в каждый графический сеанс —
// иконка появляется у любого вошедшего пользователя, а не только у того, кто
// ставил приложение. Пер-юзерный агент в ~/Library/LaunchAgents так не умеет:
// он существует только в одном домашнем каталоге, куда остальным доступа нет.
func sharedLaunchAgentPlist(executablePath: String) -> [String: Any] {
    [
        "Label": appLaunchAgentLabel,
        "ProgramArguments": [executablePath],
        "RunAtLoad": true,
        "KeepAlive": false,
        "ProcessType": "Interactive",
        // Только графические сеансы: в ssh-сеансе строки меню нет и запускать
        // приложение незачем.
        "LimitLoadToSessionType": "Aqua",
    ]
}

func launchAgentProgramPath(atPath path: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let plist = try? PropertyListSerialization.propertyList(
              from: data, options: [], format: nil) as? [String: Any],
          let arguments = plist["ProgramArguments"] as? [String] else { return nil }
    return arguments.first
}

// Никаких bootout по метке приложения: у системного и пер-юзерного агента она
// одна и та же, а bootout убивает уже запущенный экземпляр. Выключение поэтому
// только снимает плист (при следующем входе приложение просто не стартует), а
// включение — только bootstrap: в сеансах, где приложение уже работает, launchd
// откажет («служба загружена»), и это ровно то, что нужно, а в остальных иконка
// появится сразу, без перезахода.
func sharedAutostartCommands(enabled: Bool, executablePath: String, uids: [Int32]) -> [DaemonCommand] {
    guard enabled else {
        return [DaemonCommand(path: "/bin/rm", arguments: ["-f", sharedLaunchAgentPath], critical: true)]
    }
    guard let data = try? PropertyListSerialization.data(
            fromPropertyList: sharedLaunchAgentPlist(executablePath: executablePath),
            format: .xml, options: 0) else { return [] }
    // Содержимое плиста передаём в base64: внутрь `sh -c` оно попадает строкой
    // из букв, цифр и `+/=`, поэтому кавычки в путях ничего не ломают.
    let write = "printf %s '\(data.base64EncodedString())' | /usr/bin/base64 -D > '\(sharedLaunchAgentPath)'"
        + " && /usr/sbin/chown root:wheel '\(sharedLaunchAgentPath)'"
        + " && /bin/chmod 644 '\(sharedLaunchAgentPath)'"
    return [DaemonCommand(path: "/bin/sh", arguments: ["-c", write], critical: true)]
        + normalizedSessionUIDs(uids).map {
            DaemonCommand(path: "/bin/launchctl", arguments: ["bootstrap", "gui/\($0)", sharedLaunchAgentPath])
        }
}

// Путь к собственному бинарнику. Bundle.main для исполняемого файла внутри
// Contents/MacOS указывает на бандл приложения целиком, поэтому helper'у он не
// годится — спрашиваем у dyld.
func currentProcessExecutablePath() -> String {
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        return CommandLine.arguments.first ?? ""
    }
    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
}

// Основной бинарник приложения рядом с текущим: helper лежит в том же
// Contents/MacOS. Путь helper определяет сам, а не берёт из запроса клиента —
// он попадает в системный плист автозапуска, и принимать его снаружи означало
// бы разрешить прописать всем пользователям запуск чего угодно.
func siblingAppExecutablePath() -> String? {
    let path = URL(fileURLWithPath: currentProcessExecutablePath())
        .deletingLastPathComponent()
        .appendingPathComponent(appExecutableName)
        .path
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}

// Автозапуск для всех пользователей имеет смысл только из /Applications: домашний
// каталог соседа недоступен, и агент в чужом сеансе просто не стартовал бы.
func isSharedInstallLocation(_ executablePath: String) -> Bool {
    executablePath.hasPrefix("/Applications/")
}

// MARK: - XPC-протокол helper'а

let helperMachServiceName = "com.ilya.stkhmonitor.helper"
let helperPlistName = "\(helperMachServiceName).plist"

// Поднимаем при любом изменении helper'а. Приложение сравнивает это число с
// версией уже установленного демона: launchd продолжает крутить старый бинарник
// до перерегистрации, и без явной версии рассинхрон был бы невидим.
let helperProtocolVersion = 2

@objc(StkhHelperProtocol) protocol StkhHelperProtocol {
    func fetchVersion(reply: @escaping (Int) -> Void)
    func setDaemonRunning(_ shouldRun: Bool, uid: Int32, reply: @escaping (Bool, String) -> Void)
    func setSharedAutostart(_ enabled: Bool, reply: @escaping (Bool, String) -> Void)
}
