import Foundation

public enum DiagnosticSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct ComposeDiagnostic: Codable, Equatable, Sendable {
    public let severity: DiagnosticSeverity
    public let path: String
    public let code: String?
    public let message: String

    public init(severity: DiagnosticSeverity, path: String, message: String, code: String? = nil) {
        self.severity = severity
        self.path = path
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case severity
        case path
        case code
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        severity = try container.decode(DiagnosticSeverity.self, forKey: .severity)
        path = try container.decode(String.self, forKey: .path)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
    }
}

public enum ComposeLoadError: Error, LocalizedError {
    case fileNotFound([String])
    case invalidRoot
    case missingServices
    case invalidService(String)
    case invalidValue(path: String, expected: String)
    case recursiveInclude(String)
    case remoteIncludeDisabled(String)
    case remoteIncludeFetchFailed(String, String)
    case requiredEnvironmentVariable(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let candidates):
            return "No Compose file found. Checked: \(candidates.joined(separator: ", "))."
        case .invalidRoot:
            return "Compose file root must be a YAML mapping."
        case .missingServices:
            return "Compose file must define a services mapping."
        case .invalidService(let name):
            return "Service '\(name)' must be a mapping."
        case .invalidValue(let path, let expected):
            return "Invalid value at \(path). Expected \(expected)."
        case .recursiveInclude(let path):
            return "Recursive Compose include detected for \(path)."
        case .remoteIncludeDisabled(let url):
            return "Remote Compose include is disabled for \(url)."
        case .remoteIncludeFetchFailed(let url, let message):
            return "Failed to fetch remote Compose include \(url): \(message)"
        case .requiredEnvironmentVariable(let message):
            return message
        }
    }
}
