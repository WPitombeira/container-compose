import Foundation
import CryptoKit

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

public enum ComposeConfigProjectionError: Error, LocalizedError, Equatable, Sendable {
    case noSuchService(String)

    public var errorDescription: String? {
        switch self {
        case .noSuchService(let service):
            return "no such service: \(service): not found"
        }
    }
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

    public static func serviceHashValues(in project: ComposeProject, target: String) throws -> [String] {
        let services: [ComposeService]
        if target == "*" {
            services = project.services
        } else if let service = project.services.first(where: { $0.name == target }) {
            services = [service]
        } else {
            throw ComposeConfigProjectionError.noSuchService(target)
        }

        return try services.map { service in
            "\(service.name) \(try serviceConfigHash(service))"
        }
    }

    public static func serviceConfigHash(_ service: ComposeService) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(service)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
