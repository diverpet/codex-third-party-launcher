import Foundation
import GatewayCore

@main
struct GatewayCoreTests {
    static func main() throws {
        let tests = Self()
        try tests.testGatewayNormalizationAndKeyHandling()
        try tests.testCatalogIDsAndImageClassification()
        try tests.testCatalogFiltersOnlyExplicitNonResponsesModels()
        try tests.testNativeCatalogDoesNotLoadBundledDefaults()
        try tests.testHomeFolderDoesNotReuseOfficialConfiguration()
        print("All gateway checks passed.")
    }

    func testGatewayNormalizationAndKeyHandling() throws {
        let gateway = try Gateway(" HTTPS://Example.COM:443/v1/ ")
        assertEqual(gateway.baseURL.absoluteString, "https://example.com/v1")
        let normalized = try Gateway("https://example.com/v1")
        assertEqual(gateway.profileID, normalized.profileID)
        let other = try Gateway("https://other.example/v1")
        assertTrue(gateway.profileID != other.profileID)
        let request = try gateway.modelRequest(key: " fixture ")
        assertEqual(request.url?.absoluteString, "https://example.com/v1/models")
        assertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        for invalid in ["http://example.com/v1", "https://user@example.com", "https://example.com?key=x"] {
            assertThrows(try Gateway(invalid))
        }
        assertThrows(try gateway.modelRequest(key: "foo\nbar"))
        _ = try Gateway("http://127.0.0.1:8080/v1")
    }

    func testCatalogIDsAndImageClassification() throws {
        let gateway = Data("""
            {"data":[{"id":"known"},{"id":"vision","input_modalities":["text","image"]},
                     {"id":"unknown"},{"id":"known"},{"id":"vendor/known"}]}
            """.utf8)
        let stock = Data("""
            {"models":[{"slug":"known","display_name":"Alias","visibility":"list",
                        "supported_in_api":true,"input_modalities":["text","image"]}]}
            """.utf8)
        let overrides = try JSONDecoder().decode(ModelOverrides.self, from: Data("""
            {"excludePrefixes":["vendor/"],"inputModalities":{"unknown":["text","image"]}}
            """.utf8))
        let result = try ModelCatalog.make(gatewayResponse: gateway, bundledCatalog: { stock }, overrides: overrides)
        let catalog = try unwrap(JSONSerialization.jsonObject(with: result) as? [String: [[String: Any]]])
        let models = try unwrap(catalog["models"])
        assertEqual(models.compactMap { $0["slug"] as? String }, ["known", "unknown", "vision"])
        assertEqual(models.compactMap { $0["display_name"] as? String }, ["known", "unknown", "vision"])
        for model in models {
            assertEqual(model["input_modalities"] as? [String], ["text", "image"])
        }
    }

    func testNativeCatalogDoesNotLoadBundledDefaults() throws {
        let raw = Data("""
            {"models":[{"slug":"test","visibility":"list","display_name":"Alternate","input_modalities":["text"],"priority":17},
                       {"slug":"chat","visibility":"list","supported_apis":["chat.completions"]}]}
            """.utf8)
        let result = try ModelCatalog.make(gatewayResponse: raw, bundledCatalog: {
            fatalError("Native catalog should not invoke the bundled CLI")
        })
        let catalog = try unwrap(JSONSerialization.jsonObject(with: result) as? [String: [[String: Any]]])
        assertEqual(catalog["models"]?.count, 1)
        let model = try unwrap(catalog["models"]?.first)
        assertEqual(model["display_name"] as? String, "test")
        assertEqual(model["priority"] as? Int, 17)
    }

    func testCatalogFiltersOnlyExplicitNonResponsesModels() throws {
        let raw = Data("""
            {"object":"list","data":[
                {"id":"chat","supported_apis":["chat.completions"]},
                {"id":"empty","supported_apis":[]},
                {"id":"legacy"},
                {"id":"null","supported_apis":null},
                {"id":"vision","supported_apis":["chat.completions","responses"],"input_modalities":["text","image"]}
            ]}
            """.utf8)
        let result = try ModelCatalog.make(gatewayResponse: raw, bundledCatalog: { nil })
        let catalog = try unwrap(JSONSerialization.jsonObject(with: result) as? [String: [[String: Any]]])
        let models = try unwrap(catalog["models"])
        assertEqual(models.compactMap { $0["slug"] as? String }, ["legacy", "null", "vision"])
        assertEqual(models.last?["input_modalities"] as? [String], ["text", "image"])
        let chatOnly = Data("""
            {"data":[{"id":"chat","supported_apis":["chat.completions"]}]}
            """.utf8)
        assertThrows(try ModelCatalog.make(gatewayResponse: chatOnly, bundledCatalog: { nil }))
    }

    func testHomeFolderDoesNotReuseOfficialConfiguration() throws {
        let gateway = try Gateway("https://example.com/v1")
        let catalog = URL(fileURLWithPath: "/tmp/codex-test/gateway-models.json")
        let home = URL(fileURLWithPath: "/Users/test")
        let config = try gateway.configuration(catalog: catalog, userHome: home)
        assertTrue(config.contains("[projects.\"/Users/test\"]\ntrust_level = \"untrusted\""))
        assertTrue(config.contains("env_key = \"CODEX_GATEWAY_API_KEY\""))
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, line: UInt = #line) {
    precondition(actual == expected, "Line \(line): expected \(expected), got \(actual)")
}

private func assertTrue(_ condition: Bool, line: UInt = #line) {
    precondition(condition, "Assertion failed on line \(line)")
}

private func assertThrows<T>(_ expression: @autoclosure () throws -> T, line: UInt = #line) {
    do {
        _ = try expression()
        fatalError("Expected an error on line \(line)")
    } catch {}
}

private func unwrap<T>(_ optional: T?, line: UInt = #line) throws -> T {
    guard let optional else { throw NSError(domain: "GatewayChecks", code: Int(line)) }
    return optional
}
