import Foundation

public struct ComposeResourceKeys: Sendable {
    public init() {}

    public func portMergeKey(from rawValue: Any) -> String? {
        if let string = rawValue as? String {
            return parsePort(from: string)
        }
        guard let map = rawValue as? [String: Any] else {
            return nil
        }
        return parsePort(from: map)
    }

    public func volumeMergeKey(from rawValue: Any) -> String? {
        if let string = rawValue as? String {
            return parseVolume(from: string)
        }
        guard let map = rawValue as? [String: Any] else {
            return nil
        }
        return parseVolume(from: map)
    }

    public func configMergeKey(from rawValue: Any) -> String? {
        parseTargetResource(from: rawValue, defaultPrefix: "/")
    }

    public func secretMergeKey(from rawValue: Any) -> String? {
        parseTargetResource(from: rawValue, defaultPrefix: "/run/secrets/")
    }

    private func parsePort(from value: [String: Any]) -> String? {
        let target = stringValue(value["target"])
        let published = stringValue(value["published"])
        let explicitProtocolValue = stringValue(value["protocol"])?.lowercased()
        let ip = stringValue(value["host_ip"] ?? value["hostIP"] ?? value["ip"])

        guard target != nil || published != nil || explicitProtocolValue != nil || ip != nil else {
            return nil
        }

        let protocolValue = explicitProtocolValue ?? "tcp"
        let key = composePortMergeKey(ip: ip, target: target, published: published, protocolValue: protocolValue)
        return key.isEmpty ? nil : key
    }

    private func parsePort(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parsed = parseShortPortSyntax(trimmed)
        let key = composePortMergeKey(ip: parsed.ip, target: parsed.target, published: parsed.published, protocolValue: parsed.protocolValue)
        return key.isEmpty ? nil : key
    }

    private func parseVolume(from value: [String: Any]) -> String? {
        if let target = stringValue(value["target"])?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
            return target
        }

        if let source = stringValue(value["source"])?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
            return source
        }

        return nil
    }

    private func parseVolume(from value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }

        if parts.count >= 2 {
            let target = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty {
                return target
            }
        }

        return String(first).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseTargetResource(from rawValue: Any, defaultPrefix: String) -> String? {
        if let string = rawValue as? String {
            return defaultTarget(for: string, defaultPrefix: defaultPrefix)
        }
        guard let map = rawValue as? [String: Any] else {
            return nil
        }
        if let target = stringValue(map["target"]) {
            return target.hasPrefix("/") ? target : "\(defaultPrefix)\(target)"
        }
        guard let source = stringValue(map["source"]) else {
            return nil
        }
        return defaultTarget(for: source, defaultPrefix: defaultPrefix)
    }

    private func defaultTarget(for source: String, defaultPrefix: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(defaultPrefix)\(trimmed)"
    }

    private func composePortMergeKey(ip: String?, target: String?, published: String?, protocolValue: String?) -> String {
        var components: [String] = []
        if let ip, !ip.isEmpty {
            components.append("ip=\(ip)")
        }
        if let target, !target.isEmpty {
            components.append("target=\(target)")
        }
        if let published, !published.isEmpty {
            components.append("published=\(published)")
        }
        if let protocolValue, !protocolValue.isEmpty {
            components.append("protocol=\(protocolValue)")
        }
        return components.joined(separator: ";")
    }

    private func parseShortPortSyntax(_ value: String) -> ParsedPort {
        let (main, protocolValue) = splitHostProtocol(value)

        let parts = main.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return .init() }

        switch parts.count {
        case 1:
            return ParsedPort(
                ip: nil,
                target: String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines),
                published: nil,
                protocolValue: protocolValue ?? "tcp"
            )
        case 2:
            let published = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let target = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedPort(
                ip: nil,
                target: target.isEmpty ? nil : target,
                published: published.isEmpty ? nil : published,
                protocolValue: protocolValue ?? "tcp"
            )
        case 3:
            let ip = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let published = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let target = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedPort(
                ip: ip.isEmpty ? nil : ip,
                target: target.isEmpty ? nil : target,
                published: published.isEmpty ? nil : published,
                protocolValue: protocolValue ?? "tcp"
            )
        default:
            return .init(protocolValue: protocolValue ?? "tcp")
        }
    }

    private func splitHostProtocol(_ value: String) -> (String, String?) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let delimiter = normalized.lastIndex(of: "/")
        guard let delimiter else {
            return (normalized, nil)
        }

        let protocolCandidate = String(normalized[normalized.index(after: delimiter)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let knownProtocols: Set<String> = ["tcp", "udp", "sctp"]
        let normalizedProtocol = protocolCandidate.lowercased()
        guard knownProtocols.contains(normalizedProtocol), !protocolCandidate.isEmpty else {
            return (normalized, nil)
        }

        let core = String(normalized[..<delimiter])
        return (core, normalizedProtocol)
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let int as Int:
            return String(int)
        case let double as Double:
            let asInt = Int(double)
            return Double(asInt) == double ? String(asInt) : String(double)
        default:
            return nil
        }
    }

    private struct ParsedPort: Sendable {
        var ip: String?
        var target: String?
        var published: String?
        var protocolValue: String?

        init(ip: String? = nil, target: String? = nil, published: String? = nil, protocolValue: String? = nil) {
            self.ip = ip
            self.target = target
            self.published = published
            self.protocolValue = protocolValue
        }
    }
}
