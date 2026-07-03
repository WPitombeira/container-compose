import Foundation
import Yams

public enum ComposeConfigRenderFormat: String, Codable, CaseIterable, Sendable {
    case json
    case yaml
}

public enum ComposeConfigRenderError: Error, LocalizedError {
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let value):
            return "Unsupported config format '\(value)'. Expected one of: json, yaml."
        }
    }
}

public struct ComposeConfigRenderer: Sendable {
    public init() {}

    public func render<T: Encodable>(_ value: T, format: ComposeConfigRenderFormat) throws -> String {
        switch format {
        case .json:
            return try renderJSON(value)
        case .yaml:
            return try renderYAML(value)
        }
    }

    public func renderJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public func renderYAML<T: Encodable>(_ value: T) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        return try encoder.encode(value)
    }

    public static func parseFormat(_ value: String) throws -> ComposeConfigRenderFormat {
        guard let format = ComposeConfigRenderFormat(rawValue: value.lowercased()) else {
            throw ComposeConfigRenderError.unsupportedFormat(value)
        }
        return format
    }
}
