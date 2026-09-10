import Foundation

// Привилегированный helper. Запускается launchd от root по требованию (плист
// лежит в Contents/Library/LaunchDaemons бандла и регистрируется через
// SMAppService), слушает Mach-сервис и умеет ровно два действия: запустить или
// остановить stkh-client и включить или выключить автозапуск приложения во всех
// сеансах.
//
// Намеренно не принимает ни произвольных команд, ни путей, ни аргументов —
// иначе это был бы sudo без пароля для любого, кто до него дотянется. Пути и
// список сеансов helper определяет сам.

func log(_ message: String) {
    NSLog("[stkhmonitor-helper] %@", message)
}

final class HelperService: NSObject, StkhHelperProtocol {
    func fetchVersion(reply: @escaping (Int) -> Void) {
        reply(helperProtocolVersion)
    }

    func setDaemonRunning(_ shouldRun: Bool, uid: Int32, reply: @escaping (Bool, String) -> Void) {
        // uid приходит снаружи и подставляется в домен gui/<uid>. Диапазон
        // сверяем даже при доверенном клиенте: обычные пользователи начинаются
        // с 501, и bootstrap в системные домены нам не нужен ни в одном
        // сценарии.
        guard uid >= 500 else {
            reply(false, "недопустимый uid \(uid)")
            return
        }

        // Список сеансов helper собирает сам: stkh-client-agent загружен в
        // каждый графический сеанс, и остановка только в сеансе позвавшего
        // пользователя ничего бы не дала — агент соседа поднял бы демона
        // обратно. uid клиента добавляем на случай, если ps по какой-то причине
        // не отдал его сеанс.
        let uids = normalizedSessionUIDs(activeGUISessionUIDs() + [uid])
        let (ok, message) = runDaemonCommands(daemonControlCommands(shouldRun: shouldRun, uids: uids))
        log("setDaemonRunning(\(shouldRun), uid: \(uid), сеансы: \(uids)) -> ok=\(ok) \(message)")
        reply(ok, message)
    }

    // Ставит или снимает системный LaunchAgent приложения, чтобы иконка была в
    // строке меню у каждого вошедшего пользователя. Путь к бинарнику helper
    // берёт у себя (см. siblingAppExecutablePath) — клиент им не управляет.
    func setSharedAutostart(_ enabled: Bool, reply: @escaping (Bool, String) -> Void) {
        guard let executable = siblingAppExecutablePath() else {
            reply(false, "не удалось определить путь к приложению")
            return
        }
        guard !enabled || isSharedInstallLocation(executable) else {
            reply(false, "приложение должно лежать в папке «Программы»")
            return
        }
        let uids = normalizedSessionUIDs(activeGUISessionUIDs())
        let commands = sharedAutostartCommands(enabled: enabled, executablePath: executable, uids: uids)
        guard !commands.isEmpty else {
            reply(false, "не удалось собрать плист автозапуска")
            return
        }
        let (ok, message) = runDaemonCommands(commands)
        log("setSharedAutostart(\(enabled), сеансы: \(uids)) -> ok=\(ok) \(message)")
        reply(ok, message)
    }
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: StkhHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: helperMachServiceName)
let listenerDelegate = HelperListenerDelegate()
listener.delegate = listenerDelegate

// Проверку подписи клиента делает сам XPC — до того, как соединение дойдёт до
// нашего кода. Это принципиально надёжнее ручной проверки по PID: тот подвержен
// гонке с переиспользованием идентификатора процесса.
//
// Требование генерируется на этапе сборки из фактической подписи приложения
// (build/generated/SigningRequirement.swift), поэтому оно совпадает и с
// самоподписанным сертификатом, и с Developer ID.
if #available(macOS 13.0, *) {
    listener.setConnectionCodeSigningRequirement(helperClientRequirement)
} else {
    // На macOS 12 и старше нет ни SMAppService, ни этой проверки, так что
    // helper туда и не ставится. Если он всё же там оказался — выходим:
    // принимать соединения без проверки подписи хуже, чем не работать вовсе.
    log("требуется macOS 13 или новее — проверка подписи клиента недоступна")
    exit(EXIT_FAILURE)
}

log("запущен, версия протокола \(helperProtocolVersion)")
listener.resume()
dispatchMain()
