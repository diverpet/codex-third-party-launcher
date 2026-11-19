import AppKit
import GatewayCore
import UserNotifications

@MainActor
final class TurnNotifications: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let directoryPrefix = "codex-turn-notices-"

    private let center = UNUserNotificationCenter.current()
    private let sessionID = UUID()
    let directory: URL
    private var desktop: NSRunningApplication?
    private var delivered: Set<String> = []

    init(directory: URL) {
        self.directory = directory
        super.init()
        center.delegate = self
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }

    func attach(to desktop: NSRunningApplication) {
        self.desktop = desktop
    }

    func postPending() async {
        guard let desktop, !desktop.isTerminated else { return }
        let files = FileManager.default
        let queued = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in queued where file.pathExtension == "json" {
            guard let bytes = try? Data(contentsOf: file), let event = TurnCompletion.parse(bytes) else {
                try? files.removeItem(at: file)
                continue
            }
            let id = "\(sessionID.uuidString)-\(event.identifier)"
            if !desktop.isActive, !delivered.contains(id) {
                let content = UNMutableNotificationContent()
                content.title = "第三方 Codex"
                content.body = "本轮已完成。点击打开会话。"
                content.sound = .default
                content.userInfo = ["session": sessionID.uuidString, "thread": event.threadID.uuidString]
                let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
                do {
                    try await center.add(request)
                    delivered.insert(id)
                } catch {
                    // The desktop session can continue if notifications are denied or unavailable.
                }
            }
            try? files.removeItem(at: file)
        }
    }

    func finish() {
        desktop = nil
        let identifiers = Array(delivered)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let session = info["session"] as? String, let thread = info["thread"] as? String,
              let threadID = UUID(uuidString: thread) else { return }
        await open(threadID, from: session)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    private func open(_ thread: UUID, from session: String) async {
        guard session == sessionID.uuidString, let desktop, !desktop.isTerminated,
              let bundle = desktop.bundleURL, let url = TurnCompletion.threadURL(thread) else { return }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        options.allowsRunningApplicationSubstitution = false
        options.addsToRecentItems = false
        // Preserve the isolated launch environment by opening the existing app at its exact path.
        _ = try? await NSWorkspace.shared.open([url], withApplicationAt: bundle, configuration: options)
    }

    nonisolated static func enqueue(_ payload: String) {
        guard let path = ProcessInfo.processInfo.environment[TurnCompletion.relayDirectoryVariable],
              let event = TurnCompletion.parse(Data(payload.utf8)) else { return }
        let files = FileManager.default
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let name = directory.lastPathComponent
        guard name.hasPrefix(directoryPrefix), UUID(uuidString: String(name.dropFirst(directoryPrefix.count))) != nil,
              directory.deletingLastPathComponent().resolvingSymlinksInPath().path ==
                  files.temporaryDirectory.resolvingSymlinksInPath().path,
              let resource = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              resource.isDirectory == true, resource.isSymbolicLink == false,
              let encoded = try? JSONEncoder().encode(event) else { return }
        try? encoded.write(to: directory.appendingPathComponent(event.identifier + ".json"), options: .atomic)
    }
}
