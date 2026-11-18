import Foundation
import GatewayCore

final class LocalModelProxy {
    private struct Settings: Encodable {
        let baseURL: URL
        let upstreamKey: String
        let localKey: String
        let modelPattern = Gateway.gptModelPattern
    }

    let baseURL: URL
    let localKey: String
    private let input: FileHandle

    init(gateway: Gateway, key: String) throws {
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
            let settings = Settings(baseURL: gateway.baseURL, upstreamKey: key, localKey: randomKey)
            try commands.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(settings) + Data([10]))
            let ready = output.fileHandleForReading.availableData
            guard !ready.isEmpty, ready.count <= 128,
                  let address = String(data: ready, encoding: .utf8),
                  let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme == "http", url.host == "127.0.0.1", url.port != nil else {
                throw LauncherError.proxyUnavailable
            }
            baseURL = url
        } catch {
            try? commands.fileHandleForWriting.close()
            throw LauncherError.proxyUnavailable
        }
        input = commands.fileHandleForWriting
        localKey = randomKey
    }

    deinit { try? input.close() }
}
