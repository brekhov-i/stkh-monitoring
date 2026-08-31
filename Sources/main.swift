import Cocoa

let targetPath = "/usr/local/libexec/stkh-client.app/Contents/MacOS/stkh-client"
let daemonLabel = "stkh-client-daemon"
let agentLabel = "stkh-client-agent"
let daemonPlist = "/Library/LaunchDaemons/\(daemonLabel).plist"
let agentPlist = "/Library/LaunchAgents/\(agentLabel).plist"

func isDaemonRunning() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", "^\(targetPath)"]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        return false
    }
}

let vpnHost = "guard.profit.local"

func pingHost(_ host: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/sbin/ping")
    task.arguments = ["-c", "1", "-t", "2", host]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        return false
    }
}

@discardableResult
func runShellAsAdmin(_ script: String) -> Bool {
    let escaped = script
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
    var error: NSDictionary?
    if let scriptObject = NSAppleScript(source: appleScript) {
        scriptObject.executeAndReturnError(&error)
    }
    return error == nil
}

let launchAgentLabel = "com.ilya.stkhmonitor"

func launchAgentPlistURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
}

func currentExecutablePath() -> String {
    Bundle.main.executablePath ?? CommandLine.arguments[0]
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
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = arguments
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    try? task.run()
    task.waitUntilExit()
}

func installLaunchAgent() {
    let url = launchAgentPlistURL()
    let plistDict: [String: Any] = [
        "Label": launchAgentLabel,
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
    let uid = getuid()
    runLaunchctl(["bootout", "gui/\(uid)/\(launchAgentLabel)"])
}

func removeLaunchAgent() {
    let uid = getuid()
    runLaunchctl(["bootout", "gui/\(uid)/\(launchAgentLabel)"])
    try? FileManager.default.removeItem(at: launchAgentPlistURL())
}

func isAnotherInstanceRunning() -> Bool {
    let myPid = ProcessInfo.processInfo.processIdentifier
    let path = currentExecutablePath()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", "^\(path)$"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        return false
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    let pids = output.split(separator: "\n").compactMap { Int32($0) }
    return pids.contains { $0 != myPid }
}

// scutil --nc start can't complete this VPN's IPSec handshake: the shared
// secret in the System keychain has an ACL that only allows Apple-signed
// system processes (neagent, pppd, racoon, the Network Settings extension,
// etc.) to read it — no third-party process, signed or not, can pass that
// check. So instead of a broken one-click "reconnect", just get the user to
// the right pane; the actual Connect click still has to be theirs.
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
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    task.arguments = ["/Library/Application Support/com.apple.TCC/TCC.db", sql]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
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

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var running = false
    var vpnConnected = false
    var refreshInFlight = false
    let uid = getuid()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if !isRunningFromMountedDMG() && !isLaunchAgentUpToDate() {
            installLaunchAgent()
        }
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func refreshStatus() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let daemonRunning = isDaemonRunning()
            let vpnUp = pingHost(vpnHost)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = daemonRunning
                self.vpnConnected = vpnUp
                self.refreshInFlight = false
                self.updateIcon()
                self.buildMenu()
            }
        }
    }

    func updateIcon() {
        let symbolName = running ? "eye.fill" : "eye.slash"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "stkh-client status")
        image?.isTemplate = true
        statusItem.button?.image = image
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

    func buildMenu() {
        let menu = NSMenu()

        let daemonText = running ? "stkh-client: запущен" : "stkh-client: остановлен"
        let statusMenuItem = NSMenuItem(title: daemonText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(self.statusMenuItem(label: vpnHost, isUp: vpnConnected))

        let reconnectItem = NSMenuItem(title: "Открыть настройки VPN…", action: #selector(openVPNSettingsAction), keyEquivalent: "")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

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
            let autostartItem = NSMenuItem(title: "Автозапуск при входе", action: #selector(toggleAutostart), keyEquivalent: "")
            autostartItem.target = self
            autostartItem.state = isLaunchAgentUpToDate() ? .on : .off
            menu.addItem(autostartItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func manualRefresh() {
        refreshStatus()
    }

    @objc func openVPNSettingsAction() {
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

    @objc func toggleDaemon() {
        let script = running ? """
        launchctl bootout system/\(daemonLabel) >/dev/null 2>&1
        launchctl bootout gui/\(uid)/\(agentLabel) >/dev/null 2>&1
        pkill -9 -f '\(targetPath)' >/dev/null 2>&1
        true
        """ : """
        launchctl bootstrap system \(daemonPlist) >/dev/null 2>&1
        launchctl bootstrap gui/\(uid) \(agentPlist) >/dev/null 2>&1
        true
        """
        runShellAsAdmin(script)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStatus()
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
