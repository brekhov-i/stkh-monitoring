import Cocoa
import Security
import ServiceManagement
import SystemConfiguration

// Константы демона, запуск процессов и XPC-протокол живут в
// Sources/Shared/DaemonControl.swift — их использует и helper.

func isDaemonRunning() -> Bool {
    runProcess("/usr/bin/pgrep", ["-f", "^\(targetPath)"]).ok
}

let vpnHost = "guard.profit.local"

func pingHost(_ host: String) -> Bool {
    runProcess("/sbin/ping", ["-c", "1", "-t", "2", host]).ok
}

struct AdminResult {
    let ok: Bool
    let cancelled: Bool
    let output: String
    let message: String
}

// Ошибка -128 — это «пользователь нажал Отмена» в запросе пароля. Отличать её
// от настоящего сбоя обязательно: раньше оба случая выглядели одинаково, и
// после отмены приложение ругалось так, будто что-то сломалось.
@discardableResult
func runShellAsAdmin(_ script: String) -> AdminResult {
    let escaped = script
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
    guard let scriptObject = NSAppleScript(source: appleScript) else {
        return AdminResult(ok: false, cancelled: false, output: "",
                           message: "не удалось собрать AppleScript")
    }
    var error: NSDictionary?
    let result = scriptObject.executeAndReturnError(&error)
    if let error = error {
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "код \(code)"
        return AdminResult(ok: false, cancelled: code == -128, output: "", message: message)
    }
    return AdminResult(ok: true, cancelled: false, output: result.stringValue ?? "", message: "")
}

// Итог команды запуска/остановки, каким бы путём она ни выполнялась.
struct DaemonCommandOutcome {
    let ok: Bool
    let cancelled: Bool
    let message: String
    let usedHelper: Bool
}

// Сеансы, в которых нужно поднять или выгрузить службы: все графические плюс
// свой на случай, если ps его не показал.
func daemonSessionUIDs() -> [Int32] {
    normalizedSessionUIDs(activeGUISessionUIDs() + [Int32(getuid())])
}

func launchAgentPlistURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(userLaunchAgentRelativePath)
}

// Через dyld, а не через Bundle.main: helper вычисляет путь так же, и их
// сравнение (совпадает ли плист автозапуска с текущим бинарником) должно быть
// посимвольным.
func currentExecutablePath() -> String {
    let path = currentProcessExecutablePath()
    return path.isEmpty ? (Bundle.main.executablePath ?? CommandLine.arguments[0]) : path
}

// Автозапуск для всех пользователей: системный плист есть и ведёт именно на это
// приложение.
func isSharedAutostartEnabled() -> Bool {
    launchAgentProgramPath(atPath: sharedLaunchAgentPath) == currentExecutablePath()
}

func isRunningFromMountedDMG() -> Bool {
    Bundle.main.bundlePath.hasPrefix("/Volumes/")
}

func isLaunchAgentUpToDate() -> Bool {
    guard let data = try? Data(contentsOf: launchAgentPlistURL()),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          let args = plist["ProgramArguments"] as? [String] else {
        return false
    }
    return args.first == currentExecutablePath()
}

func runLaunchctl(_ arguments: [String]) {
    runProcess("/bin/launchctl", arguments)
}

func installLaunchAgent() {
    let url = launchAgentPlistURL()
    let plistDict: [String: Any] = [
        "Label": appLaunchAgentLabel,
        "ProgramArguments": [currentExecutablePath()],
        "RunAtLoad": true,
        "KeepAlive": false,
        "ProcessType": "Interactive"
    ]
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0) else { return }
    try? data.write(to: url)

    // Note: intentionally not bootstrapped here — bootstrapping a RunAtLoad
    // agent launches it immediately, which would spawn a duplicate instance
    // alongside the one currently running. Writing the plist is enough: launchd
    // picks it up automatically at the next login.
    bootoutUserLaunchAgent()
}

func removeLaunchAgent() {
    bootoutUserLaunchAgent()
    try? FileManager.default.removeItem(at: launchAgentPlistURL())
}

// Метка у пер-юзерного и системного агента одна. Пока в /Library лежит
// системный плист, bootout снял бы именно его — вместе с работающим
// приложением, — поэтому в этом случае просто оставляем регистрацию launchd в
// покое: она всё равно перечитывается при следующем входе.
func bootoutUserLaunchAgent() {
    guard !FileManager.default.fileExists(atPath: sharedLaunchAgentPath) else { return }
    runLaunchctl(["bootout", "gui/\(getuid())/\(appLaunchAgentLabel)"])
}

// Ограничение по -U обязательно: pgrep видит процессы всех пользователей, а при
// быстром переключении пользователей у каждого из них свой сеанс и своя строка
// меню — но исполняемый файл один и тот же (/Applications/…). Без -U второй
// вошедший пользователь находил экземпляр первого и молча завершался, так что
// иконка появлялась только у одного.
// Кто сейчас за экраном. При быстром переключении пользователей приложение
// работает в каждом сеансе, и без этой проверки два экземпляра дёргали бы
// туннель наперегонки: один пользователь отключает VPN вручную, а фоновый
// экземпляр другого через пять секунд поднимает его обратно.
func consoleSessionUID() -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
          !name.isEmpty, name != "loginwindow" else { return nil }
    return uid
}

func isConsoleSession() -> Bool {
    guard let consoleUID = consoleSessionUID() else { return true }
    return consoleUID == getuid()
}

func isAnotherInstanceRunning() -> Bool {
    let myPid = ProcessInfo.processInfo.processIdentifier
    let path = currentExecutablePath()
    let result = runProcess("/usr/bin/pgrep", ["-U", String(getuid()), "-f", "^\(path)$"])
    let pids = result.output.split(separator: "\n").compactMap { Int32($0) }
    return pids.contains { $0 != myPid }
}

// MARK: - VPN L2TP/IPSec: модель

struct VPNService {
    let id: String
    let name: String
    let type: String
    let enabled: Bool

    var isL2TP: Bool { type.uppercased().contains("L2TP") }
    var menuTitle: String { isL2TP ? "\(name) (L2TP)" : "\(name) [\(type)]" }
}

enum VPNState {
    case connected, connecting, disconnecting, disconnected, invalid, unknown

    init(_ status: SCNetworkConnectionStatus) {
        switch status {
        case .connected: self = .connected
        case .connecting: self = .connecting
        case .disconnecting: self = .disconnecting
        case .disconnected: self = .disconnected
        case .invalid: self = .invalid
        @unknown default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .connected: return "подключено"
        case .connecting: return "подключение…"
        case .disconnecting: return "отключение…"
        case .disconnected: return "отключено"
        case .invalid: return "не настроено"
        case .unknown: return "неизвестно"
        }
    }

    var color: NSColor {
        switch self {
        case .connected: return .systemGreen
        case .connecting, .disconnecting: return .systemOrange
        case .disconnected: return .systemRed
        case .invalid, .unknown: return .secondaryLabelColor
        }
    }

    var isBusy: Bool { self == .connecting || self == .disconnecting }
}

// MARK: - VPN L2TP/IPSec: чтение состояния

let scutilPath = "/usr/sbin/scutil"

// Строка `scutil --nc list` выглядит так:
//   * (Disconnected)   8FAFC3B8-…-C73DF40E1E0C PPP --> L2TP  "VPN"  [PPP:L2TP]
// Имя всегда в последних кавычках перед типом в квадратных скобках, поэтому
// цепляемся за хвост строки, а не за середину (у некоторых служб в описании
// типа есть свои скобки, например `VPN (com.wireguard.macos)`).
let vpnListLineRegex = try? NSRegularExpression(
    pattern: "^(\\*| )\\s*\\(([A-Za-z]+)\\)\\s+([0-9A-Fa-f-]{36})\\s+.*\"([^\"]*)\"\\s*\\[([^\\]]+)\\]\\s*$"
)

func listVPNServices() -> [VPNService] {
    guard let regex = vpnListLineRegex else { return [] }
    let result = runProcess(scutilPath, ["--nc", "list"])
    guard result.ok else { return [] }
    var services: [VPNService] = []
    for line in result.output.split(separator: "\n").map(String.init) {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else { continue }
        func group(_ index: Int) -> String {
            guard let r = Range(match.range(at: index), in: line) else { return "" }
            return String(line[r])
        }
        services.append(VPNService(id: group(3), name: group(4), type: group(5), enabled: group(1) == "*"))
    }
    return services
}

// Соединение создаём на каждый вызов: объект дешёвый, а держать его в поле
// пришлось бы синхронизировать между потоками.
func vpnConnection(serviceID: String) -> SCNetworkConnection? {
    guard !serviceID.isEmpty else { return nil }
    return SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, nil, nil)
}

func vpnState(serviceID: String) -> VPNState {
    guard let connection = vpnConnection(serviceID: serviceID) else { return .invalid }
    return VPNState(SCNetworkConnectionGetStatus(connection))
}

// Достаёт имя пользователя из уже настроенной службы, чтобы не заставлять
// вводить его руками.
func vpnConfiguredUsername(serviceID: String) -> String {
    guard !serviceID.isEmpty else { return "" }
    let result = runProcess(scutilPath, ["--nc", "show", serviceID])
    guard result.ok else { return "" }
    for line in result.output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("AuthName") , let colon = trimmed.firstIndex(of: ":") else { continue }
        return String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
    return ""
}

// MARK: - VPN L2TP/IPSec: настройки

struct VPNConfig: Codable {
    var serviceID: String
    var serviceName: String
    var username: String
    var password: String
    var sharedSecret: String
    var autoReconnect: Bool?

    init(serviceID: String = "",
         serviceName: String = "",
         username: String = "",
         password: String = "",
         sharedSecret: String = "",
         autoReconnect: Bool? = nil) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.username = username
        self.password = password
        self.sharedSecret = sharedSecret
        self.autoReconnect = autoReconnect
    }

    // Мониторинг и переподключение включены по умолчанию: ради этого приложение
    // и висит в строке меню. nil означает «пользователь ещё не решал».
    var autoReconnectEnabled: Bool { autoReconnect ?? true }

    enum CodingKeys: String, CodingKey {
        case serviceID, serviceName, username, password, sharedSecret, autoReconnect
    }

    // Свой декодер: синтезированный требует все не-опциональные ключи, а нам
    // нужно уметь читать частичный файл (например, только sharedSecret).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serviceID = try c.decodeIfPresent(String.self, forKey: .serviceID) ?? ""
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        sharedSecret = try c.decodeIfPresent(String.self, forKey: .sharedSecret) ?? ""
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect)
    }
}

// Значения по умолчанию, вшиваемые на этапе сборки. Заполните sharedSecret
// (и при необходимости username), если хотите раздавать сборку, в которой
// общий ключ уже подставлен и пользователь его вообще никогда не вводит.
// Более гибкая альтернатива — файл VPNConfigStore.managedPath, разложенный
// администратором на машины.
let builtinVPNDefaults = VPNConfig(
    serviceName: "VPN",
    username: "",
    password: "",
    sharedSecret: "",
    autoReconnect: nil
)

// Непустые поля `override` перекрывают `base`; пустые — оставляют базовое
// значение. Так вшитые/централизованные умолчания заполняют то, что
// пользователь не задал сам.
func mergeVPNConfig(_ base: VPNConfig, _ override: VPNConfig) -> VPNConfig {
    var result = base
    if !override.serviceID.isEmpty { result.serviceID = override.serviceID }
    if !override.serviceName.isEmpty { result.serviceName = override.serviceName }
    if !override.username.isEmpty { result.username = override.username }
    if !override.password.isEmpty { result.password = override.password }
    if !override.sharedSecret.isEmpty { result.sharedSecret = override.sharedSecret }
    if let auto = override.autoReconnect { result.autoReconnect = auto }
    return result
}

enum Keychain {
    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func write(service: String, account: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        insert[kSecAttrLabel as String] = "StkhMonitor VPN"
        insert[kSecAttrDescription as String] = "Учётные данные VPN для StkhMonitor"
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

enum VPNConfigStore {
    static let keychainService = "com.ilya.stkhmonitor.vpn"
    static let keychainAccount = "config"

    // Файл для централизованной раздачи: администратор кладёт сюда JSON вида
    // {"serviceName":"VPN","username":"","sharedSecret":"…"} и общий ключ
    // подставляется на всех машинах без участия пользователя.
    static let managedURL = URL(fileURLWithPath: "/Library/Application Support/StkhMonitor/vpn.json")

    static var userFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/StkhMonitor/vpn.json")
    }

    private static func decode(_ data: Data?) -> VPNConfig? {
        guard let data = data else { return nil }
        return try? JSONDecoder().decode(VPNConfig.self, from: data)
    }

    static func load() -> VPNConfig {
        var config = builtinVPNDefaults
        if let managed = decode(try? Data(contentsOf: managedURL)) {
            config = mergeVPNConfig(config, managed)
        }
        if let stored = decode(Keychain.read(service: keychainService, account: keychainAccount)) {
            config = mergeVPNConfig(config, stored)
        } else if let stored = decode(try? Data(contentsOf: userFileURL)) {
            config = mergeVPNConfig(config, stored)
        }
        return config
    }

    @discardableResult
    static func save(_ config: VPNConfig) -> Bool {
        guard let data = try? JSONEncoder().encode(config) else { return false }
        if Keychain.write(service: keychainService, account: keychainAccount, data: data) { return true }
        // Запасной путь, если связка ключей недоступна: файл только для владельца.
        let url = userFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}

// MARK: - VPN L2TP/IPSec: управление

// Три попытки: обрыв обычно лечится первой же, а если сервер действительно
// лежит, долбиться в него бесконечно бессмысленно. Пауза между попытками нужна,
// чтобы успело отработать рукопожатие L2TP и подняться сеть после сна.
let vpnMaxReconnectAttempts = 3
let vpnReconnectDelay: TimeInterval = 15

// Выбирает службу, которой управляем: сначала по сохранённому ID, потом по
// имени, иначе — первая же L2TP-служба в системе. Благодаря последнему
// пункту в типовом случае настраивать вообще нечего.
func resolveVPNService(config: VPNConfig, services: [VPNService]) -> VPNService? {
    if !config.serviceID.isEmpty, let byID = services.first(where: { $0.id == config.serviceID }) {
        return byID
    }
    if !config.serviceName.isEmpty,
       let byName = services.first(where: { $0.name == config.serviceName && $0.isL2TP }) {
        return byName
    }
    return services.first(where: { $0.isL2TP })
}

// Почему не `scutil --nc start`: он всегда передаёт системе набор
// пользовательских опций, и L2TP-плагин, найдя там пустой общий ключ, отвергает
// подключение, не дойдя до IPSec. В /var/log/ppp.log это выглядит так:
//     L2TP connecting to server 'vpn.pr-lg.ru' (87.117.29.106)...
//     L2TP: incorrect user shared secret found.
// «Системные настройки» опций не передают вовсе — и система сама берёт общий
// ключ из системной связки, куда доступ есть только у неё. Делаем так же:
// userOptions = nil. Тогда ключ вообще не нужно ни читать, ни хранить, ни
// спрашивать у пользователя.
//
// Опции передаём, только если ключ задан в приложении вручную — это осознанное
// переопределение для нестандартных конфигураций.
@discardableResult
func startVPN(_ config: VPNConfig, serviceID: String) -> Bool {
    guard let connection = vpnConnection(serviceID: serviceID) else { return false }

    var userOptions: CFDictionary?
    if !config.sharedSecret.isEmpty {
        var ppp: [String: Any] = [:]
        if !config.username.isEmpty { ppp[kSCPropNetPPPAuthName as String] = config.username }
        if !config.password.isEmpty { ppp[kSCPropNetPPPAuthPassword as String] = config.password }
        var options: [String: Any] = [
            kSCEntNetIPSec as String: [kSCPropNetIPSecSharedSecret as String: config.sharedSecret]
        ]
        if !ppp.isEmpty { options[kSCEntNetPPP as String] = ppp }
        userOptions = options as CFDictionary
    }

    // linger = true: туннель переживёт выход приложения, как и при подключении
    // из «Настроек».
    return SCNetworkConnectionStart(connection, userOptions, true)
}

@discardableResult
func stopVPN(serviceID: String) -> Bool {
    guard let connection = vpnConnection(serviceID: serviceID) else { return false }
    return SCNetworkConnectionStop(connection, true)
}

struct SystemVPNSecrets {
    var username = ""
    var secretPlain = ""
    var secretKeychainItem = ""
    var passwordPlain = ""
    var passwordKeychainItem = ""
}

let systemConfigurationPreferences =
    URL(fileURLWithPath: "/Library/Preferences/SystemConfiguration/preferences.plist")

func readSystemVPNSecrets(serviceID: String) -> SystemVPNSecrets {
    var secrets = SystemVPNSecrets()
    guard !serviceID.isEmpty,
          let data = try? Data(contentsOf: systemConfigurationPreferences),
          let root = (try? PropertyListSerialization.propertyList(
              from: data, options: [], format: nil)) as? [String: Any],
          let services = root["NetworkServices"] as? [String: Any],
          let service = services[serviceID] as? [String: Any] else { return secrets }

    if let ipsec = service["IPSec"] as? [String: Any],
       let shared = ipsec["SharedSecret"] as? String, !shared.isEmpty {
        if (ipsec["SharedSecretEncryption"] as? String) == "Keychain" {
            secrets.secretKeychainItem = shared
        } else {
            secrets.secretPlain = shared
        }
    }
    if let ppp = service["PPP"] as? [String: Any] {
        secrets.username = ppp["AuthName"] as? String ?? ""
        if let password = ppp["AuthPassword"] as? String, !password.isEmpty {
            if (ppp["AuthPasswordEncryption"] as? String) == "Keychain" {
                secrets.passwordKeychainItem = password
            } else {
                secrets.passwordPlain = password
            }
        }
    }
    return secrets
}

struct VPNSecretImport {
    var secret = ""
    var password = ""
    var username = ""
    var cancelled = false
    var failure = ""
}

// Разовый импорт. Сначала берём то, что доступно без прав: имя пользователя и
// значения, лежащие в preferences.plist открытым текстом. За зашифрованными
// идём в System.keychain — вот это уже требует администратора, потому что ACL
// пускает к ним только системные компоненты (neagent/racoon).
// allowAdminPrompt == false — режим «молча, без единого диалога».
func importVPNSecretsFromSystem(serviceID: String, allowAdminPrompt: Bool = true) -> VPNSecretImport {
    let refs = readSystemVPNSecrets(serviceID: serviceID)
    var imported = VPNSecretImport()
    imported.username = refs.username
    imported.secret = refs.secretPlain
    imported.password = refs.passwordPlain

    let needsSecret = imported.secret.isEmpty && !refs.secretKeychainItem.isEmpty
    let needsPassword = imported.password.isEmpty && !refs.passwordKeychainItem.isEmpty
    guard allowAdminPrompt, needsSecret || needsPassword else {
        if allowAdminPrompt && imported.secret.isEmpty && refs.secretKeychainItem.isEmpty {
            imported.failure = "в конфигурации службы нет общего ключа IPSec"
        }
        return imported
    }

    // Имя элемента подставляем в одинарных кавычках, поэтому одинарную кавычку
    // внутри имени экранируем — иначе команда развалится.
    func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    // -w отдаёт только пароль, но на элементах с пустым acct он срабатывает не
    // всегда — тогда пробуем -g, который печатает `password: "…"` в stderr.
    // Код возврата и текст ошибки возвращаем наружу: без них непонятно, что
    // именно не сложилось, а гадать по пустой строке бессмысленно.
    func read(_ item: String) -> String {
        let base = "/usr/bin/security find-generic-password"
        let tail = "\(quoted(item)) /Library/Keychains/System.keychain 2>&1"
        return "out=$(\(base) -w -s \(tail)); code=$?; "
            + "if [ $code -ne 0 ]; then out=$(\(base) -g -s \(tail)); code=$?; fi; "
            + "printf '%s<<<CODE>>>%s' \"$out\" \"$code\""
    }
    let script = (needsSecret ? read(refs.secretKeychainItem) : "printf '<<<CODE>>>skip'")
        + "; printf '<<<NEXT>>>'; "
        + (needsPassword ? read(refs.passwordKeychainItem) : "printf '<<<CODE>>>skip'")
    let result = runShellAsAdmin(script)
    if result.cancelled {
        imported.cancelled = true
        return imported
    }
    guard result.ok else {
        imported.failure = result.message
        return imported
    }

    // Каждая половина выглядит как «вывод<<<CODE>>>код возврата».
    func split(_ chunk: String) -> (value: String, code: String) {
        let parts = chunk.components(separatedBy: "<<<CODE>>>")
        guard parts.count > 1 else { return (chunk, "") }
        return (parts[0], parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
    }
    // -g печатает пароль отдельной строкой вида: password: "значение"
    func value(_ raw: String) -> String {
        if let marker = raw.range(of: "password: \"") {
            let rest = raw[marker.upperBound...]
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let halves = result.output.components(separatedBy: "<<<NEXT>>>")
    if needsSecret, let first = halves.first {
        let (raw, code) = split(first)
        if code == "0" {
            imported.secret = value(raw)
        } else {
            imported.failure = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    if needsPassword, halves.count > 1 {
        let (raw, code) = split(halves[1])
        if code == "0" { imported.password = value(raw) }
    }
    if imported.secret.isEmpty && imported.failure.isEmpty {
        imported.failure = "система вернула пустой ключ"
    }
    return imported
}

func openVPNNetworkSettings() {
    let candidates = [
        "x-apple.systempreferences:com.apple.Network-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.network"
    ]
    for candidate in candidates {
        if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
            return
        }
    }
}

// MARK: - Разрешения stkh-client (TCC)

let stkhTCCClientID = "stkh-client"

struct TCCPermission {
    let label: String
    let service: String
}

// Fallback shortlist shown when TCC.db can't be read yet (no Full Disk Access) —
// these can still be revoked blind via tccutil, they just can't show a real status.
let fallbackPermissions: [TCCPermission] = [
    TCCPermission(label: "Камера", service: "Camera"),
    TCCPermission(label: "Микрофон", service: "Microphone"),
    TCCPermission(label: "Запись экрана", service: "ScreenCapture"),
    TCCPermission(label: "Универсальный доступ", service: "Accessibility"),
    TCCPermission(label: "Отслеживание ввода", service: "ListenEvent"),
]

// Maps the raw TCC.db "service" column (kTCCService... constants) to both a
// Russian label and the short form tccutil's reset command expects.
let tccServiceLabels: [String: String] = [
    "kTCCServiceCamera": "Камера",
    "kTCCServiceMicrophone": "Микрофон",
    "kTCCServiceScreenCapture": "Запись экрана",
    "kTCCServiceAccessibility": "Универсальный доступ",
    "kTCCServiceListenEvent": "Отслеживание ввода (клавиатура/мышь)",
    "kTCCServicePostEvent": "Имитация нажатий (управление другими приложениями)",
    "kTCCServiceSystemPolicyAllFiles": "Полный доступ к диску",
    "kTCCServiceSystemPolicyDesktopFolder": "Доступ к рабочему столу",
    "kTCCServiceSystemPolicyDocumentsFolder": "Доступ к документам",
    "kTCCServiceSystemPolicyDownloadsFolder": "Доступ к загрузкам",
    "kTCCServiceSystemPolicyNetworkVolumes": "Доступ к сетевым дискам",
    "kTCCServiceSystemPolicyRemovableVolumes": "Доступ к внешним дискам",
    "kTCCServiceAppleEvents": "Управление другими приложениями (AppleEvents)",
    "kTCCServiceBluetoothAlways": "Bluetooth",
    "kTCCServiceLocation": "Геолокация",
    "kTCCServiceContactsFull": "Контакты",
    "kTCCServiceCalendar": "Календарь",
    "kTCCServiceReminders": "Напоминания",
    "kTCCServicePhotos": "Фото",
    "kTCCServiceMediaLibrary": "Медиатека",
    "kTCCServiceSpeechRecognition": "Распознавание речи",
]

func tccShortServiceName(_ rawService: String) -> String {
    rawService.hasPrefix("kTCCService") ? String(rawService.dropFirst("kTCCService".count)) : rawService
}

func tccLabel(_ rawService: String) -> String {
    tccServiceLabels[rawService] ?? tccShortServiceName(rawService)
}

enum PermissionStatus {
    case allowed, denied, notRequested, unavailable
}

func runSqlite3(_ sql: String) -> String? {
    let result = runProcess("/usr/bin/sqlite3", ["/Library/Application Support/com.apple.TCC/TCC.db", sql])
    guard result.ok else { return nil }
    return result.output
}

// Discovers every TCC service stkh-client has ever been recorded for, rather
// than guessing which permissions it might use — this is the real, complete list.
func discoverStkhTCCServices() -> [String]? {
    guard let output = runSqlite3("SELECT DISTINCT service FROM access WHERE client='\(stkhTCCClientID)' ORDER BY service;") else {
        return nil
    }
    return output.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
}

func queryTCCStatus(rawService: String) -> PermissionStatus {
    guard let output = runSqlite3("SELECT auth_value FROM access WHERE service='\(rawService)' AND client='\(stkhTCCClientID)' LIMIT 1;") else {
        return .unavailable
    }
    switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "": return .notRequested
    case "0": return .denied
    case "2", "3": return .allowed
    default: return .notRequested
    }
}

func resetTCCPermission(shortServiceName: String) {
    runShellAsAdmin("/usr/bin/tccutil reset \(shortServiceName) \(stkhTCCClientID)")
}

// MARK: - Привилегированный helper: установка

// Без helper'а каждый запуск и остановка демона упираются в запрос пароля через
// `do shell script … with administrator privileges`. Для расписания это
// неприемлемо: в 18:00 нажимать «ОК» в диалоге некому. SMAppService
// регистрирует helper один раз — с одним подтверждением, — а дальше launchd
// поднимает его по обращению к Mach-сервису без всякого пароля.
enum HelperState: Equatable {
    case unsupported
    case notInstalled
    case requiresApproval
    case installed
    case outdated
    case failed(String)

    var label: String {
        switch self {
        case .unsupported: return "недоступно (нужна macOS 13+)"
        case .notInstalled: return "не установлен"
        case .requiresApproval: return "ждёт подтверждения в настройках"
        case .installed: return "установлен"
        case .outdated: return "установлена старая версия"
        case .failed(let message): return "ошибка: \(message)"
        }
    }

    var isUsable: Bool { self == .installed }
}

// Пакетный установщик кладёт helper обычным системным демоном в
// /Library/LaunchDaemons: пакет и так выполняется от root, а SMAppService
// потребовал бы от пользователя вручную включить тумблер в «Элементах входа».
// SMAppService про такой плист ничего не знает, поэтому установка и удаление
// для него идут отдельным путём — через launchctl.
let legacyHelperDaemonPath = "/Library/LaunchDaemons/\(helperPlistName)"

enum HelperManager {
    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static var isLegacyInstalled: Bool {
        FileManager.default.fileExists(atPath: legacyHelperDaemonPath)
    }

    static func state() -> HelperState {
        guard #available(macOS 13.0, *) else { return .unsupported }
        switch SMAppService.daemon(plistName: helperPlistName).status {
        case .notRegistered: return .notInstalled
        case .enabled: return .installed
        case .requiresApproval: return .requiresApproval
        // .notFound — это не «плист потерялся», а «в BackgroundTaskManagement
        // ещё нет записи о службе». Ровно это возвращается, пока helper не
        // регистрировали ни разу (проверено по логам smd: плист при этом
        // успешно разобран — «Setting up BundleProgram keys»). Для пользователя
        // случай тот же самый: helper не установлен.
        case .notFound: return .notInstalled
        @unknown default: return .failed("неизвестный статус регистрации")
        }
    }

    static func install() -> (ok: Bool, cancelled: Bool, message: String) {
        // Плист от пакета перерегистрируем через launchctl: SMAppService рядом с
        // ним поставил бы вторую службу с той же меткой.
        if isLegacyInstalled {
            let result = runShellAsAdmin(
                "/bin/launchctl bootout system/\(helperMachServiceName) >/dev/null 2>&1 || true\n"
                + "/bin/launchctl bootstrap system '\(legacyHelperDaemonPath)'")
            return (result.ok, result.cancelled, result.message)
        }
        guard #available(macOS 13.0, *) else { return (false, false, "нужна macOS 13 или новее") }
        do {
            try SMAppService.daemon(plistName: helperPlistName).register()
            return (true, false, "")
        } catch {
            // Повторная регистрация уже установленного helper'а — не ошибка.
            // Сверяемся со статусом, а не с кодом ошибки: коды SMAppService
            // между версиями системы не задокументированы.
            if state() == .installed { return (true, false, "") }
            return (false, false, (error as NSError).localizedDescription)
        }
    }

    static func uninstall() -> (ok: Bool, cancelled: Bool, message: String) {
        if isLegacyInstalled {
            let result = runShellAsAdmin(
                "/bin/launchctl bootout system/\(helperMachServiceName) >/dev/null 2>&1 || true\n"
                + "/bin/rm -f '\(legacyHelperDaemonPath)'")
            return (result.ok, result.cancelled, result.message)
        }
        guard #available(macOS 13.0, *) else { return (false, false, "нужна macOS 13 или новее") }
        do {
            try SMAppService.daemon(plistName: helperPlistName).unregister()
            return (true, false, "")
        } catch {
            if state() == .notInstalled { return (true, false, "") }
            return (false, false, (error as NSError).localizedDescription)
        }
    }

    static func openLoginItemsSettings() {
        guard #available(macOS 13.0, *) else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Привилегированный helper: вызовы по XPC

// Ответ может прийти тремя путями: от самого helper'а, от обработчика ошибок
// соединения и от сторожевого таймера. Сработать должен ровно один.
private final class SingleReply {
    private let lock = NSLock()
    private var fired = false
    private let body: (Bool, String) -> Void

    init(_ body: @escaping (Bool, String) -> Void) {
        self.body = body
    }

    func fire(_ ok: Bool, _ message: String) {
        lock.lock()
        let alreadyFired = fired
        fired = true
        lock.unlock()
        guard !alreadyFired else { return }
        body(ok, message)
    }
}

enum HelperClient {
    // launchctl bootstrap отрабатывает быстро, но на загруженной машине запуск
    // самого helper'а занимает секунды. Ждём с запасом — и всё же не вечно.
    static let callTimeout: TimeInterval = 20

    // Соединение на каждый вызов: обращения редкие (кнопка в меню и границы
    // расписания), а одноразовое соединение избавляет от возни с переподъёмом
    // после того, как launchd выгрузит простаивающий helper.
    private static func withProxy(_ completion: @escaping (Bool, String) -> Void,
                                  _ body: (StkhHelperProtocol, SingleReply) -> Void) {
        let connection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: StkhHelperProtocol.self)
        connection.resume()

        let reply = SingleReply { ok, message in
            connection.invalidate()
            DispatchQueue.main.async { completion(ok, message) }
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply.fire(false, (error as NSError).localizedDescription)
        }) as? StkhHelperProtocol else {
            reply.fire(false, "не удалось получить прокси helper'а")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + callTimeout) {
            reply.fire(false, "helper не ответил за \(Int(callTimeout)) с")
        }
        body(proxy, reply)
    }

    static func setDaemonRunning(_ shouldRun: Bool,
                                 uid: Int32,
                                 completion: @escaping (Bool, String) -> Void) {
        withProxy(completion) { proxy, reply in
            proxy.setDaemonRunning(shouldRun, uid: uid) { ok, message in
                reply.fire(ok, message)
            }
        }
    }

    static func setSharedAutostart(_ enabled: Bool,
                                   completion: @escaping (Bool, String) -> Void) {
        withProxy(completion) { proxy, reply in
            proxy.setSharedAutostart(enabled) { ok, message in
                reply.fire(ok, message)
            }
        }
    }

    // Версия нужна, чтобы поймать ситуацию «бандл обновили, а launchd всё ещё
    // держит старый helper»: снаружи она ничем другим не видна.
    static func fetchVersion(completion: @escaping (Int?) -> Void) {
        withProxy({ ok, message in
            completion(ok ? Int(message) : nil)
        }, { proxy, reply in
            proxy.fetchVersion { version in
                reply.fire(true, String(version))
            }
        })
    }
}

// MARK: - Окно настроек VPN

final class VPNSettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var servicePopup: NSPopUpButton!
    private var userField: NSTextField!
    private var passwordField: NSSecureTextField!
    private var secretField: NSSecureTextField!
    private var autoReconnectCheckbox: NSButton!
    private var services: [VPNService] = []

    var onSave: ((VPNConfig) -> Void)?

    func show(config: VPNConfig, services: [VPNService]) {
        if window == nil { buildWindow() }
        populate(config: config, services: services)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeLabel(_ text: String, y: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: 20, y: y, width: 190, height: 20)
        field.alignment = .right
        return field
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки VPN"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = window.contentView!

        servicePopup = NSPopUpButton(frame: NSRect(x: 220, y: 268, width: 300, height: 26))
        userField = NSTextField(frame: NSRect(x: 220, y: 234, width: 300, height: 24))
        passwordField = NSSecureTextField(frame: NSRect(x: 220, y: 200, width: 300, height: 24))
        secretField = NSSecureTextField(frame: NSRect(x: 220, y: 166, width: 300, height: 24))

        content.addSubview(makeLabel("Служба VPN:", y: 272))
        content.addSubview(servicePopup)
        content.addSubview(makeLabel("Пользователь:", y: 236))
        content.addSubview(userField)
        content.addSubview(makeLabel("Пароль:", y: 202))
        content.addSubview(passwordField)
        content.addSubview(makeLabel("Общий ключ:", y: 168))
        content.addSubview(secretField)

        autoReconnectCheckbox = NSButton(checkboxWithTitle: "Переподключать автоматически при обрыве",
                                         target: nil, action: nil)
        autoReconnectCheckbox.frame = NSRect(x: 220, y: 136, width: 300, height: 20)
        content.addSubview(autoReconnectCheckbox)

        let note = NSTextField(wrappingLabelWithString:
            "Пароль и общий ключ хранятся в связке ключей этого приложения и "
            + "подставляются при подключении — macOS больше не будет их спрашивать.")
        note.frame = NSRect(x: 20, y: 78, width: 500, height: 44)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        content.addSubview(note)

        let importButton = NSButton(title: "Взять ключ из системы…", target: self, action: #selector(importSecrets))
        importButton.frame = NSRect(x: 16, y: 16, width: 220, height: 32)
        importButton.bezelStyle = .rounded
        content.addSubview(importButton)

        let cancelButton = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        cancelButton.frame = NSRect(x: 330, y: 16, width: 90, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        content.addSubview(cancelButton)

        let saveButton = NSButton(title: "Сохранить", target: self, action: #selector(save))
        saveButton.frame = NSRect(x: 424, y: 16, width: 100, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        content.addSubview(saveButton)

        self.window = window
    }

    private func populate(config: VPNConfig, services: [VPNService]) {
        // L2TP наверху списка — управляем в первую очередь ими.
        self.services = services.sorted { $0.isL2TP && !$1.isL2TP }
        servicePopup.removeAllItems()
        if self.services.isEmpty {
            servicePopup.addItem(withTitle: "Службы VPN не найдены")
            servicePopup.isEnabled = false
        } else {
            servicePopup.isEnabled = true
            for service in self.services {
                servicePopup.addItem(withTitle: service.menuTitle)
            }
            let selected = resolveVPNService(config: config, services: self.services)
            if let index = self.services.firstIndex(where: { $0.id == selected?.id }) {
                servicePopup.selectItem(at: index)
            }
        }
        userField.stringValue = config.username.isEmpty
            ? vpnConfiguredUsername(serviceID: selectedServiceID() ?? "")
            : config.username
        passwordField.stringValue = config.password
        secretField.stringValue = config.sharedSecret
        autoReconnectCheckbox.state = config.autoReconnectEnabled ? .on : .off
    }

    private func selectedServiceID() -> String? {
        let index = servicePopup.indexOfSelectedItem
        guard index >= 0 && index < services.count else { return nil }
        return services[index].id
    }

    private func selectedService() -> VPNService? {
        let index = servicePopup.indexOfSelectedItem
        guard index >= 0 && index < services.count else { return nil }
        return services[index]
    }

    @objc private func importSecrets() {
        guard let serviceID = selectedServiceID() else { return }
        let imported = importVPNSecretsFromSystem(serviceID: serviceID)
        if !imported.secret.isEmpty { secretField.stringValue = imported.secret }
        if !imported.password.isEmpty { passwordField.stringValue = imported.password }
        if userField.stringValue.isEmpty { userField.stringValue = imported.username }
        guard imported.secret.isEmpty, !imported.cancelled else { return }
        let alert = NSAlert()
        alert.messageText = "Не удалось прочитать ключ из системы"
        alert.informativeText = (imported.failure.isEmpty ? "" : "Причина: \(imported.failure)\n\n")
            + "macOS ограничивает доступ к общему ключу VPN в системной связке ключей — "
            + "прочитать его может только сама система. Введите ключ вручную в поле «Общий ключ»: "
            + "он сохранится в приложении и дальше будет подставляться автоматически."
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func save() {
        var config = VPNConfig()
        if let service = selectedService() {
            config.serviceID = service.id
            config.serviceName = service.name
        }
        config.username = userField.stringValue.trimmingCharacters(in: .whitespaces)
        config.password = passwordField.stringValue
        config.sharedSecret = secretField.stringValue
        config.autoReconnect = autoReconnectCheckbox.state == .on
        onSave?(config)
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

// MARK: - Приложение

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var running = false
    var vpnHostReachable = false
    var refreshInFlight = false
    let uid = getuid()

    var vpnConfig = VPNConfig()
    var vpnServices: [VPNService] = []
    var vpnService: VPNService?
    var vpnTunnelState: VPNState = .unknown
    // Ручное отключение не должно тут же отменяться автопереподключением.
    var vpnStoppedByUser = false
    var lastAutoConnectAttempt = Date.distantPast
    var vpnReconnectAttempts = 0
    var vpnReconnectGaveUp = false

    var schedule = DaemonSchedule()
    // nil означает «расписание ещё ни разу не вычислялось в этом запуске».
    // Именно по переходу этого значения принимается решение действовать, см.
    // applyScheduleIfNeeded.
    var lastScheduleDesired: Bool?
    var scheduleLastError: String?
    var daemonCommandInFlight = false
    let automationSettings = AutomationSettingsController()

    var helperState: HelperState = .notInstalled
    var helperVersionMismatch = false
    // Счётчик опросов: helper переспрашиваем реже, чем всё остальное.
    var refreshTicks = 0

    // Активен ли сеанс, в котором мы работаем (не переключились ли на другого
    // пользователя). Автоподключение VPN ведёт только активный экземпляр.
    var isForegroundSession = true
    var sharedAutostart = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        sharedAutostart = isSharedAutostartEnabled()
        if !isRunningFromMountedDMG() {
            if sharedAutostart {
                // Системный агент уже запускает приложение в каждом сеансе.
                // Пер-юзерный плист при этом только вредит: при входе launchd
                // стартовал бы приложение дважды, и второй экземпляр молча
                // завершался бы, обнаружив первый.
                if isLaunchAgentUpToDate() { removeLaunchAgent() }
            } else if !isLaunchAgentUpToDate() {
                installLaunchAgent()
            }
        }
        vpnConfig = VPNConfigStore.load()
        schedule = DaemonScheduleStore.load()
        refreshHelperState()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    // После сна туннель почти всегда мёртв, а сеть поднимается не мгновенно.
    // Счётчик обнуляем: это новая серия попыток, а не продолжение прежней.
    @objc func systemDidWake() {
        vpnReconnectAttempts = 0
        vpnReconnectGaveUp = false
        lastAutoConnectAttempt = Date()
        refreshStatus()
    }

    func refreshStatus() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let config = vpnConfig
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let daemonRunning = isDaemonRunning()
            let hostUp = pingHost(vpnHost)
            let services = listVPNServices()
            let service = resolveVPNService(config: config, services: services)
            let state = service.map { vpnState(serviceID: $0.id) } ?? .invalid
            let foreground = isConsoleSession()
            let shared = isSharedAutostartEnabled()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = daemonRunning
                self.vpnHostReachable = hostUp
                self.vpnServices = services
                self.vpnService = service
                self.vpnTunnelState = state
                self.isForegroundSession = foreground
                self.sharedAutostart = shared
                self.refreshInFlight = false
                // Helper дёргаем раз в полминуты: его состояние меняется редко,
                // но меняться может и снаружи — например, другой пользователь
                // установил или удалил его, пока мы висим в фоне.
                self.refreshTicks += 1
                if self.refreshTicks % 6 == 1 { self.refreshHelperState() }
                if state == .connected { self.vpnStoppedByUser = false }
                // Порядок важен: сначала обновляем счётчик попыток, потом рисуем
                // меню — иначе в нём будет состояние предыдущего опроса.
                self.autoReconnectIfNeeded()
                self.applyScheduleIfNeeded()
                self.updateIcon()
                self.buildMenu()
            }
        }
    }

    func autoReconnectIfNeeded() {
        // В фоновом сеансе туннель не трогаем: VPN один на всю машину, и
        // поднимать его наперекор пользователю, который сидит за экраном и
        // только что отключил его вручную, нельзя. Расписание демона при этом
        // продолжает работать в любом сеансе — оно у каждого пользователя своё.
        guard isForegroundSession else { return }
        guard vpnConfig.autoReconnectEnabled, let service = vpnService else { return }
        switch vpnTunnelState {
        case .connected:
            // Связь есть — следующую серию попыток начинаем с чистого листа.
            vpnReconnectAttempts = 0
            vpnReconnectGaveUp = false
        case .connecting, .disconnecting:
            // Идёт рукопожатие: молча ждём следующего опроса, чтобы не сбить его.
            break
        case .disconnected:
            guard !vpnStoppedByUser, !vpnReconnectGaveUp else { return }
            // Хост уже доступен (например, туннель на самом деле поднялся, а
            // scutil ещё не обновил статус, либо есть другой путь до сервера) —
            // незачем дёргать переподключение и жечь оставшиеся попытки.
            guard !vpnHostReachable else {
                vpnReconnectAttempts = 0
                vpnReconnectGaveUp = false
                return
            }
            guard Date().timeIntervalSince(lastAutoConnectAttempt) >= vpnReconnectDelay else { return }
            guard vpnReconnectAttempts < vpnMaxReconnectAttempts else {
                vpnReconnectGaveUp = true
                return
            }
            vpnReconnectAttempts += 1
            connect(service: service)
        case .invalid, .unknown:
            // Службы фактически нет либо scutil не ответил — поднимать нечего.
            break
        }
    }

    // Единая точка подключения: и для кнопки в меню, и для автопереподключения.
    // Ключ подставляем прямо здесь, до вызова scutil.
    func connect(service: VPNService) {
        lastAutoConnectAttempt = Date()
        let config = vpnConfig
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            startVPN(config, serviceID: service.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.refreshStatus()
            }
        }
    }

    func updateIcon() {
        let symbolName = running ? "eye.fill" : "eye.slash"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "stkh-client status")
        image?.isTemplate = true
        statusItem.button?.image = image
        let vpnName = vpnService?.name ?? "не найден"
        statusItem.button?.toolTip = "stkh-client: \(running ? "запущен" : "остановлен")\n"
            + "VPN «\(vpnName)»: \(vpnTunnelState.label)\n"
            + "\(vpnHost): \(vpnHostReachable ? "доступен" : "нет связи")"
    }

    func coloredMenuItem(label: String, word: String, color: NSColor) -> NSMenuItem {
        let text = "\(label): \(word)"
        let attributed = NSMutableAttributedString(string: text)
        let wordRange = (text as NSString).range(of: word)
        attributed.addAttribute(.foregroundColor, value: color, range: wordRange)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = attributed
        item.isEnabled = false
        return item
    }

    func statusMenuItem(label: String, isUp: Bool) -> NSMenuItem {
        let word = isUp ? "подключено" : "нет связи"
        let color = isUp ? NSColor.systemGreen : NSColor.systemRed
        return coloredMenuItem(label: label, word: word, color: color)
    }

    func permissionMenuItem(label: String, status: PermissionStatus) -> NSMenuItem {
        switch status {
        case .allowed:
            return coloredMenuItem(label: label, word: "разрешено", color: .systemGreen)
        case .denied:
            return coloredMenuItem(label: label, word: "запрещено", color: .systemRed)
        case .notRequested:
            return coloredMenuItem(label: label, word: "не запрошено", color: .secondaryLabelColor)
        case .unavailable:
            return coloredMenuItem(label: label, word: "неизвестно (нужен Full Disk Access)", color: .secondaryLabelColor)
        }
    }

    func addPermissionRow(to permMenu: NSMenu, label: String, shortServiceName: String, status: PermissionStatus) {
        permMenu.addItem(permissionMenuItem(label: label, status: status))
        // Only offer to revoke when we know there's actually something granted —
        // for .unavailable (status unknown) we still offer it blind, since that's
        // the only way to act without Full Disk Access.
        guard status == .allowed || status == .unavailable else { return }
        let resetItem = NSMenuItem(title: "Отозвать: \(label)", action: #selector(revokePermission(_:)), keyEquivalent: "")
        resetItem.target = self
        resetItem.representedObject = shortServiceName
        permMenu.addItem(resetItem)
    }

    func buildPermissionsMenu() -> NSMenu {
        let permMenu = NSMenu()

        if let discovered = discoverStkhTCCServices() {
            if discovered.isEmpty {
                let noneItem = NSMenuItem(title: "Нет зафиксированных запросов разрешений", action: nil, keyEquivalent: "")
                noneItem.isEnabled = false
                permMenu.addItem(noneItem)
            } else {
                for rawService in discovered {
                    let status = queryTCCStatus(rawService: rawService)
                    addPermissionRow(to: permMenu, label: tccLabel(rawService), shortServiceName: tccShortServiceName(rawService), status: status)
                }
            }
        } else {
            let hintItem = NSMenuItem(title: "Полный список недоступен без Full Disk Access — показан частичный", action: nil, keyEquivalent: "")
            hintItem.isEnabled = false
            permMenu.addItem(hintItem)
            permMenu.addItem(NSMenuItem.separator())
            for perm in fallbackPermissions {
                addPermissionRow(to: permMenu, label: perm.label, shortServiceName: perm.service, status: .unavailable)
            }
            permMenu.addItem(NSMenuItem.separator())
            let fdaItem = NSMenuItem(title: "Открыть Full Disk Access…", action: #selector(openFullDiskAccessSettings), keyEquivalent: "")
            fdaItem.target = self
            permMenu.addItem(fdaItem)
        }

        return permMenu
    }

    func addVPNSection(to menu: NSMenu) {
        guard let service = vpnService else {
            let noneItem = NSMenuItem(title: "VPN L2TP не найден в системе", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
            let settingsItem = NSMenuItem(title: "Открыть настройки сети…", action: #selector(openNetworkSettingsAction), keyEquivalent: "")
            settingsItem.target = self
            menu.addItem(settingsItem)
            return
        }

        menu.addItem(coloredMenuItem(label: "VPN «\(service.name)»",
                                     word: vpnTunnelState.label,
                                     color: vpnTunnelState.color))

        let isConnected = vpnTunnelState == .connected
        let toggleItem = NSMenuItem(
            title: isConnected ? "Отключить VPN" : "Подключить VPN",
            action: #selector(toggleVPN),
            keyEquivalent: ""
        )
        toggleItem.target = self
        // Во время рукопожатия команда всё равно ничего не сделает — не мигаем кнопкой.
        toggleItem.isEnabled = !vpnTunnelState.isBusy
        menu.addItem(toggleItem)

        if !isForegroundSession {
            menu.addItem(disabledMenuItem("Фоновый сеанс — VPN ведёт активный пользователь"))
        } else if vpnConfig.autoReconnectEnabled && vpnTunnelState != .connected && !vpnStoppedByUser {
            let title: String
            if vpnReconnectGaveUp {
                title = "Автоподключение остановлено после \(vpnMaxReconnectAttempts) попыток"
            } else if vpnReconnectAttempts > 0 {
                title = "Переподключение: попытка \(vpnReconnectAttempts) из \(vpnMaxReconnectAttempts)"
            } else {
                title = "Автопереподключение включено"
            }
            let stateItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            stateItem.isEnabled = false
            menu.addItem(stateItem)
        }
    }

    func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func describeTransition(_ transition: ScheduleTransition) -> String {
        let calendar = Calendar.current
        let action = transition.starts ? "Запуск" : "Остановка"
        let day: String
        if calendar.isDateInToday(transition.date) {
            day = "сегодня"
        } else if calendar.isDateInTomorrow(transition.date) {
            day = "завтра"
        } else {
            day = weekdayShortNames[calendar.component(.weekday, from: transition.date)] ?? ""
        }
        return "\(action) \(day) в \(formatTimeOfDay(minutes: minutesOfDay(transition.date)))"
    }

    func addScheduleSection(to menu: NSMenu) {
        guard schedule.isActive else {
            menu.addItem(disabledMenuItem("Автоматика выключена"))
            return
        }

        menu.addItem(disabledMenuItem("Расписание: \(describeSchedule(schedule))"))

        if schedule.hasBreak {
            let title = schedule.breakInsideWorkWindow
                ? describeBreak(schedule).capitalizedFirst
                : "\(describeBreak(schedule).capitalizedFirst) — вне рабочего времени"
            menu.addItem(disabledMenuItem(title))
        }

        let desired = scheduleDesiredRunning(schedule, at: Date())
        menu.addItem(coloredMenuItem(label: "Сейчас по расписанию",
                                     word: desired ? "запущен" : "остановлен",
                                     color: desired ? .systemGreen : .secondaryLabelColor))

        if let transition = nextScheduleTransition(schedule, after: Date()) {
            menu.addItem(disabledMenuItem(describeTransition(transition)))
        }

        // Расхождение видно только здесь: сама иконка показывает фактическое
        // состояние и о расписании ничего не знает.
        if running != desired {
            let item = coloredMenuItem(label: "Фактически",
                                       word: running ? "запущен" : "остановлен",
                                       color: .systemOrange)
            menu.addItem(item)
        }

        if let error = scheduleLastError, !error.isEmpty {
            menu.addItem(coloredMenuItem(label: "Последняя попытка", word: error, color: .systemRed))
        }
    }

    func addHelperSection(to menu: NSMenu) {
        guard HelperManager.isSupported else {
            menu.addItem(disabledMenuItem("Без пароля: нужна macOS 13 или новее"))
            return
        }

        let color: NSColor
        switch helperState {
        case .installed: color = .systemGreen
        case .requiresApproval, .outdated: color = .systemOrange
        default: color = .secondaryLabelColor
        }
        menu.addItem(coloredMenuItem(label: "Запуск без пароля", word: helperState.label, color: color))

        switch helperState {
        case .installed:
            let removeItem = NSMenuItem(title: "Удалить helper", action: #selector(uninstallHelper), keyEquivalent: "")
            removeItem.target = self
            menu.addItem(removeItem)
        case .requiresApproval:
            let openItem = NSMenuItem(title: "Открыть «Элементы входа»…", action: #selector(openHelperSettings), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)
        case .outdated:
            let updateItem = NSMenuItem(title: "Обновить helper…", action: #selector(installHelper), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        default:
            let installItem = NSMenuItem(title: "Установить helper…", action: #selector(installHelper), keyEquivalent: "")
            installItem.target = self
            menu.addItem(installItem)
        }
    }

    func buildAutomationMenu() -> NSMenu {
        let menu = NSMenu()
        // По умолчанию NSMenu включает любой пункт, у которого есть цель и
        // действие, перебивая выставленный вручную isEnabled. Здесь это
        // помешало бы гасить «Применить расписание сейчас» на время выполнения
        // команды, поэтому берём управление на себя.
        menu.autoenablesItems = false

        let loginItem = NSMenuItem(title: "Запускать приложение при входе",
                                   action: #selector(toggleAutostart),
                                   keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (sharedAutostart || isLaunchAgentUpToDate()) ? .on : .off
        // При общем автозапуске переключать нечего: плист лежит в системной
        // папке и относится ко всем сразу.
        loginItem.isEnabled = !sharedAutostart
        menu.addItem(loginItem)

        let sharedItem = NSMenuItem(title: "Запускать у всех пользователей",
                                    action: #selector(toggleSharedAutostart),
                                    keyEquivalent: "")
        sharedItem.target = self
        sharedItem.state = sharedAutostart ? .on : .off
        sharedItem.isEnabled = sharedAutostart || isSharedInstallLocation(currentExecutablePath())
        menu.addItem(sharedItem)

        if !isSharedInstallLocation(currentExecutablePath()) {
            menu.addItem(disabledMenuItem("Для этого приложение должно лежать в «Программах»"))
        } else if !sharedAutostart {
            menu.addItem(disabledMenuItem("Иначе иконки не будет у других пользователей"))
        }

        menu.addItem(NSMenuItem.separator())

        addScheduleSection(to: menu)

        let settingsItem = NSMenuItem(title: "Настроить автоматизацию…",
                                      action: #selector(openAutomationSettings),
                                      keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if schedule.isActive {
            let applyItem = NSMenuItem(title: "Применить расписание сейчас",
                                       action: #selector(applyScheduleNow),
                                       keyEquivalent: "")
            applyItem.target = self
            applyItem.isEnabled = !daemonCommandInFlight
            menu.addItem(applyItem)
        }

        menu.addItem(NSMenuItem.separator())

        addHelperSection(to: menu)

        return menu
    }

    func buildMenu() {
        let menu = NSMenu()

        let daemonText = running ? "stkh-client: запущен" : "stkh-client: остановлен"
        let daemonItem = NSMenuItem(title: daemonText, action: nil, keyEquivalent: "")
        daemonItem.isEnabled = false
        menu.addItem(daemonItem)

        menu.addItem(statusMenuItem(label: vpnHost, isUp: vpnHostReachable))

        // Строка в шапке, а не только в подменю: включённое расписание само
        // останавливает демона, и не видя этого сразу, остановку легко принять
        // за сбой.
        menu.addItem(coloredMenuItem(label: "Автоматизация",
                                     word: schedule.isActive ? "включена" : "выключена",
                                     color: schedule.isActive ? .systemGreen : .secondaryLabelColor))

        menu.addItem(NSMenuItem.separator())

        addVPNSection(to: menu)

        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(
            title: running ? "Остановить" : "Запустить",
            action: #selector(toggleDaemon),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        let permSubmenuItem = NSMenuItem(title: "Разрешения (stkh-client)", action: nil, keyEquivalent: "")
        permSubmenuItem.submenu = buildPermissionsMenu()
        menu.addItem(permSubmenuItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Обновить сейчас", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        if isRunningFromMountedDMG() {
            let warnItem = NSMenuItem(title: "Скопируйте в Applications для автозапуска", action: nil, keyEquivalent: "")
            warnItem.isEnabled = false
            menu.addItem(warnItem)
        } else {
            let automationItem = NSMenuItem(title: "Автоматизация", action: nil, keyEquivalent: "")
            automationItem.submenu = buildAutomationMenu()
            menu.addItem(automationItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func manualRefresh() {
        vpnConfig = VPNConfigStore.load()
        refreshHelperState()
        refreshStatus()
    }

    @objc func toggleVPN() {
        guard let service = vpnService else { return }
        let shouldStop = vpnTunnelState == .connected
        vpnStoppedByUser = shouldStop
        // Любое действие руками — это новая серия попыток.
        vpnReconnectAttempts = 0
        vpnReconnectGaveUp = false
        guard shouldStop else {
            connect(service: service)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            stopVPN(serviceID: service.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.refreshStatus()
            }
        }
    }

    @objc func openNetworkSettingsAction() {
        openVPNNetworkSettings()
    }

    @objc func revokePermission(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? String else { return }
        resetTCCPermission(shortServiceName: service)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.buildMenu()
        }
    }

    @objc func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleAutostart() {
        if isLaunchAgentUpToDate() {
            removeLaunchAgent()
        } else {
            installLaunchAgent()
        }
        buildMenu()
    }

    // Автозапуск для всех: системный плист в /Library/LaunchAgents, который
    // launchd грузит в каждый графический сеанс. Пишем его от root — через
    // helper молча, без helper'а с запросом пароля.
    @objc func toggleSharedAutostart() {
        let enable = !sharedAutostart
        let executable = currentExecutablePath()
        guard !enable || isSharedInstallLocation(executable) else {
            let alert = NSAlert()
            alert.messageText = "Приложение запущено не из папки «Программы»"
            alert.informativeText =
                "Чтобы иконка появлялась у всех пользователей, приложение должно лежать в "
                + "/Applications: домашняя папка одного пользователя другим недоступна, и запустить "
                + "приложение оттуда система не сможет.\n\nСкопируйте StkhMonitor.app в «Программы», "
                + "запустите его оттуда и включите переключатель снова."
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        let finish: (Bool, String) -> Void = { [weak self] ok, message in
            guard let self = self else { return }
            self.sharedAutostart = isSharedAutostartEnabled()
            if self.sharedAutostart {
                // Пер-юзерный плист рядом с системным приводит к двойному
                // запуску при входе — убираем его сразу.
                if isLaunchAgentUpToDate() { removeLaunchAgent() }
            } else if !isLaunchAgentUpToDate() {
                // Общий автозапуск сняли — возвращаем свой, иначе приложение
                // перестало бы запускаться при входе вообще.
                installLaunchAgent()
            }
            self.buildMenu()
            guard !ok else { return }
            let alert = NSAlert()
            alert.messageText = enable
                ? "Не удалось включить запуск у всех пользователей"
                : "Не удалось выключить запуск у всех пользователей"
            alert.informativeText = message.isEmpty ? "Система не сообщила причину." : message
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }

        guard !helperState.isUsable else {
            HelperClient.setSharedAutostart(enable, completion: finish)
            return
        }
        let commands = sharedAutostartCommands(enabled: enable,
                                               executablePath: executable,
                                               uids: daemonSessionUIDs())
        guard !commands.isEmpty else {
            finish(false, "не удалось собрать плист автозапуска")
            return
        }
        let result = runShellAsAdmin(adminScript(for: commands))
        // Отмена запроса пароля — не ошибка: молча оставляем как было.
        guard !result.cancelled else { return }
        finish(result.ok, result.message)
    }

    // MARK: - Управление демоном

    // Единственная точка запуска и остановки: и кнопка в меню, и расписание
    // ходят сюда. Через helper — молча, без helper'а — со старым запросом
    // пароля, чтобы приложение оставалось работоспособным до его установки и
    // на macOS 12.
    func setDaemonRunning(_ shouldRun: Bool, completion: ((DaemonCommandOutcome) -> Void)? = nil) {
        guard !daemonCommandInFlight else {
            completion?(DaemonCommandOutcome(ok: false, cancelled: false,
                                             message: "предыдущая команда ещё выполняется",
                                             usedHelper: false))
            return
        }
        daemonCommandInFlight = true
        let finish: (DaemonCommandOutcome) -> Void = { [weak self] outcome in
            guard let self = self else { return }
            self.daemonCommandInFlight = false
            completion?(outcome)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refreshStatus()
            }
        }

        guard helperState.isUsable else {
            // NSAppleScript показывает модальный диалог и блокирует поток, на
            // котором выполняется, поэтому запасной путь остаётся на главном.
            let commands = daemonControlCommands(shouldRun: shouldRun, uids: daemonSessionUIDs())
            let result = runShellAsAdmin(adminScript(for: commands))
            finish(DaemonCommandOutcome(ok: result.ok, cancelled: result.cancelled,
                                        message: result.message, usedHelper: false))
            return
        }

        HelperClient.setDaemonRunning(shouldRun, uid: Int32(uid)) { ok, message in
            finish(DaemonCommandOutcome(ok: ok, cancelled: false, message: message, usedHelper: true))
        }
    }

    @objc func toggleDaemon() {
        let desired = !running
        setDaemonRunning(desired)
        // Ручное переключение внутри окна расписания не должно откатываться
        // назад на следующем же опросе: считаем, что расписание уже применено
        // к этому состоянию.
        if schedule.isActive { lastScheduleDesired = scheduleDesiredRunning(schedule, at: Date()) }
    }

    // MARK: - Расписание

    func applyScheduleIfNeeded() {
        guard schedule.isActive else {
            lastScheduleDesired = nil
            return
        }
        let desired = scheduleDesiredRunning(schedule, at: Date())
        let previous = lastScheduleDesired
        lastScheduleDesired = desired

        // Действуем только на границе окна — и один раз при запуске приложения
        // (previous == nil). Иначе остановленный вручную демон поднимался бы
        // обратно через пять секунд, а при отменённом запросе пароля диалог
        // всплывал бы бесконечно.
        guard previous != desired else { return }
        guard running != desired, !daemonCommandInFlight else { return }

        setDaemonRunning(desired) { [weak self] outcome in
            guard let self = self else { return }
            if outcome.ok {
                self.scheduleLastError = nil
            } else if outcome.cancelled {
                self.scheduleLastError = "запрос пароля отменён в \(formatTimeOfDay(minutes: minutesOfDay(Date())))"
            } else {
                self.scheduleLastError = outcome.message
            }
        }
    }

    @objc func openAutomationSettings() {
        automationSettings.onSave = { [weak self] schedule in
            guard let self = self else { return }
            self.schedule = schedule
            DaemonScheduleStore.save(schedule)
            // Новое расписание применяем сразу, не дожидаясь ближайшей границы:
            // сбрасываем «предыдущее» состояние, и следующий опрос сработает
            // как переход.
            self.lastScheduleDesired = nil
            self.scheduleLastError = nil
            self.refreshStatus()
        }
        automationSettings.show(schedule: schedule)
    }

    @objc func applyScheduleNow() {
        guard schedule.isActive else { return }
        lastScheduleDesired = nil
        scheduleLastError = nil
        applyScheduleIfNeeded()
        buildMenu()
    }

    // MARK: - Helper

    func refreshHelperState() {
        let registration = HelperManager.state()
        helperState = registration
        guard HelperManager.isSupported else {
            helperVersionMismatch = false
            return
        }
        // Живой helper опрашиваем всегда, а не только когда SMAppService
        // отчитался об установке. Helper — системный демон: его один раз
        // регистрирует администратор, а работает он для всех пользователей.
        // У второго пользователя (тем более без прав администратора)
        // SMAppService вполне может сказать «не зарегистрирован», хотя
        // Mach-сервис отвечает и остановить демона через него можно без пароля.
        // Ответ самого helper'а тут — источник правды, статус регистрации нет.
        HelperClient.fetchVersion { [weak self] version in
            guard let self = self else { return }
            if let version = version {
                self.helperVersionMismatch = version != helperProtocolVersion
                self.helperState = self.helperVersionMismatch ? .outdated : .installed
            } else {
                self.helperVersionMismatch = false
                // Helper не ответил. Если система считает его
                // зарегистрированным — это не «не установлен», а поломка, и
                // показать её надо честно: команды пойдут через запрос пароля.
                self.helperState = registration == .installed ? .failed("не отвечает") : registration
            }
            self.buildMenu()
        }
    }

    // Куда идти пользователю. Раздел лежит не в «Конфиденциальности», как
    // подсказывает интуиция, а в «Основных» — и называется по-разному в разных
    // версиях системы, поэтому перечисляем оба варианта.
    var backgroundApprovalPath: String {
        if #available(macOS 14.0, *) {
            return "Системные настройки → Основные → Элементы входа и расширения → "
                + "раздел «Разрешить в фоновом режиме»"
        }
        return "Системные настройки → Основные → Элементы входа → раздел «Разрешить в фоновом режиме»"
    }

    func showBackgroundApprovalAlert(title: String, reason: String) {
        let alert = NSAlert()
        alert.messageText = title
        var text = "Включите переключатель StkhMonitor:\n\n\(backgroundApprovalPath)\n\n"
            + "Если StkhMonitor в списке есть, но выключен — включите его. Если он там числится "
            + "дважды или помечен как «не определено», удалите старую запись кнопкой «−» и нажмите "
            + "«Установить helper…» ещё раз.\n\n"
            // Разделение двух совершенно разных причин с одинаковым текстом ошибки:
            // ждать разрешения имеет смысл, только если система вообще приняла
            // регистрацию и показала службу в списке.
            + "Если StkhMonitor в списке не появился вовсе, дело не в разрешении: система не "
            + "приняла регистрацию. Тогда проверьте, что приложение лежит в папке «Программы» и "
            + "запущено именно оттуда, а не из образа диска или папки сборки.\n\n"
            + "Пока helper не разрешён, запуск и остановка stkh-client будут спрашивать пароль "
            + "администратора, а расписание будет срабатывать только при вас."
        if !reason.isEmpty {
            text += "\n\nОтвет системы: \(reason)"
        }
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        // Приложение живёт без иконки в Dock, поэтому без явной активации
        // окно предупреждения может уехать за чужие окна.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            HelperManager.openLoginItemsSettings()
        }
    }

    @objc func installHelper() {
        let result = HelperManager.install()
        refreshHelperState()
        buildMenu()

        // Отмена запроса пароля — не сбой: молча оставляем как было.
        if result.cancelled { return }

        if result.ok {
            // Регистрация прошла, но система может ждать тумблера в списке
            // фоновых программ — тогда объясняем, где он.
            if HelperManager.state() == .requiresApproval {
                showBackgroundApprovalAlert(title: "Осталось разрешить работу в фоне", reason: "")
            }
            return
        }

        // «Operation not permitted» здесь почти всегда означает не поломку, а
        // именно неразрешённую фоновую работу: система регистрирует службу, но
        // держит её выключенной до подтверждения пользователем.
        let looksLikeApproval = helperState == .requiresApproval
            || result.message.localizedCaseInsensitiveContains("not permitted")
            || result.message.localizedCaseInsensitiveContains("не разрешена")
        if looksLikeApproval {
            showBackgroundApprovalAlert(title: "Требуется разрешение на работу в фоне",
                                        reason: result.message)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Не удалось установить helper"
        alert.informativeText = result.message + "\n\n"
            + "Без helper'а запуск и остановка stkh-client продолжат запрашивать пароль администратора. "
            + "Чаще всего мешает одно из двух: приложение запущено не из папки «Программы» "
            + "или его подпись изменилась после установки helper'а.\n\n"
            + "Разрешения на фоновую работу: \(backgroundApprovalPath)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Закрыть")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            HelperManager.openLoginItemsSettings()
        }
    }

    @objc func uninstallHelper() {
        let result = HelperManager.uninstall()
        refreshHelperState()
        buildMenu()
        guard !result.ok, !result.cancelled else { return }
        let alert = NSAlert()
        alert.messageText = "Не удалось удалить helper"
        alert.informativeText = result.message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc func openHelperSettings() {
        HelperManager.openLoginItemsSettings()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
