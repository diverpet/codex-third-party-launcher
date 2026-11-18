import CryptoKit
import Foundation

public enum LauncherError: LocalizedError {
    case invalidURL
    case invalidKey
    case invalidContextWindow
    case gatewayStatus(Int)
    case missingModels
    case invalidPolicy
    case proxyUnavailable
    case proxyConfiguration
    case chatGPTConnection(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter an HTTPS Base URL without credentials, query parameters, or a fragment. Loopback HTTP is also supported."
        case .invalidKey:
            return "Enter a valid API key."
        case .invalidContextWindow:
            return "最大上下文请输入正整数，例如 128000 或 128K。"
        case .gatewayStatus(let status):
            return "The gateway returned HTTP \(status) from /models."
        case .missingModels:
            return "The gateway did not return any usable models. Check your Base URL, key permissions, Responses API support, and local catalog filters."
        case .invalidPolicy:
            return "Check exclusion prefixes, input modalities, and reasoning levels in model-overrides.json. A model's default reasoning level must be one of its available levels."
        case .proxyUnavailable:
            return "The local GPT filter could not start. Reinstall the launcher and try again."
        case .proxyConfiguration:
            return "GPT exclusion requires the launcher-managed thirdparty provider in this profile's config.toml."
        case .chatGPTConnection(let reason):
            switch reason {
            case "chatgpt_plan_not_enabled":
                return "这个账号没有授予 ChatGPT 套餐用量权限。请在授权页面选择符合条件的账号。"
            case "chatgpt_models_unavailable":
                return "无法读取这个 ChatGPT 账号的可用模型。请检查账号的使用权限后重试。"
            case "chatgpt_authorization_declined":
                return "ChatGPT 授权已取消。"
            default:
                return "连接 ChatGPT 账号失败。请重新打开 Launcher 后重试。"
            }
        }
    }
}

public struct Gateway {
    public static let defaultContextWindow = 500_000
    public let baseURL: URL

    public init(_ input: String) throws {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
        else { throw LauncherError.invalidURL }

        parts.scheme = scheme
        parts.host = host
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        while parts.percentEncodedPath.hasSuffix("/") {
            parts.percentEncodedPath.removeLast()
        }
        guard let url = parts.url else { throw LauncherError.invalidURL }
        baseURL = url
    }

    public var profileID: String {
        SHA256.hash(data: Data(baseURL.absoluteString.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
    }

    public func modelRequest(key: String) throws -> URLRequest {
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw LauncherError.invalidKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("models"), timeoutInterval: 15)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }

    public static func contextWindow(_ input: String) throws -> Int {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return defaultContextWindow }

        let thousands = value.last == "K" || value.last == "k"
        let digits = thousands ? String(value.dropLast()) : value
        let multiplier = thousands ? 1_000 : 1
        guard digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let amount = Int(digits), (1...(Int(Int32.max) / multiplier)).contains(amount) else {
            throw LauncherError.invalidContextWindow
        }
        return amount * multiplier
    }

    public func configuration(catalog: URL, userHome: URL) throws -> String {
        return """
        model_provider = "thirdparty"
        model_catalog_json = \(try quote(catalog.path))
        cli_auth_credentials_store = "file"

        [model_providers.thirdparty]
        name = "Third-party gateway"
        base_url = \(try quote(baseURL.absoluteString))
        wire_api = "responses"
        env_key = "CODEX_GATEWAY_API_KEY"
        requires_openai_auth = false

        # Keep the official user config from loading as project config.
        [projects.\(try quote(userHome.path))]
        trust_level = "untrusted"

        """
    }

    public static let gptModelPattern = "(?i)(^|/)(gpt|chatgpt)([-_.0-9][^/]*)?$"

    public static func isGPTModel(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines).range(of: gptModelPattern, options: .regularExpression) != nil
    }

    public static func enableReasoningLevels(_ levels: Set<String>, in configuration: String) -> String {
        // The Desktop picker applies this preference on top of each model's catalog.
        let defaults = ["low", "medium", "high", "xhigh", "ultra", "persistent"]
        let additional = ["none", "minimal", "max"].filter(levels.contains)
        let explicitPreference = #"(?m)^\s*(enabled-reasoning-efforts|"enabled-reasoning-efforts"|'enabled-reasoning-efforts')\s*="#
        guard !additional.isEmpty,
              configuration.range(of: explicitPreference, options: .regularExpression) == nil else { return configuration }
        let entry = "enabled-reasoning-efforts = [" + (defaults + additional).map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        var lines = configuration.components(separatedBy: "\n")
        if let table = lines.firstIndex(where: {
            $0.range(of: #"^\s*\[\s*(desktop|"desktop"|'desktop')\s*\]\s*(#.*)?$"#, options: .regularExpression) != nil
        }) {
            lines.insert(entry, at: table + 1)
            return lines.joined(separator: "\n")
        }
        // Preserve a profile that represents Desktop settings as an inline table or dotted keys.
        let customRoot = #"(?m)^\s*(desktop|"desktop"|'desktop')\s*[.=]"#
        guard configuration.range(of: customRoot, options: .regularExpression) == nil else { return configuration }
        return configuration + "\n[desktop]\n" + entry + "\n"
    }

    public func configuration(_ existing: String, forLocalProxy proxyURL: URL) throws -> String {
        let lines = existing.components(separatedBy: .newlines)
        let root = lines.prefix(while: { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") })
        let section = "[model_providers.thirdparty]"
        guard root.contains(#"model_provider = "thirdparty""#),
              let start = lines.firstIndex(of: section) else { throw LauncherError.proxyConfiguration }
        let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.endIndex
        let provider = lines[(start + 1)..<end]
        let remoteLine = "base_url = \(try quote(baseURL.absoluteString))"
        guard provider.contains(#"env_key = "CODEX_GATEWAY_API_KEY""#),
              provider.contains(#"wire_api = "responses""#),
              let base = provider.firstIndex(of: remoteLine) else { throw LauncherError.proxyConfiguration }
        var updated = lines
        let proxyLine = "base_url = \(try quote(proxyURL.absoluteString))"
        updated[base] = proxyLine
        if let websockets = provider.firstIndex(where: {
            $0.range(of: #"^\s*supports_websockets\s*="#, options: .regularExpression) != nil
        }) {
            updated[websockets] = "supports_websockets = false"
        } else {
            updated.insert("supports_websockets = false", at: base + 1)
        }
        return updated.joined(separator: "\n")
    }

    public static func restoreProxyConfiguration(current: String, original: String, active: String) throws -> String {
        if current == active { return original }
        if current == original { return current }

        // Codex writes preferences to this file during a session. Restore only the
        // two provider settings changed by the launcher and keep the other edits.
        var currentLines = current.components(separatedBy: "\n")
        let originalLines = original.components(separatedBy: "\n")
        let activeLines = active.components(separatedBy: "\n")
        var replacements: [(Int, String?)] = []
        for key in ["base_url", "supports_websockets"] {
            let before = try providerSetting(key, in: originalLines)
            guard let temporary = try providerSetting(key, in: activeLines) else {
                throw LauncherError.proxyConfiguration
            }
            let actual = try providerSetting(key, in: currentLines)
            if actual?.value == before?.value { continue }
            guard let actual, actual.value == temporary.value else { throw LauncherError.proxyConfiguration }
            replacements.append((actual.index, before.map { originalLines[$0.index] }))
        }
        for (index, replacement) in replacements.sorted(by: { $0.0 > $1.0 }) {
            if let replacement { currentLines[index] = replacement }
            else { currentLines.remove(at: index) }
        }
        return currentLines.joined(separator: "\n")
    }

    private static func providerSetting(_ key: String, in lines: [String]) throws -> (index: Int, value: String)? {
        let table = "[model_providers.thirdparty]"
        let sections = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == table
        }
        guard sections.count == 1, let start = sections.first else { throw LauncherError.proxyConfiguration }
        let assignment = try NSRegularExpression(pattern: "^\\s*" + key + #"[ \t]*=[ \t]*("(?:[^"\\]|\\.)*"|true|false)[ \t]*(?:#.*)?\s*$"#)
        let prefix = "^\\s*" + key + #"\s*="#
        let indices = lines.indices.dropFirst(start + 1).prefix {
            !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        }.filter { lines[$0].range(of: prefix, options: .regularExpression) != nil }
        guard let index = indices.first else { return nil }
        let line = lines[index]
        guard indices.count == 1,
              let match = assignment.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { throw LauncherError.proxyConfiguration }
        let value = String(line[range])
        if value.hasPrefix("\"") {
            return (index, try JSONDecoder().decode(String.self, from: Data(value.utf8)))
        }
        return (index, value)
    }

    private func quote(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
