import Foundation

public struct ModelOverrides: Decodable {
    public let excludePrefixes: [String]
    public let inputModalities: [String: [String]]

    public init(excludePrefixes: [String] = [], inputModalities: [String: [String]] = [:]) {
        self.excludePrefixes = excludePrefixes
        self.inputModalities = inputModalities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        excludePrefixes = try values.decodeIfPresent([String].self, forKey: .excludePrefixes) ?? []
        inputModalities = try values.decodeIfPresent([String: [String]].self, forKey: .inputModalities) ?? [:]
        guard !excludePrefixes.contains(""), inputModalities.values.allSatisfy({
            !$0.isEmpty && $0.allSatisfy { ["text", "image"].contains($0) }
        }) else { throw LauncherError.invalidPolicy }
    }

    private enum CodingKeys: String, CodingKey { case excludePrefixes, inputModalities }
}

public enum ModelCatalog {
    public static func make(
        gatewayResponse: Data, bundledCatalog: () -> Data?, overrides: ModelOverrides = .init()
    ) throws -> Data {
        let response = try JSONSerialization.jsonObject(with: gatewayResponse) as? [String: Any]
        let entries: [[String: Any]]
        if let native = response?["models"] as? [[String: Any]] {
            entries = native
        } else if let standard = response?["data"] as? [[String: Any]] {
            let defaults = bundledModels(bundledCatalog())
            entries = standard.sorted {
                ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
            }.enumerated().compactMap { index, entry in
                guard let id = entry["id"] as? String else { return nil }
                var model = defaults[id] ?? genericModel(id, priority: 1_000 + index)
                if let declared = entry["input_modalities"] as? [String] {
                    model["input_modalities"] = declared.contains("image") ? ["text", "image"] : ["text"]
                }
                return model
            }
        } else {
            throw LauncherError.missingModels
        }

        var seen = Set<String>()
        let models = entries.compactMap { entry -> [String: Any]? in
            guard let id = entry["slug"] as? String, !id.isEmpty,
                  id.rangeOfCharacter(from: .controlCharacters) == nil,
                  !overrides.excludePrefixes.contains(where: { id.hasPrefix($0) }),
                  seen.insert(id).inserted else { return nil }
            var model = entry
            model["display_name"] = id
            if let override = overrides.inputModalities[id] {
                model["input_modalities"] = override
            }
            return model
        }
        guard models.contains(where: { ($0["visibility"] as? String) == "list" })
        else { throw LauncherError.missingModels }
        return try JSONSerialization.data(withJSONObject: ["models": models], options: [.prettyPrinted, .sortedKeys])
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
