import CryptoKit
import Foundation

public struct TurnCompletion: Codable, Sendable {
    public static let relayDirectoryVariable = "CODEX_THIRDPARTY_TURN_NOTICES"
    public static let notifierVariable = "CODEX_THIRDPARTY_NOTIFIER"

    public let threadID: UUID
    public let turnID: String
    private let type: String

    private enum CodingKeys: String, CodingKey {
        case type
        case threadID = "thread-id"
        case turnID = "turn-id"
    }

    public static func parse(_ data: Data) -> Self? {
        guard let event = try? JSONDecoder().decode(Self.self, from: data),
              event.type == "agent-turn-complete", !event.turnID.isEmpty,
              event.turnID.utf8.count <= 256 else { return nil }
        return event
    }

    public var identifier: String {
        let value = Data("\(threadID.uuidString)/\(turnID)".utf8)
        return SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    public static func threadURL(_ threadID: UUID) -> URL? {
        URL(string: "codex://threads/\(threadID.uuidString.lowercased())")
    }

    // Codex appends the event as the first argument after the shell's $0.
    // The profile can also be used without the Launcher. In that case the command is inert.
    public static func addingNotifyCommand(to configuration: String) throws -> String? {
        let command = ["/bin/sh", "-c",
                       "if [ -n \"$\(notifierVariable)\" ]; then exec \"$\(notifierVariable)\" --notify-turn \"$1\"; fi",
                       "codex-thirdparty-notify"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let line = "notify = " + String(decoding: try encoder.encode(command), as: UTF8.self)
        if configuration.components(separatedBy: .newlines).contains(line) { return configuration }
        let customNotify = #"(?m)^[ \t]*(?:notify|"notify"|'notify')[ \t]*="#
        guard configuration.range(of: customNotify, options: .regularExpression) == nil else { return nil }
        return line + "\n" + configuration
    }
}
