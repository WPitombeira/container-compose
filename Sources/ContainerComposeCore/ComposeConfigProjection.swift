import Foundation

public enum ComposeConfigProjectionMode: String, Codable, CaseIterable, Sendable {
    case services
    case images
    case profiles
    case networks
    case volumes
    case models
}

public struct ComposeConfigProjection: Codable, Equatable, Sendable {
    public var mode: ComposeConfigProjectionMode
    public var values: [String]

    public init(mode: ComposeConfigProjectionMode, values: [String]) {
        self.mode = mode
        self.values = values
    }

    public static func values(for mode: ComposeConfigProjectionMode, in project: ComposeProject) -> [String] {
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
}
