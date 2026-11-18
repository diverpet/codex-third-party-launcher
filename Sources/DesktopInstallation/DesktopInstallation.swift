import Darwin
import Foundation
import Security

public enum DesktopInstallationError: LocalizedError {
    case invalidSource
    case invalidManagedCopy(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "Choose a verified OpenAI ChatGPT app that includes Codex."
        case let .invalidManagedCopy(bundle):
            return "The isolated app could not be verified. Quit it, move the copy at \(bundle.path) out of that folder, then open the launcher again."
        }
    }
}

public struct DesktopInstallation: Sendable {
    public static let officialBundleID = "com.openai.codex"
    public let bundle: URL

    public init(bundle: URL) {
        self.bundle = bundle
    }

    public static func isOfficialApplication(_ url: URL) -> Bool {
        guard let app = Bundle(url: url),
              app.bundleIdentifier == officialBundleID,
              let executable = app.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let policy = #"identifier "com.openai.codex" and anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2""#
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(policy as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    public func installedApplication() throws -> URL? {
        let manager = FileManager.default
        let parent = bundle.deletingLastPathComponent()
        try rejectSymlinks(parent, bundle)
        guard manager.fileExists(atPath: bundle.path) else { return nil }
        guard Self.isOfficialApplication(bundle) else {
            throw DesktopInstallationError.invalidManagedCopy(bundle)
        }
        return bundle
    }

    public func install(from source: URL) throws -> URL {
        let manager = FileManager.default
        let parent = bundle.deletingLastPathComponent()
        try rejectSymlinks(parent, bundle)
        try manager.createDirectory(at: parent, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let lock = parent.appendingPathComponent(".install.lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let staging = parent.appendingPathComponent(".installing", isDirectory: true)
        if manager.fileExists(atPath: staging.path) || isSymlink(staging) {
            try manager.removeItem(at: staging)
        }
        if let installed = try installedApplication() { return installed }
        let source = source.resolvingSymlinksInPath()
        guard Self.isOfficialApplication(source) else { throw DesktopInstallationError.invalidSource }

        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(bundle.lastPathComponent)
        try manager.copyItem(at: source, to: staged)
        guard Self.isOfficialApplication(staged) else { throw DesktopInstallationError.invalidSource }
        try manager.moveItem(at: staged, to: bundle)
        return bundle
    }

    private func rejectSymlinks(_ parent: URL, _ destination: URL) throws {
        guard !isSymlink(parent), !isSymlink(destination) else {
            throw DesktopInstallationError.invalidManagedCopy(bundle)
        }
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
