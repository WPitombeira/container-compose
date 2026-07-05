import Foundation

public enum ComposeConfigProjectionMode: String, Codable, CaseIterable, Sendable {
    case services
    case images
    case profiles
    case networks
    case volumes
    case models
    case environment
    case variables
}

public struct ComposeConfigProjection: Codable, Equatable, Sendable {
    public var mode: ComposeConfigProjectionMode
    public var values: [String]

    public init(mode: ComposeConfigProjectionMode, values: [String]) {
        self.mode = mode
        self.values = values
    }

    public static func values(
        for mode: ComposeConfigProjectionMode,
        in project: ComposeProject,
        interpolationEnvironment: [String: String] = [:],
        interpolationVariables: [ComposeInterpolationVariable] = []
    ) -> [String] {
        switch mode {
        case .services:
            return project.services.map(\.name)
        case .images:
            return stableUnique(project.services.compactMap(\.image))
        case .profiles:
            return stableUnique(project.services.flatMap(\.profiles)).sorted()
        case .networks:
            return project.networks.keys.sorted()
        case .volumes:
            return project.volumes.keys.sorted()
        case .models:
            return project.models.keys.sorted()
        case .environment:
            return environmentValues(interpolationEnvironment)
        case .variables:
            return variableValues(interpolationVariables)
        }
    }

    public static func project(_ project: ComposeProject, mode: ComposeConfigProjectionMode) -> ComposeConfigProjection {
        ComposeConfigProjection(mode: mode, values: values(for: mode, in: project))
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    public static func environmentValues(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().map { key in
            "\(key)=\(environment[key] ?? "")"
        }
    }

    public static func variableValues(_ variables: [ComposeInterpolationVariable]) -> [String] {
        variables
            .sorted { $0.name < $1.name }
            .map { variable in
                "\(variable.name)=\(variable.defaultValue ?? "")"
            }
    }
}
