import Foundation

public struct ModelOverrides: Decodable {
    public struct ReasoningEfforts: Decodable {
        private static let knownLevels: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        let levels: [String]
        let defaultEffort: String

        var isValid: Bool {
            let unique = Set(levels)
            return levels.count == unique.count && unique.isSubset(of: Self.knownLevels) && unique.contains(defaultEffort)
        }
    }

    public let excludePrefixes: [String]
    public let inputModalities: [String: [String]]
    public let reasoningEfforts: [String: ReasoningEfforts]

    public var declaredReasoningLevels: Set<String> {
        Set(reasoningEfforts.values.flatMap(\.levels))
    }

    public init(excludePrefixes: [String] = [], inputModalities: [String: [String]] = [:]) {
        self.excludePrefixes = excludePrefixes
        self.inputModalities = inputModalities
        self.reasoningEfforts = [:]
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        excludePrefixes = try values.decodeIfPresent([String].self, forKey: .excludePrefixes) ?? []
        inputModalities = try values.decodeIfPresent([String: [String]].self, forKey: .inputModalities) ?? [:]
        reasoningEfforts = try values.decodeIfPresent([String: ReasoningEfforts].self, forKey: .reasoningEfforts) ?? [:]
        guard !excludePrefixes.contains(""), inputModalities.values.allSatisfy({
            !$0.isEmpty && $0.allSatisfy { ["text", "image"].contains($0) }
        }), reasoningEfforts.allSatisfy({ !$0.key.isEmpty && $0.value.isValid }) else {
            throw LauncherError.invalidPolicy
        }
    }

    private enum CodingKeys: String, CodingKey { case excludePrefixes, inputModalities, reasoningEfforts }
}

public enum ModelCatalog {
    public static func make(
        gatewayResponse: Data, bundledCatalog: () -> Data?, overrides: ModelOverrides = .init(), excludeGPT: Bool = false,
        chatGPTCatalog: Data? = nil, contextWindow: Int = Gateway.defaultContextWindow
    ) throws -> Data {
        let response = try JSONSerialization.jsonObject(with: gatewayResponse) as? [String: Any]
        let entries: [[String: Any]]
        if let native = response?["models"] as? [[String: Any]] {
            entries = native.filter(supportsResponses)
        } else if let standard = response?["data"] as? [[String: Any]] {
            let defaults = bundledModels(bundledCatalog())
            entries = standard.filter(supportsResponses).sorted {
                ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
            }.enumerated().compactMap { index, entry in
                guard let id = entry["id"] as? String else { return nil }
                var model = defaults[id] ?? genericModel(id, priority: 1_000 + index)
                // A matching ID in the bundled catalog does not describe the gateway's route.
                model["supported_reasoning_levels"] = []
                model.removeValue(forKey: "default_reasoning_level")
                model.removeValue(forKey: "supports_reasoning_effort_updates")
                if let declared = entry["input_modalities"] as? [String] {
                    model["input_modalities"] = declared.contains("image") ? ["text", "image"] : ["text"]
                }
                return model
            }
        } else {
            throw LauncherError.missingModels
        }

        var seen = Set<String>()
        var models = entries.compactMap { entry -> [String: Any]? in
            guard let id = entry["slug"] as? String, !id.isEmpty,
                  id.rangeOfCharacter(from: .controlCharacters) == nil,
                  !(excludeGPT && Gateway.isGPTModel(id)),
                  !(chatGPTCatalog != nil && id.lowercased().hasPrefix("chatgpt/")),
                  !overrides.excludePrefixes.contains(where: { id.hasPrefix($0) }),
                  seen.insert(id).inserted else { return nil }
            var model = entry
            model["display_name"] = id
            model["context_window"] = contextWindow
            model["max_context_window"] = contextWindow
            if let override = overrides.inputModalities[id] {
                model["input_modalities"] = override
            }
            if let reasoning = overrides.reasoningEfforts[id] {
                model["default_reasoning_level"] = reasoning.defaultEffort
                model["supported_reasoning_levels"] = reasoning.levels.map { level in
                    ["effort": level, "description": "Use the \(level) reasoning level."]
                }
            }
            return model
        }
        if let chatGPTCatalog {
            let accountResponse = try JSONSerialization.jsonObject(with: chatGPTCatalog) as? [String: Any]
            guard excludeGPT, let accountModels = accountResponse?["models"] as? [[String: Any]] else {
                throw LauncherError.chatGPTConnection("chatgpt_models_unavailable")
            }
            var nextPriority = min(models.compactMap { $0["priority"] as? Int }.max() ?? 999, Int(Int32.max) - 1) + 1
            for entry in accountModels {
                var model = entry
                guard let id = model["slug"] as? String, id.hasPrefix("chatgpt/"),
                      (model["visibility"] as? String) == "list", seen.insert(id).inserted else { continue }
                model["priority"] = nextPriority
                model["supported_in_api"] = true
                // Codex omits hosted Web Search from Responses Lite requests.
                model["use_responses_lite"] = false
                models.append(model)
                if nextPriority < Int(Int32.max) { nextPriority += 1 }
            }
        }
        guard models.contains(where: { ($0["visibility"] as? String) == "list" })
        else { throw LauncherError.missingModels }
        return try JSONSerialization.data(withJSONObject: ["models": models], options: [.prettyPrinted, .sortedKeys])
    }

    private static func supportsResponses(_ entry: [String: Any]) -> Bool {
        // The OpenAI Models API does not require capability metadata.
        guard let supported = entry["supported_apis"] as? [String] else { return true }
        return supported.contains("responses")
    }

    private static func bundledModels(_ data: Data?) -> [String: [String: Any]] {
        guard let data,
              let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]],
              let models = catalog["models"] else { return [:] }
        return Dictionary(models.compactMap { model -> (String, [String: Any])? in
            guard let id = model["slug"] as? String,
                  (model["visibility"] as? String) == "list",
                  (model["supported_in_api"] as? Bool) == true else { return nil }
            return (id, model)
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func genericModel(_ id: String, priority: Int) -> [String: Any] {
        [
            "slug": id,
            "base_instructions": "Help the user with coding tasks. Use the provided tools when appropriate.",
            "supported_reasoning_levels": [],
            "shell_type": "shell_command",
            "visibility": "list",
            "supported_in_api": true,
            "priority": priority,
            "support_verbosity": false,
            "truncation_policy": ["mode": "tokens", "limit": 10_000],
            "experimental_supported_tools": [],
            "input_modalities": ["text"],
        ]
    }
}
