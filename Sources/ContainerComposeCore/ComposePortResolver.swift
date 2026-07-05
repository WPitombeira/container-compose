import Foundation

public struct ComposePortResolution: Codable, Equatable, Sendable {
    public var service: String
    public var privatePort: String
    public var publishedPort: String
    public var protocolValue: String
    public var hostIP: String?
    public var endpoint: String
    public var diagnostics: [ComposeDiagnostic]

    public init(
        service: String,
        privatePort: String,
        publishedPort: String,
        protocolValue: String = "tcp",
        hostIP: String? = nil,
        diagnostics: [ComposeDiagnostic] = []
    ) {
        self.service = service
        self.privatePort = privatePort
        self.publishedPort = publishedPort
        self.protocolValue = protocolValue
        self.hostIP = hostIP
        endpoint = "\(hostIP?.isEmpty == false ? hostIP! : "0.0.0.0"):\(publishedPort)"
        self.diagnostics = diagnostics
    }
}

public enum ComposePortResolutionError: Error, Equatable, LocalizedError, Sendable {
    case serviceNotFound(String)
    case publishedPortNotFound(service: String, privatePort: String, protocolValue: String)

    public var errorDescription: String? {
        switch self {
        case .serviceNotFound(let service):
            return "Service '\(service)' was not found in the Compose project."
        case .publishedPortNotFound(let service, let privatePort, let protocolValue):
            return "Service '\(service)' does not publish private port \(privatePort)/\(protocolValue)."
        }
    }
}

public struct ComposePortResolver: Sendable {
    public init() {}

    public func resolve(
        project: ComposeProject,
        serviceName: String,
        privatePort: String,
        protocolValue: String = "tcp",
        replicaIndex: Int = 1
    ) throws -> ComposePortResolution {
        guard let service = project.services.first(where: { $0.name == serviceName }) else {
            throw ComposePortResolutionError.serviceNotFound(serviceName)
        }

        let requested = normalizedPortAndProtocol(privatePort, defaultProtocol: protocolValue)
        var diagnostics: [ComposeDiagnostic] = []
        if replicaIndex != 1 {
            diagnostics.append(.init(
                severity: .warning,
                path: "port.index",
                message: "Docker Compose --index selects a specific service replica; static Compose port resolution uses the declared published port and does not inspect replica runtime state."
            ))
        }

        for port in service.ports {
            guard let binding = ComposePortBinding(port) else { continue }
            guard binding.protocolValue == requested.protocolValue else { continue }
            guard let publishedPort = binding.publishedPort(for: requested.port) else { continue }
            return ComposePortResolution(
                service: service.name,
                privatePort: requested.port,
                publishedPort: publishedPort,
                protocolValue: requested.protocolValue,
                hostIP: binding.hostIP,
                diagnostics: diagnostics
            )
        }

        throw ComposePortResolutionError.publishedPortNotFound(
            service: service.name,
            privatePort: requested.port,
            protocolValue: requested.protocolValue
        )
    }

    private func normalizedPortAndProtocol(_ value: String, defaultProtocol: String) -> (port: String, protocolValue: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.lastIndex(of: "/") else {
            return (trimmed, normalizedProtocol(defaultProtocol))
        }
        let port = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let protocolValue = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (port, normalizedProtocol(protocolValue.isEmpty ? defaultProtocol : protocolValue))
    }

    private func normalizedProtocol(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct ComposePortBinding {
    var hostIP: String?
    var published: String?
    var target: String
    var protocolValue: String

    init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (main, protocolValue) = Self.splitProtocol(trimmed)
        let parts = main.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            target = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        case 2:
            published = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            target = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            hostIP = parts.dropLast(2).joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
            published = parts[parts.count - 2].trimmingCharacters(in: .whitespacesAndNewlines)
            target = parts[parts.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !target.isEmpty else { return nil }
        self.protocolValue = protocolValue
    }

    func publishedPort(for privatePort: String) -> String? {
        guard let published, !published.isEmpty else { return nil }
        if target == privatePort {
            return published
        }

        guard
            let targetRange = PortRange(target),
            let publishedRange = PortRange(published),
            targetRange.count == publishedRange.count,
            let offset = targetRange.offset(of: privatePort)
        else {
            return nil
        }
        return String(publishedRange.start + offset)
    }

    private static func splitProtocol(_ value: String) -> (String, String) {
        guard let separator = value.lastIndex(of: "/") else {
            return (value, "tcp")
        }
        let main = String(value[..<separator])
        let protocolValue = String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (main, protocolValue.isEmpty ? "tcp" : protocolValue)
    }
}

private struct PortRange {
    var start: Int
    var end: Int

    init?(_ value: String) {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 1, let port = Int(parts[0]), port >= 0 {
            start = port
            end = port
            return
        }
        guard
            parts.count == 2,
            let start = Int(parts[0]),
            let end = Int(parts[1]),
            start >= 0,
            end >= start
        else {
            return nil
        }
        self.start = start
        self.end = end
    }

    var count: Int {
        end - start + 1
    }

    func offset(of value: String) -> Int? {
        guard let port = Int(value), port >= start, port <= end else {
            return nil
        }
        return port - start
    }
}
