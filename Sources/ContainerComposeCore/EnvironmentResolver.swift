import Foundation

public struct EnvironmentResolver: Sendable {
    private let processEnvironment: [String: String]
    private let envFileValues: [String: String]

    public init(
        workingDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        envFiles: [String]? = nil
    ) {
        let directoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        self.processEnvironment = environment
        if let envFiles {
            self.envFileValues = envFiles.reduce(into: [:]) { values, path in
                let fileURL = URL(fileURLWithPath: path, relativeTo: directoryURL).standardizedFileURL
                values.merge(Self.loadDotEnvValues(from: fileURL)) { _, new in new }
            }
        } else {
            self.envFileValues = Self.loadDotEnvValues(from: directoryURL.appendingPathComponent(".env"))
        }
    }

    public init(
        workingDirectoryURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        envFiles: [String]? = nil
    ) {
        self.init(workingDirectory: workingDirectoryURL.path, environment: environment, envFiles: envFiles)
    }

    public func resolve(_ text: String) -> String {
        (try? resolveWithDiagnostics(text).text) ?? text
    }

    public var interpolationEnvironment: [String: String] {
        envFileValues.merging(processEnvironment) { _, processValue in processValue }
    }

    public func resolveWithDiagnostics(_ text: String) throws -> EnvironmentResolution {
        let chars = Array(text)
        guard !chars.isEmpty else {
            return EnvironmentResolution(text: text, diagnostics: [])
        }

        var output = ""
        var diagnostics: [ComposeDiagnostic] = []
        var index = 0

        while index < chars.count {
            guard chars[index] == "$" else {
                output.append(chars[index])
                index += 1
                continue
            }

            if index + 1 >= chars.count {
                output.append(chars[index])
                index += 1
                continue
            }

            if chars[index + 1] == "$" {
                output.append("$")
                index += 2
                continue
            }

            if chars[index + 1] == "{" {
                guard let closeIndex = closingBraceIndex(in: chars, openingBraceIndex: index + 1) else {
                    output.append("${")
                    index += 2
                    continue
                }

                let token = String(chars[(index + 2)..<closeIndex])
                guard let replacement = try resolveToken(token, diagnostics: &diagnostics) else {
                    output.append(contentsOf: "${\(token)}")
                    index = closeIndex + 1
                    continue
                }
                output.append(contentsOf: replacement)
                index = closeIndex + 1
                continue
            }

            let nameStart = index + 1
            guard let nameEnd = variableNameEnd(in: chars, startingAt: nameStart) else {
                output.append(chars[index])
                index += 1
                continue
            }

            let name = String(chars[nameStart..<nameEnd])
            if let value = value(for: name), !value.isEmpty {
                output.append(value)
            } else {
                diagnostics.append(unsetVariableDiagnostic(name: name))
            }
            index = nameEnd
        }

        return EnvironmentResolution(text: output, diagnostics: diagnostics)
    }

    private func resolveToken(_ token: String, diagnostics: inout [ComposeDiagnostic]) throws -> String? {
        let expression = parseExpression(token)
        guard let expression else { return nil }

        let value = value(for: expression.name)

        switch expression.operatorKind {
        case .none:
            if let value {
                return value
            }
            diagnostics.append(unsetVariableDiagnostic(name: expression.name))
            return ""
        case .colonDash:
            if let value, !value.isEmpty {
                return value
            }
            return try resolveWithDiagnostics(expression.value).text
        case .dash:
            if let value {
                return value
            }
            return try resolveWithDiagnostics(expression.value).text
        case .colonPlus:
            if let value, !value.isEmpty {
                return try resolveWithDiagnostics(expression.value).text
            }
            return ""
        case .plus:
            if value != nil {
                return try resolveWithDiagnostics(expression.value).text
            }
            return ""
        case .colonQuestion:
            if let value, !value.isEmpty {
                return value
            }
            let message = try resolveWithDiagnostics(expression.value).text
            throw ComposeLoadError.requiredEnvironmentVariable(requiredVariableMessage(name: expression.name, message: message))
        case .question:
            if let value {
                return value
            }
            let message = try resolveWithDiagnostics(expression.value).text
            throw ComposeLoadError.requiredEnvironmentVariable(requiredVariableMessage(name: expression.name, message: message))
        }
    }

    private func parseExpression(_ token: String) -> Expression? {
        if let range = token.range(of: ":+") {
            let name = String(token[..<range.lowerBound])
            guard Self.isValidVariableName(name) else { return nil }
            let value = String(token[range.upperBound...])
            return Expression(name: name, operatorKind: .colonPlus, value: value)
        }

        if let range = token.range(of: ":?") {
            let name = String(token[..<range.lowerBound])
            guard Self.isValidVariableName(name) else { return nil }
            let value = String(token[range.upperBound...])
            return Expression(name: name, operatorKind: .colonQuestion, value: value)
        }

        if let range = token.range(of: ":-") {
            let name = String(token[..<range.lowerBound])
            guard Self.isValidVariableName(name) else { return nil }
            let value = String(token[range.upperBound...])
            return Expression(name: name, operatorKind: .colonDash, value: value)
        }

        if let range = token.range(of: "?") {
            let name = String(token[..<range.lowerBound])
            guard Self.isValidVariableName(name) else { return nil }
            let value = String(token[range.upperBound...])
            return Expression(name: name, operatorKind: .question, value: value)
        }

        if let range = token.range(of: "+") {
            let name = String(token[..<range.lowerBound])
            guard Self.isValidVariableName(name) else { return nil }
            let value = String(token[range.upperBound...])
            return Expression(name: name, operatorKind: .plus, value: value)
        }

        if let range = token.range(of: "-") {
            let name = String(token[..<range.lowerBound])
            guard Self.isValidVariableName(name) else { return nil }
            let value = String(token[range.upperBound...])
            return Expression(name: name, operatorKind: .dash, value: value)
        }

        guard Self.isValidVariableName(token) else { return nil }
        return Expression(name: token, operatorKind: .none, value: "")
    }

    private func value(for name: String) -> String? {
        processEnvironment[name] ?? envFileValues[name]
    }

    private func unsetVariableDiagnostic(name: String) -> ComposeDiagnostic {
        ComposeDiagnostic(
            severity: .warning,
            path: "environment.\(name)",
            message: "The \(name) variable is not set. Defaulting to a blank string."
        )
    }

    private func requiredVariableMessage(name: String, message: String) -> String {
        if message.isEmpty {
            return "Required environment variable \(name) is not set."
        }
        return "Required environment variable \(name) is not set: \(message)"
    }

    private func closingBraceIndex(in chars: [Character], openingBraceIndex: Int) -> Int? {
        var depth = 1
        var current = openingBraceIndex + 1
        while current < chars.count {
            if chars[current] == "$", current + 1 < chars.count, chars[current + 1] == "{" {
                depth += 1
                current += 2
                continue
            }
            if chars[current] == "}" {
                depth -= 1
                if depth == 0 {
                    return current
                }
            }
            current += 1
        }
        return nil
    }

    private func variableNameEnd(in chars: [Character], startingAt startIndex: Int) -> Int? {
        guard startIndex < chars.count else { return nil }
        let first = chars[startIndex]
        guard Self.isValidVariableFirstCharacter(first) else { return nil }

        var current = startIndex + 1
        while current < chars.count, Self.isValidVariableCharacter(chars[current]) {
            current += 1
        }
        return current
    }

    private static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.first, isValidVariableFirstCharacter(first) else { return false }
        return name.allSatisfy { character in
            isValidVariableCharacter(character)
        }
    }

    private static func isValidVariableFirstCharacter(_ character: Character) -> Bool {
        character == "_" || character.isASCIIAlpha
    }

    private static func isValidVariableCharacter(_ character: Character) -> Bool {
        character == "_" || character.isASCIIAlpha || character.isASCIIDigit
    }

    private static func loadDotEnvValues(from fileURL: URL) -> [String: String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }
        return parseDotEnv(content)
    }

    private static func parseDotEnv(_ content: String) -> [String: String] {
        var values: [String: String] = [:]

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty && !line.hasPrefix("#") else { continue }

            var declaration = line
            if declaration.hasPrefix("export ") {
                declaration = declaration
                    .dropFirst("export ".count)
                    .trimmingCharacters(in: .whitespaces)
            }

            guard let equalIndex = declaration.firstIndex(of: "=") else { continue }
            let rawKey = String(declaration[..<equalIndex]).trimmingCharacters(in: .whitespaces)
            guard Self.isValidVariableName(rawKey) else { continue }

            let rawValue = String(declaration[declaration.index(after: equalIndex)...])
            values[rawKey] = unquote(rawValue)
        }

        return values
    }

    private static func unquote(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespaces)
        if (normalized.hasPrefix("\"") && normalized.hasSuffix("\"")) ||
            (normalized.hasPrefix("'") && normalized.hasSuffix("'")) {
            normalized = String(normalized.dropFirst().dropLast())
        }
        return normalized
    }

    private enum Operator {
        case none
        case colonDash
        case dash
        case colonPlus
        case plus
        case colonQuestion
        case question
    }

    private struct Expression {
        let name: String
        let operatorKind: Operator
        let value: String
    }
}

public struct EnvironmentResolution: Equatable, Sendable {
    public let text: String
    public let diagnostics: [ComposeDiagnostic]
}

private extension Character {
    var isASCIIAlpha: Bool {
        guard let ascii = String(self).utf8.first else { return false }
        return (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122)
    }

    var isASCIIDigit: Bool {
        guard let ascii = String(self).utf8.first else { return false }
        return ascii >= 48 && ascii <= 57
    }
}
