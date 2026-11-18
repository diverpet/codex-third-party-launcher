import CryptoKit
import Foundation

public enum LauncherError: LocalizedError {
    case invalidURL
    case invalidKey
    case gatewayStatus(Int)
    case missingModels
    case invalidPolicy

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter an HTTPS Base URL without credentials, query parameters, or a fragment. Loopback HTTP is also supported."
        case .invalidKey:
            return "Enter a valid API key."
        case .gatewayStatus(let status):
            return "The gateway returned HTTP \(status) from /models."
        case .missingModels:
            return "The gateway did not return any usable models. Check your Base URL, key permissions, Responses API support, and local catalog filters."
        case .invalidPolicy:
            return "The model overrides file contains an invalid input modality or empty exclusion prefix."
        }
    }
}

public struct Gateway {
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

    public func configuration(catalog: URL, userHome: URL) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func quote(_ value: String) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
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
}
