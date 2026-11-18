import AppKit
import Foundation
import GatewayCore

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
    private let files = FileManager.default
    private let workspace = NSWorkspace.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let home = files.homeDirectoryForCurrentUser
        let bundle = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".codex-thirdparty/ChatGPT.app")
        guard let executable = Bundle(url: bundle)?.executableURL,
              files.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "Codex Desktop was not found. Run scripts/install.sh first."
            ])
        }

        if let running = workspace.runningApplications.first(where: {
            $0.executableURL?.standardizedFileURL == executable.standardizedFileURL
        }) {
            running.activate()
            return
        }

        guard let (address, secret) = promptForGateway() else { return }
        let gateway = try Gateway(address)
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try gateway.modelRequest(key: key)
        let profile = home.appendingPathComponent(".codex-thirdparty/gateways/\(gateway.profileID)")
        let appData = home.appendingPathComponent("Library/Application Support/Codex Third Party/gateways/\(gateway.profileID)")
        let catalog = profile.appendingPathComponent("gateway-models.json")
        let config = profile.appendingPathComponent("config.toml")
        let policy = profile.appendingPathComponent("model-overrides.json")
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
        let models = try ModelCatalog.make(gatewayResponse: data,
                                           bundledCatalog: { self.bundledCatalog(cli, profile: profile) },
                                           overrides: overrides)
        try writePrivate(models, to: catalog)
        if !files.fileExists(atPath: config.path) {
            try writePrivate(Data(try gateway.configuration(catalog: catalog, userHome: home).utf8), to: config)
        }

        var environment = ProcessInfo.processInfo.environment
        for name in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
                     "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_FEDERATION_RULE_ID"] {
            environment.removeValue(forKey: name)
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

    private func promptForGateway() -> (String, String)? {
        let alert = NSAlert()
        alert.messageText = "Connect to a gateway"
        alert.informativeText = "Enter a Responses API Base URL and API key."
        alert.addButton(withTitle: "Load Models and Launch")
        alert.addButton(withTitle: "Cancel")

        let address = NSTextField()
        address.placeholderString = "Base URL"
        let key = NSSecureTextField()
        key.placeholderString = "API key (this launch only)"
        let stack = NSStackView(views: [address, key])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for field in [address, key] {
            field.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = address
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (address.stringValue, key.stringValue)
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
