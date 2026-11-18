import AppKit
import DesktopInstallation
import Foundation
import GatewayCore
import UniformTypeIdentifiers

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
private final class Launcher: NSObject, NSApplicationDelegate {
    private struct ProxyConfiguration: Codable {
        let original: Data
        let active: Data
    }

    private let files = FileManager.default
    private let workspace = NSWorkspace.shared
    private weak var chatGPTCheckbox: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            do {
                try await start()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
            NSApp.terminate(nil)
        }
    }

    private func start() async throws {
        let home = files.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        guard let bundle = try await prepareDesktop(in: home) else { return }

        if let running = workspace.runningApplications.first(where: {
            $0.bundleURL?.resolvingSymlinksInPath() == bundle.resolvingSymlinksInPath()
        }) {
            running.activate()
            return
        }

        guard let (address, secret, contextWindow, excludeGPT, includeChatGPT) = promptForGateway() else { return }
        let gateway = try Gateway(address)
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try gateway.modelRequest(key: key)
        let profile = home.appendingPathComponent(".codex-thirdparty/gateways/\(gateway.profileID)")
        let appData = home.appendingPathComponent("Library/Application Support/Codex Third Party/gateways/\(gateway.profileID)")
        let catalog = profile.appendingPathComponent("gateway-models.json")
        let config = profile.appendingPathComponent("config.toml")
        let policy = profile.appendingPathComponent("model-overrides.json")
        let proxyState = profile.appendingPathComponent("local-proxy-configuration.json")
        try checkPrivatePaths([appData, catalog, config, policy, proxyState], in: home)
        try restoreConfiguration(config, backup: proxyState)
        let cliPaths = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex",
        ]
        let cli = cliPaths.map { bundle.appendingPathComponent($0) }
            .first { files.isExecutableFile(atPath: $0.path) }

        let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw LauncherError.gatewayStatus(status) }

        let overrides = files.fileExists(atPath: policy.path)
            ? try JSONDecoder().decode(ModelOverrides.self, from: Data(contentsOf: policy))
            : ModelOverrides()
        for directory in [profile, appData] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        let proxy: LocalModelProxy?
        if excludeGPT {
            let accountDirectory = includeChatGPT ? home.appendingPathComponent(".codex-thirdparty/chatgpt-plan") : nil
            if let accountDirectory { try checkPrivatePaths([accountDirectory], in: home) }
            proxy = try await LocalModelProxy(gateway: gateway, key: key, accountDirectory: accountDirectory,
                                              authorize: authorizeChatGPT)
        } else {
            proxy = nil
        }
        let models = try ModelCatalog.make(gatewayResponse: data,
                                           bundledCatalog: { self.bundledCatalog(cli, profile: profile) },
                                           overrides: overrides, excludeGPT: excludeGPT,
                                           chatGPTCatalog: proxy?.chatGPTCatalog, contextWindow: contextWindow)
        try writePrivate(models, to: catalog)
        if !files.fileExists(atPath: config.path) {
            try writePrivate(Data(try gateway.configuration(catalog: catalog, userHome: home).utf8), to: config)
        }

        var environment = ProcessInfo.processInfo.environment
        for name in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
                     "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_FEDERATION_RULE_ID"] {
            environment.removeValue(forKey: name)
        }
        if let proxy {
            if proxy.newGrant { showConnectedAccount(proxy.account) }
            let original = try Data(contentsOf: config)
            let active = try gateway.configuration(String(decoding: original, as: UTF8.self), forLocalProxy: proxy.baseURL)
            try writePrivate(JSONEncoder().encode(ProxyConfiguration(original: original, active: Data(active.utf8))), to: proxyState)
            defer { try? restoreConfiguration(config, backup: proxyState) }
            try writePrivate(Data(active.utf8), to: config)
            environment["CODEX_GATEWAY_API_KEY"] = proxy.localKey
            environment["CODEX_HOME"] = profile.path
            environment["CODEX_SQLITE_HOME"] = profile.path
            environment["CODEX_ELECTRON_USER_DATA_PATH"] = appData.path
            try await launchWithProxy(bundle, appData: appData, environment: environment, proxy: proxy)
            return
        }
        environment["CODEX_GATEWAY_API_KEY"] = key
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = [
            "-n", "--env", "CODEX_HOME=\(profile.path)",
            "--env", "CODEX_SQLITE_HOME=\(profile.path)",
            "--env", "CODEX_ELECTRON_USER_DATA_PATH=\(appData.path)",
            bundle.path, "--args", "--user-data-dir=\(appData.path)",
        ]
        launch.environment = environment
        try launch.run()
        launch.waitUntilExit()
        guard launch.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [
                NSLocalizedDescriptionKey: "macOS could not open the isolated desktop app."
            ])
        }
    }

    private func authorizeChatGPT(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "授权 ChatGPT 账号模型"
        alert.informativeText = "请在浏览器选择你正在使用的 ChatGPT 账号。带 ChatGPT 标记的模型使用该账号的套餐额度。"
        alert.addButton(withTitle: "Continue with ChatGPT")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn && workspace.open(url)
    }

    private func showConnectedAccount(_ account: String?) {
        let alert = NSAlert()
        alert.messageText = "已连接 ChatGPT 套餐"
        let identity = account.map { "\($0)\n\n" } ?? ""
        alert.informativeText = identity + "在模型菜单选择带 ChatGPT 标记的模型时，将使用该账号的套餐额度。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "管理用量")
        if alert.runModal() == .alertSecondButtonReturn, let url = URL(string: "https://chatgpt.com/settings/usage") {
            workspace.open(url)
        }
    }

    private func launchWithProxy(_ bundle: URL, appData: URL, environment: [String: String], proxy: LocalModelProxy) async throws {
        defer { withExtendedLifetime(proxy) {} }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--user-data-dir=\(appData.path)"]
        configuration.environment = environment
        let app = try await workspace.openApplication(at: bundle, configuration: configuration)
        guard app.bundleURL?.resolvingSymlinksInPath().path == bundle.resolvingSymlinksInPath().path else {
            throw LauncherError.proxyUnavailable
        }
        while !app.isTerminated {
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func restoreConfiguration(_ config: URL, backup: URL) throws {
        guard files.fileExists(atPath: backup.path) else { return }
        let state = try JSONDecoder().decode(ProxyConfiguration.self, from: Data(contentsOf: backup))
        let current = try Data(contentsOf: config)
        let restored: Data
        do {
            restored = Data(try Gateway.restoreProxyConfiguration(
                current: String(decoding: current, as: UTF8.self),
                original: String(decoding: state.original, as: UTF8.self),
                active: String(decoding: state.active, as: UTF8.self)
            ).utf8)
        } catch {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "The profile configuration changed while GPT exclusion was active. Review config.toml and local-proxy-configuration.json in \(config.deletingLastPathComponent().path) before retrying."
            ])
        }
        if restored != current { try writePrivate(restored, to: config) }
        try files.removeItem(at: backup)
    }

    private func prepareDesktop(in home: URL) async throws -> URL? {
        let relativeCopy = ".codex-thirdparty/ChatGPT.app"
        let legacyCopy = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(relativeCopy)
        let userApplications = home.appendingPathComponent("Applications", isDirectory: true)
        let managedCopy = userApplications.appendingPathComponent(relativeCopy)
        let destination = files.fileExists(atPath: legacyCopy.path) ? legacyCopy : managedCopy
        if destination.path == managedCopy.path { try checkPrivatePaths([managedCopy], in: home) }
        let installation = DesktopInstallation(bundle: destination)
        if let installed = try await Task.detached(priority: .userInitiated, operation: {
            try installation.installedApplication()
        }).value {
            return installed
        }

        let candidates = [URL(fileURLWithPath: "/Applications/ChatGPT.app"), userApplications.appendingPathComponent("ChatGPT.app")] +
            workspace.urlsForApplications(withBundleIdentifier: DesktopInstallation.officialBundleID)
        let automaticSource = await Task.detached(priority: .userInitiated) {
            candidates.map { $0.resolvingSymlinksInPath() }.first {
                $0.deletingLastPathComponent().lastPathComponent != ".codex-thirdparty" &&
                    DesktopInstallation.isOfficialApplication($0)
            }
        }.value
        guard let source = automaticSource ?? chooseDesktop() else { return nil }

        let progress = installationProgress()
        defer { progress.orderOut(nil) }
        return try await Task.detached(priority: .userInitiated) {
            try installation.install(from: source)
        }.value
    }

    private func checkPrivatePaths(_ paths: [URL], in home: URL) throws {
        for path in paths {
            var component = path
            while component.path.hasPrefix(home.path + "/") {
                if (try? files.destinationOfSymbolicLink(atPath: component.path)) != nil {
                    throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                        NSLocalizedDescriptionKey: "Isolated data cannot use a symbolic link at \(component.path). Move the link and retry."
                    ])
                }
                component.deleteLastPathComponent()
            }
        }
    }

    private func chooseDesktop() -> URL? {
        let alert = NSAlert()
        alert.messageText = "Find the official ChatGPT app"
        alert.informativeText = "Install ChatGPT with Codex, or select an existing copy. The launcher will prepare a separate instance for your gateway."
        alert.addButton(withTitle: "Choose App…")
        alert.addButton(withTitle: "Download ChatGPT")
        alert.addButton(withTitle: "Cancel")
        while true {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let picker = NSOpenPanel()
                picker.allowedContentTypes = [.applicationBundle]
                picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                picker.message = "Select the official ChatGPT app with Codex."
                if picker.runModal() == .OK { return picker.url }
            case .alertSecondButtonReturn:
                if let download = URL(string: "https://chatgpt.com/download/") { workspace.open(download) }
                return nil
            default:
                return nil
            }
        }
    }

    private func installationProgress() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Codex Third Party"
        let label = NSTextField(labelWithString: "Preparing the isolated Codex instance…")
        label.frame = NSRect(x: 20, y: 47, width: 320, height: 20)
        let indicator = NSProgressIndicator(frame: NSRect(x: 20, y: 22, width: 320, height: 14))
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(indicator)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        return panel
    }

    @objc private func updateChatGPTOption(_ sender: NSButton) {
        let enabled = sender.state == .on
        chatGPTCheckbox?.isEnabled = enabled
        if !enabled { chatGPTCheckbox?.state = .off }
    }

    private func promptForGateway() -> (String, String, Int, Bool, Bool)? {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Connect to a gateway"
        alert.informativeText = "Enter a Responses API Base URL and API key."
        alert.addButton(withTitle: "Load Models and Launch")
        alert.addButton(withTitle: "Cancel")

        let address = NSTextField()
        address.placeholderString = "Base URL"
        let key = NSSecureTextField()
        key.placeholderString = "API key (this launch only)"
        let context = NSTextField()
        context.placeholderString = "最大上下文（选填，默认 \(Gateway.defaultContextWindow / 1_000)K）"
        context.setAccessibilityLabel("最大上下文")
        let excludeGPT = NSButton(checkboxWithTitle: "排除 GPT 系列模型（推荐）", target: self, action: #selector(updateChatGPTOption(_:)))
        let includeChatGPT = NSButton(checkboxWithTitle: "把 ChatGPT 账号的模型加入隔离实例", target: nil, action: nil)
        includeChatGPT.isEnabled = false
        includeChatGPT.setAccessibilityHelp("开启 GPT 排除后可选。首次使用时在浏览器授权当前账号。")
        chatGPTCheckbox = includeChatGPT
        let explanation = """
        Codex Desktop 可能在后台调用 GPT 模型，产生额外用量。
        勾选后隐藏 GPT 模型，并拦截相关请求。
        """
        excludeGPT.setAccessibilityHelp(explanation)
        let helpIcon = HoverHelpButton(explanation: explanation)
        let filterRow = NSStackView(views: [excludeGPT, helpIcon])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 6
        let stack = NSStackView(views: [address, key, context, filterRow, includeChatGPT])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for field in [address, key, context] {
            field.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = address
        let pasteShortcut = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let editor = alert.window.firstResponder as? NSTextView,
                  editor === address.currentEditor() || editor === key.currentEditor()
                    || editor === context.currentEditor() else { return event }
            editor.paste(nil)
            return nil
        }
        defer {
            helpIcon.dismiss()
            chatGPTCheckbox = nil
            if let pasteShortcut { NSEvent.removeMonitor(pasteShortcut) }
        }
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                let window = try Gateway.contextWindow(context.stringValue)
                return (address.stringValue, key.stringValue, window, excludeGPT.state == .on,
                        excludeGPT.state == .on && includeChatGPT.state == .on)
            } catch {
                NSAlert(error: error).runModal()
                alert.window.initialFirstResponder = context
            }
        }
        return nil
    }

    private func bundledCatalog(_ cli: URL?, profile: URL) -> Data? {
        guard let cli else { return nil }
        let output = Pipe()
        let process = Process()
        process.executableURL = cli
        process.arguments = ["debug", "models", "--bundled"]
        process.environment = ["CODEX_HOME": profile.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private func writePrivate(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

@main
enum LauncherApp {
    @MainActor
    static func main() {
        let launcher = Launcher()
        let application = NSApplication.shared
        application.delegate = launcher
        withExtendedLifetime(launcher) {
            application.run()
        }
    }
}
