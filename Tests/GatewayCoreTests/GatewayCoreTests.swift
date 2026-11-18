import Foundation
import DesktopInstallation
import GatewayCore

@main
struct GatewayCoreTests {
    static func main() throws {
        let tests = Self()
        try tests.testGatewayNormalizationAndKeyHandling()
        try tests.testCatalogIDsAndImageClassification()
        try tests.testCatalogFiltersOnlyExplicitNonResponsesModels()
        try tests.testGPTExclusionUsesSameModelIDsAsProxy()
        try tests.testNativeCatalogDoesNotLoadBundledDefaults()
        try tests.testHomeFolderDoesNotReuseOfficialConfiguration()
        try tests.testProxyConfigurationChangesOnlyLauncherProvider()
        try tests.testProxyRecoveryPreservesDesktopEdits()
        try tests.testDesktopInstallerRejectsUnverifiedAppsAndManagedSymlinks()
        if let officialApp = ProcessInfo.processInfo.environment["CODEX_TEST_OFFICIAL_APP"] {
            try tests.testOfficialAppCopyInTemporaryDirectory(URL(fileURLWithPath: officialApp))
        }
        print("All launcher checks passed.")
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

    func testGPTExclusionUsesSameModelIDsAsProxy() throws {
        let response = Data("""
            {"data":[{"id":"gpt-6-luna"},{"id":"OpenAI/GPT-6.1-terra"},{"id":"chatgpt-4o-latest"},{"id":"deepseek-v4"}]}
            """.utf8)
        let result = try ModelCatalog.make(gatewayResponse: response, bundledCatalog: { nil }, excludeGPT: true)
        let catalog = try unwrap(JSONSerialization.jsonObject(with: result) as? [String: [[String: Any]]])
        assertEqual(catalog["models"]?.compactMap { $0["slug"] as? String }, ["deepseek-v4"])
    }

    func testProxyConfigurationChangesOnlyLauncherProvider() throws {
        let gateway = try Gateway("https://example.com/v1")
        let original = try gateway.configuration(catalog: URL(fileURLWithPath: "/tmp/models.json"),
                                                 userHome: URL(fileURLWithPath: "/Users/test"))
        let proxyURL = try unwrap(URL(string: "http://127.0.0.1:23456"))
        let configured = try gateway.configuration(original, forLocalProxy: proxyURL)
        assertTrue(configured.contains(#"base_url = "http://127.0.0.1:23456""#))
        assertTrue(configured.contains("supports_websockets = false"))
        assertTrue(configured.contains(#"trust_level = "untrusted""#))
        assertThrows(try gateway.configuration(original.replacingOccurrences(of: "base_url", with: "other_url"),
                                               forLocalProxy: proxyURL))
    }

    func testProxyRecoveryPreservesDesktopEdits() throws {
        let gateway = try Gateway("https://example.com/v1")
        let original = try gateway.configuration(catalog: URL(fileURLWithPath: "/tmp/models.json"),
                                                 userHome: URL(fileURLWithPath: "/Users/test"))
        let active = try gateway.configuration(original, forLocalProxy: URL(string: "http://127.0.0.1:23456")!)
        let additions = "model = \"deepseek-v4\"\n"
        let preferences = "\n[desktop]\nconversationDetailMode = \"expanded\"\n"
        let current = additions + active.replacingOccurrences(of: "supports_websockets = false", with: "supports_websockets=false # session") + preferences
        assertEqual(try Gateway.restoreProxyConfiguration(current: current, original: original, active: active),
                    additions + original + preferences)
        assertThrows(try Gateway.restoreProxyConfiguration(
            current: current.replacingOccurrences(of: "127.0.0.1:23456", with: "127.0.0.1:12345"),
            original: original, active: active))
    }

    func testDesktopInstallerRejectsUnverifiedAppsAndManagedSymlinks() throws {
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("Unofficial.app", isDirectory: true)
        let macOS = source.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try files.createDirectory(at: macOS, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": DesktopInstallation.officialBundleID,
            "CFBundleExecutable": "ChatGPT",
            "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0).write(to: source.appendingPathComponent("Contents/Info.plist"))
        try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("ChatGPT"))
        let destination = temporary.appendingPathComponent("Managed/ChatGPT.app", isDirectory: true)
        let installer = DesktopInstallation(bundle: destination)
        assertEqual(try installer.installedApplication(), nil)
        assertThrows(try installer.install(from: source))
        assertTrue(!files.fileExists(atPath: destination.path))

        try files.createSymbolicLink(at: destination, withDestinationURL: source)
        assertThrows(try installer.installedApplication())
        assertThrows(try installer.install(from: source))
        assertTrue(files.fileExists(atPath: source.path))
    }

    func testOfficialAppCopyInTemporaryDirectory(_ source: URL) throws {
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = temporary.appendingPathComponent(".installing", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temporary) }
        let installer = DesktopInstallation(bundle: temporary.appendingPathComponent("ChatGPT.app"))
        let installed = try installer.install(from: source)
        assertTrue(DesktopInstallation.isOfficialApplication(source))
        assertTrue(DesktopInstallation.isOfficialApplication(installed))
        assertEqual(try installer.installedApplication(), installed)
        assertEqual(try installer.install(from: source), installed)
        assertTrue(!files.fileExists(atPath: staging.path))
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
