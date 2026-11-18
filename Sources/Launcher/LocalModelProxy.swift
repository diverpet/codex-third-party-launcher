import Foundation
import GatewayCore

final class LocalModelProxy {
    private struct Settings: Encodable {
        let baseURL: URL
        let upstreamKey: String
        let localKey: String
        let accountDirectory: String?
        let modelPattern = Gateway.gptModelPattern
    }

    private struct Event: Decodable {
        let authorizeURL: URL?
        let baseURL: URL?
        let catalog: Data?
        let account: String?
        let newGrant: Bool?
        let error: String?
    }

    let baseURL: URL
    let localKey: String
    let chatGPTCatalog: Data?
    let account: String?
    let newGrant: Bool
    private let input: FileHandle

    @MainActor
    init(gateway: Gateway, key: String, accountDirectory: URL?, authorize: (URL) -> Bool) async throws {
        let process = Process()
        let commands = Pipe()
        let output = Pipe()
        let randomKey = UUID().uuidString + UUID().uuidString
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/GatewayProxy")
        process.standardInput = commands
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let settings = Settings(baseURL: gateway.baseURL, upstreamKey: key, localKey: randomKey,
                                    accountDirectory: accountDirectory?.path)
            try commands.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(settings) + Data([10]))
            for try await line in output.fileHandleForReading.bytes.lines {
                let event = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
                if let error = event.error { throw LauncherError.chatGPTConnection(error) }
                if let login = event.authorizeURL {
                    guard login.scheme == "https", login.host == "auth.openai.com",
                          login.path == "/api/accounts/authorize", authorize(login) else {
                        throw LauncherError.chatGPTConnection("chatgpt_authorization_declined")
                    }
                    continue
                }
                guard let url = event.baseURL, url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
                      accountDirectory == nil || event.catalog != nil else { throw LauncherError.proxyUnavailable }
                baseURL = url
                chatGPTCatalog = event.catalog
                account = event.account
                newGrant = event.newGrant ?? false
                input = commands.fileHandleForWriting
                localKey = randomKey
                return
            }
            throw LauncherError.proxyUnavailable
        } catch let error as LauncherError {
            try? commands.fileHandleForWriting.close()
            throw error
        } catch {
            try? commands.fileHandleForWriting.close()
            throw LauncherError.proxyUnavailable
        }
    }

    deinit { try? input.close() }
}
