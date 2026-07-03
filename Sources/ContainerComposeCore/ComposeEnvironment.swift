import Foundation

public struct ComposeEnvironment: Sendable {
    public let composeFilePaths: [String]
    public let composeProfiles: [String]
    public let composeProjectName: String?

    public init(environment: [String: String]) {
        let pathSeparator = Self.pathSeparator(from: environment)
        composeFilePaths = Self.parseValues(
            from: environment["COMPOSE_FILE"],
            separatedBy: pathSeparator
        )
        composeProfiles = Self.parseValues(
            from: environment["COMPOSE_PROFILES"],
            separatedBy: ","
        )
        let projectName = environment["COMPOSE_PROJECT_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        composeProjectName = projectName?.isEmpty == false ? projectName : nil
    }

    private static func pathSeparator(from environment: [String: String]) -> String {
        environment["COMPOSE_PATH_SEPARATOR"]
        ?? defaultPathSeparator
    }

    private static func parseValues(from rawValue: String?, separatedBy separator: String) -> [String] {
        guard let rawValue else { return [] }
        return rawValue
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static var defaultPathSeparator: String {
        #if os(Windows)
        return ";"
        #else
        return ":"
        #endif
    }
}
