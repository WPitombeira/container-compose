import Foundation
import Yams

public struct ComposeSource: Equatable, Sendable {
    public var path: String
    public var yaml: String?

    public init(path: String, yaml: String? = nil) {
        self.path = path
        self.yaml = yaml
    }
}

public struct ComposeLoader: Sendable {
    public typealias RemoteIncludeFetcher = @Sendable (URL) throws -> String
    public typealias RemoteIncludeResolver = @Sendable (RemoteIncludeRequest) throws -> RemoteIncludeResponse

    public struct RemoteIncludeRequest: Equatable, Sendable {
        public var url: URL
        public var sanitizedURL: String
        public var includedFrom: String?
        public var includeStack: [String]

        public init(
            url: URL,
            sanitizedURL: String,
            includedFrom: String? = nil,
            includeStack: [String] = []
        ) {
            self.url = url
            self.sanitizedURL = sanitizedURL
            self.includedFrom = includedFrom
            self.includeStack = includeStack
        }
    }

    public struct RemoteIncludeResponse: Equatable, Sendable {
        public var yaml: String
        public var cacheKey: String?
        public var cacheStatus: ComposeRemoteIncludeCacheStatus
        public var source: String?

        public init(
            yaml: String,
            cacheKey: String? = nil,
            cacheStatus: ComposeRemoteIncludeCacheStatus = .unknown,
            source: String? = nil
        ) {
            self.yaml = yaml
            self.cacheKey = cacheKey
            self.cacheStatus = cacheStatus
            self.source = source
        }
    }

    private let environment: [String: String]
    private let envFiles: [String]?
    private let interpolate: Bool
    private let remoteIncludeResolver: RemoteIncludeResolver
    private let allowRemoteIncludes: Bool

    public static let defaultFileNames = [
        "compose.yaml",
        "compose.yml",
        "docker-compose.yaml",
        "docker-compose.yml"
    ]

    public static let defaultOverrideFileNames = [
        "compose.override.yaml",
        "compose.override.yml",
        "docker-compose.override.yaml",
        "docker-compose.override.yml"
    ]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        envFiles: [String]? = nil,
        interpolate: Bool = true,
        allowRemoteIncludes: Bool = false,
        remoteIncludeFetcher: RemoteIncludeFetcher? = nil
    ) {
        self.environment = environment
        self.envFiles = envFiles
        self.interpolate = interpolate
        self.allowRemoteIncludes = allowRemoteIncludes
        let fetcher = remoteIncludeFetcher ?? { url in
            try Self.fetchRemoteInclude(from: url)
        }
        self.remoteIncludeResolver = { request in
            try RemoteIncludeResponse(yaml: fetcher(request.url))
        }
    }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        envFiles: [String]? = nil,
        interpolate: Bool = true,
        allowRemoteIncludes: Bool = false,
        remoteIncludeResolver: @escaping RemoteIncludeResolver
    ) {
        self.environment = environment
        self.envFiles = envFiles
        self.interpolate = interpolate
        self.allowRemoteIncludes = allowRemoteIncludes
        self.remoteIncludeResolver = remoteIncludeResolver
    }

    public func load(
        from path: String? = nil,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        activeProfiles: Set<String> = [],
        targetedServices: Set<String> = []
    ) throws -> ComposeProject {
        let paths = try resolveComposePaths(paths: path.map { [$0] }, workingDirectory: workingDirectory)
        return try load(
            from: paths,
            workingDirectory: workingDirectory,
            activeProfiles: activeProfiles,
            targetedServices: targetedServices
        )
    }

    public func load(
        from paths: [String],
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        activeProfiles: Set<String> = [],
        targetedServices: Set<String> = []
    ) throws -> ComposeProject {
        let resolvedPaths = try resolveComposePaths(paths: paths, workingDirectory: workingDirectory)
        return try load(
            from: resolvedPaths.map { ComposeSource(path: $0) },
            workingDirectory: workingDirectory,
            activeProfiles: activeProfiles,
            targetedServices: targetedServices
        )
    }

    public func load(
        from sources: [ComposeSource],
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        activeProfiles: Set<String> = [],
        targetedServices: Set<String> = []
    ) throws -> ComposeProject {
        let resolvedSources = sources.map {
            ComposeSource(path: resolvePath($0.path, relativeTo: workingDirectory), yaml: $0.yaml)
        }
        let resolvedPaths = resolvedSources.map(\.path)
        let loaded = try loadMergedRootWithIncludes(from: resolvedSources)

        var diagnostics = loaded.diagnostics
        let resolvedIncludes = try resolveIncludes(
            in: loaded.root,
            includeEntries: loaded.includeEntries,
            diagnostics: &diagnostics,
            stack: Set(resolvedPaths),
            includeStack: resolvedPaths
        )
        let normalizedRoot = normalizeResidualMergeTags(resolvedIncludes.root) as? [String: Any] ?? resolvedIncludes.root

        return try load(
            root: normalizedRoot,
            sourcePath: resolvedPaths[0],
            activeProfiles: activeProfiles,
            targetedServices: targetedServices,
            inheritedDiagnostics: diagnostics,
            inheritedRemoteIncludes: loaded.remoteIncludes + resolvedIncludes.remoteIncludes
        )
    }

    public func load(
        yaml: String,
        sourcePath: String = "compose.yaml",
        activeProfiles: Set<String> = [],
        targetedServices: Set<String> = []
    ) throws -> ComposeProject {
        let resolvedSourcePath = normalizeSourcePath(sourcePath)
        var diagnostics: [ComposeDiagnostic] = []
        var root = try loadRawRoot(yaml: yaml, sourcePath: sourcePath, diagnostics: &diagnostics)
        let includeEntries = parseIncludeEntries(
            root.removeValue(forKey: "include"),
            sourcePath: resolvedSourcePath,
            diagnostics: &diagnostics
        )
        let resolvedIncludes = try resolveIncludes(
            in: root,
            includeEntries: includeEntries,
            diagnostics: &diagnostics,
            stack: [resolvedSourcePath],
            includeStack: [resolvedSourcePath]
        )
        root = resolvedIncludes.root
        root = normalizeResidualMergeTags(root) as? [String: Any] ?? root
        return try load(
            root: root,
            sourcePath: sourcePath,
            activeProfiles: activeProfiles,
            targetedServices: targetedServices,
            inheritedDiagnostics: diagnostics,
            inheritedRemoteIncludes: resolvedIncludes.remoteIncludes
        )
    }

    private func loadRawRoot(
        yaml: String,
        sourcePath: String,
        diagnostics: inout [ComposeDiagnostic],
        envFiles: [String]? = nil
    ) throws -> [String: Any] {
        guard let rawNode = try Yams.compose(yaml: yaml) else {
            throw ComposeLoadError.invalidRoot
        }
        let raw = convertYamlNode(rawNode)
        guard let root = raw as? [String: Any] else {
            throw ComposeLoadError.invalidRoot
        }
        guard interpolate else {
            return root
        }
        let resolver = EnvironmentResolver(
            workingDirectory: environmentWorkingDirectory(for: sourcePath),
            environment: environment,
            envFiles: envFiles ?? self.envFiles
        )
        guard let interpolatedRoot = try interpolateParsedValue(root, resolver: resolver, diagnostics: &diagnostics) as? [String: Any] else {
            throw ComposeLoadError.invalidRoot
        }
        return interpolatedRoot
    }

    private func convertYamlNode(_ node: Node) -> Any {
        let converted = convertYamlNodePayload(node)
        if let tagKind = composeMergeTagKind(node.tag) {
            return ComposeTaggedValue(kind: tagKind, value: converted)
        }
        return converted
    }

    private func convertYamlNodePayload(_ node: Node) -> Any {
        switch node {
        case let .scalar(scalar):
            var untagged = scalar
            untagged.tag = .implicit
            return Node.scalar(untagged).any
        case let .sequence(sequence):
            return sequence.map(convertYamlNode)
        case let .mapping(mapping):
            return mapping.reduce(into: [String: Any]()) { result, pair in
                guard let key = pair.key.string else { return }
                result[key] = convertYamlNode(pair.value)
            }
        case .alias:
            return node.any
        }
    }

    private func composeMergeTagKind(_ tag: Tag) -> ComposeTaggedValue.Kind? {
        let rawValue = tag.rawValue
        if rawValue == "!reset" || rawValue.hasSuffix("!reset") || rawValue.hasSuffix(":reset") {
            return .reset
        }
        if rawValue == "!override" || rawValue.hasSuffix("!override") || rawValue.hasSuffix(":override") {
            return .override
        }
        return nil
    }

    private func interpolateParsedValue(
        _ value: Any,
        resolver: EnvironmentResolver,
        diagnostics: inout [ComposeDiagnostic]
    ) throws -> Any {
        if let taggedValue = value as? ComposeTaggedValue {
            return ComposeTaggedValue(
                kind: taggedValue.kind,
                value: try interpolateParsedValue(taggedValue.value, resolver: resolver, diagnostics: &diagnostics)
            )
        }

        if let string = value as? String {
            let resolution = try resolver.resolveWithDiagnostics(string)
            diagnostics.append(contentsOf: resolution.diagnostics)
            return resolution.text
        }

        if let list = value as? [Any] {
            return try list.map { item in
                try interpolateParsedValue(item, resolver: resolver, diagnostics: &diagnostics)
            }
        }

        if let map = value as? [String: Any] {
            var result: [String: Any] = [:]
            for key in map.keys.sorted() {
                guard let nestedValue = map[key] else { continue }
                result[key] = try interpolateParsedValue(nestedValue, resolver: resolver, diagnostics: &diagnostics)
            }
            return result
        }

        return value
    }

    private func load(
        root: [String: Any],
        sourcePath: String,
        activeProfiles: Set<String>,
        targetedServices: Set<String>,
        inheritedDiagnostics: [ComposeDiagnostic] = [],
        inheritedRemoteIncludes: [ComposeRemoteInclude] = []
    ) throws -> ComposeProject {
        guard let rawServicesRoot = root["services"] as? [String: Any] else {
            throw ComposeLoadError.missingServices
        }

        var diagnostics = inheritedDiagnostics
        diagnostics.append(contentsOf: warnForUnsupportedTopLevel(root))
        let servicesRoot = resolveServiceExtends(
            in: rawServicesRoot,
            sourcePath: sourcePath,
            diagnostics: &diagnostics
        )

        let projectName = root["name"] as? String ?? defaultProjectName(from: sourcePath)
        var networks = parseNetworks(root["networks"], diagnostics: &diagnostics)
        let volumes = parseVolumes(root["volumes"], diagnostics: &diagnostics)
        let configs = parseConfigs(root["configs"], diagnostics: &diagnostics)
        let secrets = parseSecrets(root["secrets"], diagnostics: &diagnostics)
        let models = parseModels(root["models"], diagnostics: &diagnostics)
        let allServices = try servicesRoot.keys.sorted().map { serviceName -> ComposeService in
            guard let mapping = servicesRoot[serviceName] as? [String: Any] else {
                throw ComposeLoadError.invalidService(serviceName)
            }
            return try parseService(name: serviceName, mapping: mapping, sourcePath: sourcePath, diagnostics: &diagnostics)
        }
        let effectiveProfiles = activeProfiles.union(profilesActivatedByTargets(
            targetedServices,
            services: allServices
        ))
        let services = allServices.filter { service in
            service.profiles.isEmpty
            || !effectiveProfiles.isDisjoint(with: service.profiles)
            || targetedServices.contains(service.name)
        }
        diagnostics.append(contentsOf: missingDependencyDiagnostics(for: services, allServices: allServices))
        diagnostics.append(contentsOf: duplicateContainerNameDiagnostics(for: services, projectName: projectName))
        ensureImplicitDefaultNetwork(for: services, networks: &networks)

        return ComposeProject(
            name: projectName,
            services: services,
            networks: networks,
            volumes: volumes,
            configs: configs,
            secrets: secrets,
            models: models,
            remoteIncludes: inheritedRemoteIncludes,
            diagnostics: diagnostics,
            sourcePath: sourcePath
        )
    }

    private func resolveServiceExtends(
        in servicesRoot: [String: Any],
        sourcePath: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String: Any] {
        let rootSourcePath = normalizeSourcePath(sourcePath)
        var servicesBySource: [String: [String: Any]] = [rootSourcePath: servicesRoot]
        var resolved: [ServiceExtendsKey: [String: Any]] = [:]
        var resolving: Set<ServiceExtendsKey> = []

        func loadServices(
            from targetSourcePath: String,
            referencedFrom referencingSourcePath: String,
            serviceName: String
        ) -> [String: Any]? {
            if let services = servicesBySource[targetSourcePath] {
                return services
            }

            do {
                var fileDiagnostics: [ComposeDiagnostic] = []
                let source = try loadComposeSource(
                    targetSourcePath,
                    includedFrom: referencingSourcePath,
                    includeStack: [referencingSourcePath]
                )
                var root = try loadRawRoot(
                    yaml: source.yaml,
                    sourcePath: targetSourcePath,
                    diagnostics: &fileDiagnostics
                )
                diagnostics.append(contentsOf: fileDiagnostics)
                root = normalizeResidualMergeTags(root) as? [String: Any] ?? root

                guard let services = root["services"] as? [String: Any] else {
                    diagnostics.append(.init(
                        severity: .error,
                        path: "services.\(serviceName).extends.file",
                        message: "Extended Compose file does not define services: \(targetSourcePath)"
                    ))
                    return nil
                }

                servicesBySource[targetSourcePath] = services
                return services
            } catch {
                diagnostics.append(.init(
                    severity: .error,
                    path: "services.\(serviceName).extends.file",
                    message: "Extended Compose file could not be loaded: \(targetSourcePath) (\(error))"
                ))
                return nil
            }
        }

        func resolve(_ serviceName: String, sourcePath currentSourcePath: String) -> [String: Any]? {
            let key = ServiceExtendsKey(sourcePath: currentSourcePath, service: serviceName)
            if let existing = resolved[key] {
                return existing
            }

            guard let currentServicesRoot = servicesBySource[currentSourcePath],
                  var mapping = currentServicesRoot[serviceName] as? [String: Any] else {
                return nil
            }

            guard let rawExtends = mapping.removeValue(forKey: "extends") else {
                resolved[key] = mapping
                return mapping
            }

            guard !resolving.contains(key) else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "services.\(serviceName).extends",
                    message: "Circular service extends reference detected."
                ))
                resolved[key] = mapping
                return mapping
            }

            guard let reference = parseExtendsReference(
                rawExtends,
                serviceName: serviceName,
                diagnostics: &diagnostics
            ) else {
                resolved[key] = mapping
                return mapping
            }

            let referenceSourcePath: String
            if let file = reference.file, !file.isEmpty {
                referenceSourcePath = normalizeSourcePath(resolvePath(
                    file,
                    relativeTo: containingDirectory(for: currentSourcePath)
                ))
                guard loadServices(
                    from: referenceSourcePath,
                    referencedFrom: currentSourcePath,
                    serviceName: serviceName
                ) != nil else {
                    resolved[key] = mapping
                    return mapping
                }
            } else {
                referenceSourcePath = currentSourcePath
            }

            guard let targetServicesRoot = servicesBySource[referenceSourcePath],
                  targetServicesRoot[reference.service] != nil else {
                let location = referenceSourcePath == currentSourcePath ? "the current Compose file" : referenceSourcePath
                diagnostics.append(.init(
                    severity: .error,
                    path: "services.\(serviceName).extends.service",
                    message: "Extended service '\(reference.service)' is not defined in \(location)."
                ))
                resolved[key] = mapping
                return mapping
            }

            resolving.insert(key)
            defer { resolving.remove(key) }

            guard var base = resolve(reference.service, sourcePath: referenceSourcePath) else {
                resolved[key] = mapping
                return mapping
            }

            if referenceSourcePath != currentSourcePath {
                base = rewriteRelativeServicePaths(base, from: referenceSourcePath, to: currentSourcePath)
            }

            diagnostics.append(contentsOf: validateExtendsHealthcheckMerge(
                base: base,
                override: mapping,
                serviceName: serviceName
            ))
            let merged = merge(base: base, override: mapping, path: ["services", serviceName])
            resolved[key] = merged
            return merged
        }

        for serviceName in servicesRoot.keys.sorted() {
            _ = resolve(serviceName, sourcePath: rootSourcePath)
        }

        return servicesRoot.reduce(into: [:]) { result, pair in
            let key = ServiceExtendsKey(sourcePath: rootSourcePath, service: pair.key)
            result[pair.key] = resolved[key] ?? pair.value
        }
    }

    private func validateExtendsHealthcheckMerge(
        base: [String: Any],
        override: [String: Any],
        serviceName: String
    ) -> [ComposeDiagnostic] {
        guard healthcheckIsEffectivelyDisabled(in: override) else { return [] }
        guard !healthcheckIsEffectivelyDisabled(in: base) else { return [] }
        return [
            .init(
                severity: .error,
                path: healthcheckDisableDiagnosticPath(in: override, serviceName: serviceName),
                message: "A service extending another service cannot newly disable healthchecks unless the referenced service also disables healthchecks."
            )
        ]
    }

    private func healthcheckIsEffectivelyDisabled(in mapping: [String: Any]) -> Bool {
        guard let healthcheck = mapping["healthcheck"] as? [String: Any] else { return false }
        return parseBool(healthcheck["disable"]) == true || healthcheckTestDisables(healthcheck["test"])
    }

    private func healthcheckDisableDiagnosticPath(in mapping: [String: Any], serviceName: String) -> String {
        guard let healthcheck = mapping["healthcheck"] as? [String: Any] else {
            return "services.\(serviceName).healthcheck"
        }
        if parseBool(healthcheck["disable"]) == true {
            return "services.\(serviceName).healthcheck.disable"
        }
        if healthcheckTestDisables(healthcheck["test"]) {
            return "services.\(serviceName).healthcheck.test"
        }
        return "services.\(serviceName).healthcheck"
    }

    private func healthcheckTestDisables(_ value: Any?) -> Bool {
        guard let list = value as? [Any],
              let first = list.compactMap({ stringify($0) }).first else {
            return false
        }
        return first.uppercased() == "NONE"
    }

    private func rewriteRelativeServicePaths(
        _ mapping: [String: Any],
        from sourcePath: String,
        to targetSourcePath: String
    ) -> [String: Any] {
        let sourceDirectory = containingDirectory(for: sourcePath)
        let targetDirectory = containingDirectory(for: targetSourcePath)
        var result = mapping

        if let envFile = result["env_file"] {
            result["env_file"] = rewriteRelativePathValue(
                envFile,
                from: sourceDirectory,
                to: targetDirectory
            )
        }

        if let labelFile = result["label_file"] {
            result["label_file"] = rewriteRelativePathValue(
                labelFile,
                from: sourceDirectory,
                to: targetDirectory
            )
        }

        if let build = result["build"] {
            if let context = stringify(build) {
                result["build"] = rewriteRelativePath(context, from: sourceDirectory, to: targetDirectory)
            } else if var buildMap = build as? [String: Any] {
                if let context = stringify(buildMap["context"]) {
                    buildMap["context"] = rewriteRelativePath(context, from: sourceDirectory, to: targetDirectory)
                } else {
                    buildMap["context"] = rewriteRelativePath(".", from: sourceDirectory, to: targetDirectory)
                }
                if let additionalContexts = buildMap["additional_contexts"] {
                    buildMap["additional_contexts"] = rewriteAdditionalContexts(
                        additionalContexts,
                        from: sourceDirectory,
                        to: targetDirectory
                    )
                }
                result["build"] = buildMap
            }
        }

        if let volumes = result["volumes"] as? [Any] {
            result["volumes"] = volumes.map { rewriteRelativeVolume($0, from: sourceDirectory, to: targetDirectory) }
        }

        return result
    }

    private func rewriteAdditionalContexts(_ value: Any, from sourceDirectory: String, to targetDirectory: String) -> Any {
        if let map = value as? [String: Any] {
            return map.reduce(into: [String: Any]()) { result, pair in
                guard let path = stringify(pair.value) else {
                    result[pair.key] = pair.value
                    return
                }
                result[pair.key] = rewriteRelativePath(path, from: sourceDirectory, to: targetDirectory)
            }
        }
        if let list = value as? [Any] {
            return list.map { item in
                guard let context = stringify(item) else { return item }
                let parts = context.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else {
                    return rewriteRelativePath(context, from: sourceDirectory, to: targetDirectory)
                }
                let rewritten = rewriteRelativePath(parts[1], from: sourceDirectory, to: targetDirectory)
                return "\(parts[0])=\(rewritten)"
            }
        }
        return value
    }

    private func rewriteRelativePathValue(_ value: Any, from sourceDirectory: String, to targetDirectory: String) -> Any {
        if let path = stringify(value) {
            return rewriteRelativePath(path, from: sourceDirectory, to: targetDirectory)
        }
        if let list = value as? [Any] {
            return list.map { item -> Any in
                if let path = stringify(item) {
                    return rewriteRelativePath(path, from: sourceDirectory, to: targetDirectory)
                }
                guard var map = item as? [String: Any], let path = stringify(map["path"]) else { return item }
                map["path"] = rewriteRelativePath(path, from: sourceDirectory, to: targetDirectory)
                return map
            }
        }
        return value
    }

    private func rewriteRelativeVolume(_ value: Any, from sourceDirectory: String, to targetDirectory: String) -> Any {
        if let volume = stringify(value) {
            return rewriteRelativeVolumeSpec(volume, from: sourceDirectory, to: targetDirectory)
        }
        guard var map = value as? [String: Any] else { return value }
        let type = stringify(map["type"])
        guard type == nil || type == "bind" else { return value }
        if let source = stringify(map["source"]) {
            map["source"] = rewriteVolumeSource(source, type: type, from: sourceDirectory, to: targetDirectory)
        }
        if let source = stringify(map["src"]) {
            map["src"] = rewriteVolumeSource(source, type: type, from: sourceDirectory, to: targetDirectory)
        }
        return map
    }

    private func rewriteRelativeVolumeSpec(_ spec: String, from sourceDirectory: String, to targetDirectory: String) -> String {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return spec }
        let source = parts[0]
        guard shouldRewriteVolumeSource(source, type: nil) else { return spec }
        var rewritten = parts
        rewritten[0] = rewriteRelativePath(source, from: sourceDirectory, to: targetDirectory)
        return rewritten.joined(separator: ":")
    }

    private func rewriteVolumeSource(
        _ source: String,
        type: String?,
        from sourceDirectory: String,
        to targetDirectory: String
    ) -> String {
        guard shouldRewriteVolumeSource(source, type: type) else { return source }
        return rewriteRelativePath(source, from: sourceDirectory, to: targetDirectory)
    }

    private func shouldRewriteVolumeSource(_ source: String, type: String?) -> Bool {
        if type == "bind" {
            return shouldRewriteRelativePath(source)
        }
        return source == "."
            || source == ".."
            || source.hasPrefix("./")
            || source.hasPrefix("../")
            || source.contains("/")
    }

    private func rewriteRelativePath(_ path: String, from sourceDirectory: String, to targetDirectory: String) -> String {
        guard shouldRewriteRelativePath(path) else { return path }
        guard !isRemotePath(sourceDirectory), !isRemotePath(targetDirectory) else { return path }
        let absolutePath = URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: sourceDirectory, isDirectory: true)
        ).standardizedFileURL.path
        return relativePath(from: targetDirectory, to: absolutePath)
    }

    private func shouldRewriteRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.hasPrefix("~")
            && !hasURLScheme(path)
            && !isRemotePath(path)
    }

    private func hasURLScheme(_ path: String) -> Bool {
        URLComponents(string: path)?.scheme != nil
    }

    private func relativePath(from baseDirectory: String, to targetPath: String) -> String {
        let baseComponents = URL(fileURLWithPath: baseDirectory, isDirectory: true).standardizedFileURL.pathComponents
        let targetComponents = URL(fileURLWithPath: targetPath).standardizedFileURL.pathComponents
        var commonPrefixCount = 0

        while commonPrefixCount < baseComponents.count,
              commonPrefixCount < targetComponents.count,
              baseComponents[commonPrefixCount] == targetComponents[commonPrefixCount] {
            commonPrefixCount += 1
        }

        let parentTraversals = Array(repeating: "..", count: baseComponents.count - commonPrefixCount)
        let pathComponents = parentTraversals + Array(targetComponents.dropFirst(commonPrefixCount))
        return pathComponents.isEmpty ? "." : pathComponents.joined(separator: "/")
    }

    private func parseExtendsReference(
        _ value: Any,
        serviceName: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ServiceExtendsReference? {
        if let service = stringify(value), !service.isEmpty {
            return ServiceExtendsReference(service: service)
        }

        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(serviceName).extends",
                message: "Expected extends to be a service name or mapping."
            ))
            return nil
        }

        guard let service = stringify(map["service"]), !service.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: "services.\(serviceName).extends.service",
                message: "Service extends requires a non-empty service reference."
            ))
            return nil
        }

        return ServiceExtendsReference(service: service, file: stringify(map["file"]))
    }

    private func profilesActivatedByTargets(_ targetedServices: Set<String>, services: [ComposeService]) -> Set<String> {
        guard !targetedServices.isEmpty else { return [] }
        return services.reduce(into: Set<String>()) { result, service in
            if targetedServices.contains(service.name) {
                result.formUnion(service.profiles)
            }
        }
    }

    private func missingDependencyDiagnostics(for services: [ComposeService], allServices: [ComposeService]) -> [ComposeDiagnostic] {
        let activeServiceNames = Set(services.map(\.name))
        let allServiceNames = Set(allServices.map(\.name))
        return services.flatMap { service in
            service.dependsOn.compactMap { dependency in
                guard !activeServiceNames.contains(dependency) else { return nil }
                if allServiceNames.contains(dependency) {
                    return ComposeDiagnostic(
                        severity: .warning,
                        path: "services.\(service.name).depends_on.\(dependency)",
                        message: "Dependency service is not active. Enable a matching profile or target the dependency explicitly."
                    )
                }
                return ComposeDiagnostic(
                    severity: .warning,
                    path: "services.\(service.name).depends_on.\(dependency)",
                    message: "Dependency service is not defined in the Compose model."
                )
            }
        }
    }

    private func duplicateContainerNameDiagnostics(for services: [ComposeService], projectName: String) -> [ComposeDiagnostic] {
        var firstServiceByContainerName: [String: String] = [:]
        var diagnostics: [ComposeDiagnostic] = []
        for service in services {
            let containerName = effectiveContainerName(projectName: projectName, service: service)
            if let firstService = firstServiceByContainerName[containerName] {
                diagnostics.append(.init(
                    severity: .error,
                    path: service.containerName == nil ? "services.\(service.name)" : "services.\(service.name).container_name",
                    message: "container_name '\(containerName)' is already used by service '\(firstService)'."
                ))
            } else {
                firstServiceByContainerName[containerName] = service.name
            }
        }
        return diagnostics
    }

    private func effectiveContainerName(projectName: String, service: ComposeService) -> String {
        service.containerName ?? "\(sanitize(projectName))_\(sanitize(service.name))_1"
    }

    private func loadMergedRootWithIncludes(
        from resolvedPaths: [String],
        envFiles: [String]? = nil,
        includedFrom: String? = nil,
        includeStack: [String] = []
    ) throws -> LoadedRoot {
        try loadMergedRootWithIncludes(
            from: resolvedPaths.map { ComposeSource(path: $0) },
            envFiles: envFiles,
            includedFrom: includedFrom,
            includeStack: includeStack
        )
    }

    private func loadMergedRootWithIncludes(
        from sources: [ComposeSource],
        envFiles: [String]? = nil,
        includedFrom: String? = nil,
        includeStack: [String] = []
    ) throws -> LoadedRoot {
        var mergedRoot: [String: Any]?
        var includeEntries: [IncludeEntry] = []
        var diagnostics: [ComposeDiagnostic] = []
        var remoteIncludes: [ComposeRemoteInclude] = []

        for sourceReference in sources {
            let filePath = sourceReference.path
            let source = try loadComposeSource(
                sourceReference,
                includedFrom: includedFrom,
                includeStack: includeStack
            )
            var root = try loadRawRoot(yaml: source.yaml, sourcePath: filePath, diagnostics: &diagnostics, envFiles: envFiles)
            if let remoteInclude = source.remoteInclude {
                remoteIncludes.append(remoteInclude)
            }
            includeEntries.append(contentsOf: parseIncludeEntries(
                root.removeValue(forKey: "include"),
                sourcePath: filePath,
                diagnostics: &diagnostics
            ))
            if let existing = mergedRoot {
                mergedRoot = merge(base: existing, override: root)
            } else {
                mergedRoot = root
            }
        }

        guard let mergedRoot else {
            throw ComposeLoadError.fileNotFound(sources.map(\.path))
        }
        let normalizedRoot = normalizeResidualMergeTags(mergedRoot) as? [String: Any] ?? mergedRoot
        return LoadedRoot(
            root: normalizedRoot,
            includeEntries: includeEntries,
            diagnostics: diagnostics,
            remoteIncludes: remoteIncludes
        )
    }

    private func resolveIncludes(
        in root: [String: Any],
        includeEntries: [IncludeEntry],
        diagnostics: inout [ComposeDiagnostic],
        stack: Set<String>,
        includeStack: [String]
    ) throws -> ResolvedRoot {
        guard !includeEntries.isEmpty else {
            return ResolvedRoot(root: root, remoteIncludes: [])
        }

        var result = root
        var remoteIncludes: [ComposeRemoteInclude] = []

        for entry in includeEntries {
            let includedRoot = try loadIncludedRoot(
                entry: entry,
                diagnostics: &diagnostics,
                stack: stack,
                includeStack: includeStack
            )
            remoteIncludes.append(contentsOf: includedRoot.remoteIncludes)
            result = copyIncludedResources(from: includedRoot.root, into: result, diagnostics: &diagnostics)
        }

        return ResolvedRoot(root: result, remoteIncludes: remoteIncludes)
    }

    private func loadIncludedRoot(
        entry: IncludeEntry,
        diagnostics: inout [ComposeDiagnostic],
        stack: Set<String>,
        includeStack: [String]
    ) throws -> ResolvedRoot {
        for path in entry.paths where stack.contains(path) {
            throw ComposeLoadError.recursiveInclude(path)
        }

        let loaded = try loadMergedRootWithIncludes(
            from: entry.paths.map { ComposeSource(path: $0) },
            envFiles: entry.envFiles,
            includedFrom: entry.includedFrom,
            includeStack: includeStack
        )
        diagnostics.append(contentsOf: loaded.diagnostics)
        let resolvedIncludes = try resolveIncludes(
            in: loaded.root,
            includeEntries: loaded.includeEntries,
            diagnostics: &diagnostics,
            stack: stack.union(entry.paths),
            includeStack: includeStack + entry.paths
        )
        var includedRoot = resolvedIncludes.root
        includedRoot.removeValue(forKey: "name")
        return ResolvedRoot(
            root: includedRoot,
            remoteIncludes: loaded.remoteIncludes + resolvedIncludes.remoteIncludes
        )
    }

    private func parseIncludeEntries(
        _ value: Any?,
        sourcePath: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [IncludeEntry] {
        guard let value else { return [] }
        let sourceDirectory = containingDirectory(for: sourcePath)

        let values: [Any]
        if let string = stringify(value) {
            values = [string]
        } else if let list = value as? [Any] {
            values = list
        } else {
            diagnostics.append(.init(
                severity: .warning,
                path: "include",
                message: "Unsupported include format was ignored."
            ))
            return []
        }

        return values.compactMap { item in
            if let path = stringify(item) {
                return IncludeEntry(paths: [resolvePath(path, relativeTo: sourceDirectory)], includedFrom: sourcePath)
            }
            guard let map = item as? [String: Any] else {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "include",
                    message: "Unsupported include item was ignored."
                ))
                return nil
            }

            let explicitProjectDirectory: String?
            if let rawProjectDirectory = stringify(map["project_directory"]) {
                explicitProjectDirectory = resolveDirectory(rawProjectDirectory, relativeTo: sourceDirectory)
            } else {
                explicitProjectDirectory = nil
            }

            guard let pathValue = map["path"] else {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "include.path",
                    message: "Include item without path was ignored."
                ))
                return nil
            }

            if let path = stringify(pathValue) {
                let baseDirectory = explicitProjectDirectory ?? sourceDirectory
                let resolvedPath = resolvePath(path, relativeTo: baseDirectory)
                let projectDirectory = explicitProjectDirectory ?? containingDirectory(for: resolvedPath)
                let envFiles = parseIncludeEnvFiles(
                    map["env_file"],
                    projectDirectory: projectDirectory,
                    diagnostics: &diagnostics
                )
                return IncludeEntry(paths: [resolvedPath], envFiles: envFiles, includedFrom: sourcePath)
            }
            if let paths = pathValue as? [Any] {
                let baseDirectory = explicitProjectDirectory ?? sourceDirectory
                let resolved = paths.compactMap { item -> String? in
                    guard let path = stringify(item) else {
                        diagnostics.append(.init(
                            severity: .warning,
                            path: "include.path",
                            message: "Unsupported include path list item was ignored."
                        ))
                        return nil
                    }
                    return resolvePath(path, relativeTo: baseDirectory)
                }
                let projectDirectory = explicitProjectDirectory ?? resolved.first.map(containingDirectory(for:)) ?? sourceDirectory
                let envFiles = parseIncludeEnvFiles(
                    map["env_file"],
                    projectDirectory: projectDirectory,
                    diagnostics: &diagnostics
                )
                return resolved.isEmpty ? nil : IncludeEntry(paths: resolved, envFiles: envFiles, includedFrom: sourcePath)
            }

            diagnostics.append(.init(
                severity: .warning,
                path: "include.path",
                message: "Unsupported include path format was ignored."
            ))
            return nil
        }
    }

    private func parseIncludeEnvFiles(
        _ value: Any?,
        projectDirectory: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String]? {
        guard let value else { return nil }
        if isRemotePath(projectDirectory) {
            diagnostics.append(.init(
                severity: .warning,
                path: "include.env_file",
                message: "Remote include env_file is not supported yet; process environment still applies."
            ))
            return nil
        }
        func resolve(_ path: String) -> String {
            resolvePath(path, relativeTo: projectDirectory)
        }

        if let path = stringify(value) {
            return validateIncludeEnvFiles([resolve(path)], diagnostics: &diagnostics)
        }
        if let list = value as? [Any] {
            let paths = list.compactMap { item -> String? in
                guard let path = stringify(item) else {
                    diagnostics.append(.init(
                        severity: .warning,
                        path: "include.env_file",
                        message: "Unsupported include env_file list item was ignored."
                    ))
                    return nil
                }
                return resolve(path)
            }
            return validateIncludeEnvFiles(paths, diagnostics: &diagnostics)
        }

        diagnostics.append(.init(
            severity: .warning,
            path: "include.env_file",
            message: "Unsupported include env_file format was ignored."
        ))
        return nil
    }

    private func validateIncludeEnvFiles(
        _ paths: [String],
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String]? {
        guard !paths.isEmpty else { return nil }
        for path in paths where !isRemotePath(path) && !FileManager.default.fileExists(atPath: path) {
            diagnostics.append(.init(
                severity: .warning,
                path: "include.env_file",
                message: "Include env_file does not exist: \(path)"
            ))
        }
        return paths
    }

    private func copyIncludedResources(
        from included: [String: Any],
        into root: [String: Any],
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String: Any] {
        var result = root
        for key in ["services", "networks", "volumes", "configs", "secrets", "models"] {
            guard let includedMap = included[key] as? [String: Any] else { continue }
            var currentMap = result[key] as? [String: Any] ?? [:]

            for resourceName in includedMap.keys.sorted() {
                if currentMap[resourceName] != nil {
                    diagnostics.append(.init(
                        severity: .warning,
                        path: "\(key).\(resourceName)",
                        message: "Included resource conflicts with the current project; keeping current definition."
                    ))
                    continue
                }
                currentMap[resourceName] = includedMap[resourceName]
            }

            result[key] = currentMap
        }
        return result
    }

    private func resolveComposePaths(paths: [String]?, workingDirectory: String) throws -> [String] {
        if let paths, !paths.isEmpty {
            return paths.map {
                resolvePath($0, relativeTo: workingDirectory)
            }
        }

        let startDirectory = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
        var candidates: [String] = []
        var directory: URL? = startDirectory
        while let currentDirectory = directory {
            let currentCandidates = Self.defaultFileNames.map {
                currentDirectory.appendingPathComponent($0).path
            }
            candidates.append(contentsOf: currentCandidates)
            for candidate in currentCandidates where FileManager.default.fileExists(atPath: candidate) {
                let overrides = Self.defaultOverrideFileNames
                    .map { currentDirectory.appendingPathComponent($0).path }
                    .filter { FileManager.default.fileExists(atPath: $0) }
                return [candidate] + overrides
            }

            let parent = currentDirectory.deletingLastPathComponent().standardizedFileURL
            directory = parent.path == currentDirectory.path ? nil : parent
        }
        throw ComposeLoadError.fileNotFound(candidates)
    }

    private func merge(base: [String: Any], override: [String: Any], path: [String] = []) -> [String: Any] {
        var result = base
        for key in override.keys.sorted() {
            let mergedPath = path + [key]
            guard let overrideValue = override[key] else { continue }
            if let taggedValue = overrideValue as? ComposeTaggedValue {
                switch taggedValue.kind {
                case .reset:
                    guard let baseValue = result[key] else { continue }
                    if let defaultValue = resetDefaultValue(baseValue: baseValue, explicitValue: taggedValue.value) {
                        result[key] = defaultValue
                    } else {
                        result.removeValue(forKey: key)
                    }
                    continue
                case .override:
                    result[key] = taggedValue.value
                    continue
                }
            }

            guard let baseValue = result[key] else {
                result[key] = overrideValue
                continue
            }

            if shouldMergeDependsOn(at: mergedPath),
               let mergedDependsOn = mergeDependsOn(base: baseValue, override: overrideValue) {
                result[key] = mergedDependsOn
                continue
            }

            if shouldMergeExtraHosts(at: mergedPath),
               let mergedExtraHosts = mergeExtraHosts(base: baseValue, override: overrideValue) {
                result[key] = mergedExtraHosts
                continue
            }

            if shouldMergeLogging(at: mergedPath),
               let mergedLogging = mergeLogging(base: baseValue, override: overrideValue, path: mergedPath) {
                result[key] = mergedLogging
                continue
            }

            if shouldMergeBuild(at: mergedPath),
               let mergedBuild = mergeBuild(base: baseValue, override: overrideValue, path: mergedPath) {
                result[key] = mergedBuild
                continue
            }

            if shouldMergeServiceNetworks(at: mergedPath),
               let mergedNetworks = mergeServiceNetworks(base: baseValue, override: overrideValue, path: mergedPath) {
                result[key] = mergedNetworks
                continue
            }

            if let mergedMapping = mergeExpandedMapping(base: baseValue, override: overrideValue, at: mergedPath) {
                result[key] = mergedMapping
                continue
            }

            if shouldOverrideSequence(at: mergedPath) {
                result[key] = overrideValue
                continue
            }

            if shouldMergeNetworkIPAMConfig(at: mergedPath),
               let baseList = baseValue as? [Any],
               let overrideList = overrideValue as? [Any] {
                result[key] = mergeNetworkIPAMConfigs(base: baseList, override: overrideList, path: mergedPath)
                continue
            }

            if shouldMergeTopLevelResourceLabels(at: mergedPath),
               let mergedLabels = mergeToSequence(base: baseValue, override: overrideValue) {
                result[key] = mergedLabels
                continue
            }

            if let baseMap = baseValue as? [String: Any], let overrideMap = overrideValue as? [String: Any] {
                result[key] = merge(base: baseMap, override: overrideMap, path: mergedPath)
            } else if let baseList = baseValue as? [Any], let overrideList = overrideValue as? [Any] {
                result[key] = mergeSequence(base: baseList, override: overrideList, path: mergedPath)
            } else {
                result[key] = overrideValue
            }
        }
        return result
    }

    private func resetDefaultValue(baseValue: Any, explicitValue: Any) -> Any? {
        if explicitValue is [Any] {
            return [Any]()
        }
        if explicitValue is [String: Any] {
            return [String: Any]()
        }
        if baseValue is [Any] {
            return [Any]()
        }
        if baseValue is [String: Any] {
            return [String: Any]()
        }
        return nil
    }

    private func normalizeResidualMergeTags(_ value: Any) -> Any? {
        if let taggedValue = value as? ComposeTaggedValue {
            switch taggedValue.kind {
            case .reset:
                return resetDefaultValue(baseValue: taggedValue.value, explicitValue: taggedValue.value)
            case .override:
                return normalizeResidualMergeTags(taggedValue.value)
            }
        }

        if let map = value as? [String: Any] {
            return map.reduce(into: [String: Any]()) { result, pair in
                if let taggedValue = pair.value as? ComposeTaggedValue, taggedValue.kind == .reset {
                    if let defaultValue = resetDefaultValue(baseValue: taggedValue.value, explicitValue: taggedValue.value) {
                        result[pair.key] = defaultValue
                    }
                    return
                }
                if let normalized = normalizeResidualMergeTags(pair.value) {
                    result[pair.key] = normalized
                }
            }
        }

        if let list = value as? [Any] {
            return list.compactMap(normalizeResidualMergeTags)
        }

        return value
    }

    private func shouldOverrideSequence(at path: [String]) -> Bool {
        guard let field = path.last else { return false }
        if path.count >= 4,
           path[0] == "services",
           path[2] == "healthcheck",
           path[3] == "test" {
            return true
        }
        return field == "command" || field == "entrypoint"
    }

    private func shouldMergeDependsOn(at path: [String]) -> Bool {
        path.count >= 3 && path[0] == "services" && path.last == "depends_on"
    }

    private func shouldMergeExtraHosts(at path: [String]) -> Bool {
        guard path.count >= 3, path[0] == "services", path.last == "extra_hosts" else {
            return false
        }
        return path.count == 3 || (path.count == 4 && path[2] == "build")
    }

    private func shouldMergeBuild(at path: [String]) -> Bool {
        path.count == 3 && path[0] == "services" && path[2] == "build"
    }

    private func mergeBuild(base: Any, override: Any, path: [String]) -> [String: Any]? {
        guard let baseMap = buildMapping(from: base),
              let overrideMap = buildMapping(from: override) else {
            return nil
        }
        return merge(base: baseMap, override: overrideMap, path: path)
    }

    private func buildMapping(from value: Any) -> [String: Any]? {
        if let context = stringify(value) {
            return ["context": context]
        }
        if let map = value as? [String: Any] {
            return map
        }
        return nil
    }

    private func mergeExtraHosts(base: Any, override: Any) -> [Any]? {
        guard var baseEntries = extraHostEntries(from: base),
              let overrideEntries = extraHostEntries(from: override) else {
            return nil
        }

        for entry in overrideEntries where !baseEntries.contains(entry) {
            baseEntries.append(entry)
        }
        return baseEntries
    }

    private func extraHostEntries(from value: Any) -> [String]? {
        if let string = stringify(value) {
            return [string]
        }

        if let list = value as? [Any] {
            var entries: [String] = []
            for item in list {
                guard let entry = stringify(item) else { return nil }
                entries.append(entry)
            }
            return entries
        }

        if let map = value as? [String: Any] {
            var entries: [String] = []
            for key in map.keys.sorted() {
                guard let value = stringify(map[key]) else { return nil }
                entries.append("\(key)=\(value)")
            }
            return entries
        }

        return nil
    }

    private func mergeDependsOn(base: Any, override: Any) -> [String: Any]? {
        guard let baseEntries = dependsOnEntries(from: base),
              let overrideEntries = dependsOnEntries(from: override) else {
            return nil
        }

        var result = baseEntries.reduce(into: [String: Any]()) { merged, entry in
            merged[entry.name] = entry.value
        }

        for entry in overrideEntries {
            guard let existingValue = result[entry.name] else {
                result[entry.name] = entry.value
                continue
            }

            if isDefaultDependsOnValue(entry.value) {
                continue
            }

            if let existingMap = existingValue as? [String: Any],
               let overrideMap = entry.value as? [String: Any] {
                result[entry.name] = merge(base: existingMap, override: overrideMap)
            } else {
                result[entry.name] = entry.value
            }
        }

        return result
    }

    private func dependsOnEntries(from value: Any) -> [(name: String, value: Any)]? {
        if let service = stringify(value) {
            return [(service, [String: Any]())]
        }

        if let list = value as? [Any] {
            var entries: [(name: String, value: Any)] = []
            for item in list {
                guard let service = stringify(item) else { return nil }
                entries.append((service, [String: Any]()))
            }
            return entries
        }

        if let map = value as? [String: Any] {
            return map.keys.sorted().map { key in
                (key, map[key] ?? NSNull())
            }
        }

        return nil
    }

    private func isDefaultDependsOnValue(_ value: Any) -> Bool {
        if value is NSNull {
            return true
        }
        if let map = value as? [String: Any] {
            return map.isEmpty
        }
        return false
    }

    private struct ExpandedMappingMergeConfig {
        var separators: [String]
        var allowsBareKey: Bool
    }

    private func mergeExpandedMapping(base: Any, override: Any, at path: [String]) -> [String: Any]? {
        guard let config = expandedMappingMergeConfig(at: path),
              let baseMap = expandedMapping(from: base, config: config),
              let overrideMap = expandedMapping(from: override, config: config) else {
            return nil
        }
        return merge(base: baseMap, override: overrideMap, path: path)
    }

    private func expandedMappingMergeConfig(at path: [String]) -> ExpandedMappingMergeConfig? {
        guard path.count >= 3, path[0] == "services", let field = path.last else {
            return nil
        }

        if path.count == 3 {
            switch field {
            case "annotations", "environment", "labels":
                return ExpandedMappingMergeConfig(separators: ["="], allowsBareKey: true)
            case "sysctls":
                return ExpandedMappingMergeConfig(separators: ["="], allowsBareKey: false)
            default:
                return nil
            }
        }

        if path.count == 4, path[2] == "build" {
            switch field {
            case "args", "labels":
                return ExpandedMappingMergeConfig(separators: ["="], allowsBareKey: true)
            default:
                return nil
            }
        }

        if path.count == 4, path[2] == "deploy", field == "labels" {
            return ExpandedMappingMergeConfig(separators: ["="], allowsBareKey: true)
        }

        return nil
    }

    private func expandedMapping(from value: Any, config: ExpandedMappingMergeConfig) -> [String: Any]? {
        if let map = value as? [String: Any] {
            return map
        }

        guard let list = value as? [Any] else {
            return nil
        }

        var result: [String: Any] = [:]
        for item in list {
            guard let raw = stringify(item),
                  let entry = expandedMappingEntry(from: raw, config: config) else {
                return nil
            }
            result[entry.key] = entry.value
        }
        return result
    }

    private func expandedMappingEntry(
        from raw: String,
        config: ExpandedMappingMergeConfig
    ) -> (key: String, value: Any)? {
        for separator in config.separators {
            guard let range = raw.range(of: separator) else { continue }
            let key = String(raw[..<range.lowerBound])
            guard !key.isEmpty else { return nil }
            return (key, String(raw[range.upperBound...]))
        }

        guard config.allowsBareKey, !raw.isEmpty else {
            return nil
        }
        return (raw, NSNull())
    }

    private func mergeSequence(base: [Any], override: [Any], path: [String]) -> [Any] {
        guard let field = path.last, path.count >= 3, path[0] == "services" else {
            return base + override
        }

        if isBlockIODeviceSequence(path) {
            return mergeUniqueSequence(base: base, override: override, key: keyedMapMergeKey("path"))
        }

        if isDeployPlacementConstraintSequence(path) {
            return mergeUniqueSequence(base: base, override: override, key: { stringify($0) })
        }

        if isDeployPlacementPreferenceSequence(path) {
            return mergeUniqueSequence(base: base, override: override, key: exactMapMergeKey)
        }

        if isDeployGenericResourceSequence(path) {
            return mergeUniqueSequence(base: base, override: override, key: exactMapMergeKey)
        }

        let resourceKeys = ComposeResourceKeys()
        switch field {
        case "cap_add",
             "cap_drop",
             "device_cgroup_rules",
             "expose",
             "external_links",
             "security_opt":
            return mergeUniqueSequence(base: base, override: override, key: { stringify($0) })
        case "ports":
            return mergeUniqueSequence(base: base, override: override, key: resourceKeys.portMergeKey)
        case "volumes":
            return mergeUniqueSequence(base: base, override: override, key: resourceKeys.volumeMergeKey)
        case "devices":
            return mergeUniqueSequence(base: base, override: override, key: deviceMergeKey)
        case "configs":
            return mergeUniqueSequence(base: base, override: override, key: resourceKeys.configMergeKey)
        case "secrets":
            return mergeUniqueSequence(base: base, override: override, key: resourceKeys.secretMergeKey)
        default:
            return base + override
        }
    }

    private func mergeUniqueSequence(
        base: [Any],
        override: [Any],
        key: (Any) -> String?
    ) -> [Any] {
        var result = base
        var indexesByKey: [String: Int] = [:]
        for (index, item) in result.enumerated() {
            if let itemKey = key(item) {
                indexesByKey[itemKey] = index
            }
        }

        for item in override {
            guard let itemKey = key(item) else {
                result.append(item)
                continue
            }
            if let existingIndex = indexesByKey[itemKey] {
                result[existingIndex] = item
            } else {
                indexesByKey[itemKey] = result.count
                result.append(item)
            }
        }
        return result
    }

    private func isDeployPlacementConstraintSequence(_ path: [String]) -> Bool {
        path.count == 5
            && path[0] == "services"
            && path[2] == "deploy"
            && path[3] == "placement"
            && path[4] == "constraints"
    }

    private func isDeployPlacementPreferenceSequence(_ path: [String]) -> Bool {
        path.count == 5
            && path[0] == "services"
            && path[2] == "deploy"
            && path[3] == "placement"
            && path[4] == "preferences"
    }

    private func isDeployGenericResourceSequence(_ path: [String]) -> Bool {
        path.count == 6
            && path[0] == "services"
            && path[2] == "deploy"
            && path[3] == "resources"
            && path[4] == "reservations"
            && path[5] == "generic_resources"
    }

    private func shouldMergeTopLevelResourceLabels(at path: [String]) -> Bool {
        path.count == 3 && (path[0] == "networks" || path[0] == "volumes") && path[2] == "labels"
    }

    private func mergeToSequence(base: Any, override: Any) -> [Any]? {
        guard let baseSequence = sequenceValue(from: base),
              let overrideSequence = sequenceValue(from: override) else {
            return nil
        }
        return baseSequence + overrideSequence
    }

    private func sequenceValue(from value: Any) -> [Any]? {
        if let list = value as? [Any] {
            return list
        }
        if let string = stringify(value) {
            return [string]
        }
        if let map = value as? [String: Any] {
            return map.keys.sorted().flatMap { key -> [Any] in
                guard let value = map[key], !(value is NSNull) else {
                    return [key]
                }
                if let list = value as? [Any] {
                    return list.map { "\(key)=\($0)" }
                }
                return ["\(key)=\(value)"]
            }
        }
        return nil
    }

    private func shouldMergeNetworkIPAMConfig(at path: [String]) -> Bool {
        path.count == 4 && path[0] == "networks" && path[2] == "ipam" && path[3] == "config"
    }

    private func mergeNetworkIPAMConfigs(base: [Any], override: [Any], path: [String]) -> [Any] {
        var result = base
        var indexesBySubnet: [String: Int] = [:]
        for (index, item) in result.enumerated() {
            if let subnet = keyedMapMergeKey("subnet")(item) {
                indexesBySubnet[subnet] = index
            }
        }

        for item in override {
            guard let subnet = keyedMapMergeKey("subnet")(item) else {
                result.append(item)
                continue
            }
            if let existingIndex = indexesBySubnet[subnet],
               let baseMap = result[existingIndex] as? [String: Any],
               let overrideMap = item as? [String: Any] {
                result[existingIndex] = merge(base: baseMap, override: overrideMap, path: path)
            } else if let existingIndex = indexesBySubnet[subnet] {
                result[existingIndex] = item
            } else {
                indexesBySubnet[subnet] = result.count
                result.append(item)
            }
        }
        return result
    }

    private func shouldMergeLogging(at path: [String]) -> Bool {
        path.count == 3 && path[0] == "services" && path[2] == "logging"
    }

    private func mergeLogging(base: Any, override: Any, path: [String]) -> [String: Any]? {
        guard let baseMap = base as? [String: Any],
              let overrideMap = override as? [String: Any] else {
            return nil
        }

        let baseDriver = stringify(baseMap["driver"])
        let overrideDriver = stringify(overrideMap["driver"])
        guard baseDriver == overrideDriver || baseDriver == nil || overrideDriver == nil else {
            return overrideMap
        }

        return merge(base: baseMap, override: overrideMap, path: path)
    }

    private func shouldMergeServiceNetworks(at path: [String]) -> Bool {
        path.count == 3 && path[0] == "services" && path[2] == "networks"
    }

    private func mergeServiceNetworks(base: Any, override: Any, path: [String]) -> Any? {
        if let baseList = base as? [Any], let overrideList = override as? [Any] {
            return mergeUniqueSequence(base: baseList, override: overrideList, key: networkAttachmentMergeKey)
        }

        guard var baseMap = serviceNetworkMapping(from: base),
              let overrideMap = serviceNetworkMapping(from: override) else {
            return nil
        }

        for key in overrideMap.keys.sorted() {
            guard let overrideValue = overrideMap[key] else { continue }
            if overrideValue is NSNull, baseMap[key] != nil {
                continue
            }
            if let baseOptions = baseMap[key] as? [String: Any],
               let overrideOptions = overrideValue as? [String: Any] {
                baseMap[key] = merge(base: baseOptions, override: overrideOptions, path: path + [key])
            } else {
                baseMap[key] = overrideValue
            }
        }
        return baseMap
    }

    private func serviceNetworkMapping(from value: Any) -> [String: Any]? {
        if let name = stringify(value), !name.isEmpty {
            return [name: NSNull()]
        }

        if let map = value as? [String: Any] {
            return map
        }

        guard let list = value as? [Any] else { return nil }
        var result: [String: Any] = [:]
        for item in list {
            guard let name = networkAttachmentMergeKey(item) else {
                return nil
            }
            result[name] = NSNull()
        }
        return result
    }

    private func networkAttachmentMergeKey(_ value: Any) -> String? {
        guard let name = stringify(value), !name.isEmpty else { return nil }
        return name
    }

    private func deviceMergeKey(_ value: Any) -> String? {
        guard let spec = stringify(value), !spec.isEmpty else { return nil }
        let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty else { return spec }
        return String(parts[1])
    }

    private func isBlockIODeviceSequence(_ path: [String]) -> Bool {
        guard path.count == 4, path[0] == "services", path[2] == "blkio_config" else {
            return false
        }
        switch path[3] {
        case "weight_device",
             "device_read_bps",
             "device_read_iops",
             "device_write_bps",
             "device_write_iops":
            return true
        default:
            return false
        }
    }

    private func keyedMapMergeKey(_ key: String) -> (Any) -> String? {
        { value in
            guard let map = value as? [String: Any] else { return nil }
            return stringify(map[key])
        }
    }

    private func exactMapMergeKey(_ value: Any) -> String? {
        guard let map = value as? [String: Any] else { return nil }
        return stableMergeKey(map)
    }

    private func stableMergeKey(_ value: Any) -> String {
        if let map = value as? [String: Any] {
            return "{" + map.keys.sorted().map { key in
                "\(key)=\(stableMergeKey(map[key] ?? ""))"
            }.joined(separator: "\u{1f}") + "}"
        }
        if let list = value as? [Any] {
            return "[" + list.map { stableMergeKey($0) }.joined(separator: "\u{1f}") + "]"
        }
        return stringify(value) ?? String(describing: value)
    }

    private func defaultProjectName(from sourcePath: String) -> String {
        if let url = URL(string: sourcePath), isRemoteURL(url) {
            let directoryName = url.deletingLastPathComponent().lastPathComponent
            return sanitizeProjectName(directoryName)
        }
        let directory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().lastPathComponent
        return sanitizeProjectName(directory)
    }

    private func sanitizeProjectName(_ directory: String) -> String {
        let cleaned = directory.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return name.isEmpty ? "container-compose" : name
    }

    private func loadComposeSource(
        _ path: String,
        includedFrom: String? = nil,
        includeStack: [String] = []
    ) throws -> LoadedComposeSource {
        try loadComposeSource(
            ComposeSource(path: path),
            includedFrom: includedFrom,
            includeStack: includeStack
        )
    }

    private func loadComposeSource(
        _ source: ComposeSource,
        includedFrom: String? = nil,
        includeStack: [String] = []
    ) throws -> LoadedComposeSource {
        let path = source.path
        if let yaml = source.yaml {
            return LoadedComposeSource(yaml: yaml)
        }
        if let url = URL(string: path), isRemoteURL(url) {
            let sanitizedURL = sanitizedURLString(url)
            guard allowRemoteIncludes else {
                throw ComposeLoadError.remoteIncludeDisabled(sanitizedURL)
            }
            do {
                let response = try remoteIncludeResolver(.init(
                    url: url,
                    sanitizedURL: sanitizedURL,
                    includedFrom: includedFrom,
                    includeStack: includeStack
                ))
                return LoadedComposeSource(
                    yaml: response.yaml,
                    remoteInclude: .init(
                        url: sanitizedURL,
                        cacheKey: response.cacheKey,
                        cacheStatus: response.cacheStatus,
                        source: response.source,
                        contentLength: response.yaml.utf8.count
                    )
                )
            } catch {
                throw ComposeLoadError.remoteIncludeFetchFailed(sanitizedURL, String(describing: error))
            }
        }
        do {
            return LoadedComposeSource(yaml: try String(contentsOfFile: path, encoding: .utf8))
        } catch {
            throw ComposeLoadError.fileNotFound([path])
        }
    }

    private func normalizeSourcePath(_ sourcePath: String) -> String {
        if isRemotePath(sourcePath) {
            return sourcePath
        }
        return URL(fileURLWithPath: sourcePath).standardizedFileURL.path
    }

    private func environmentWorkingDirectory(for sourcePath: String) -> String {
        isRemotePath(sourcePath) ? "/" : URL(fileURLWithPath: sourcePath).deletingLastPathComponent().path
    }

    private func containingDirectory(for sourcePath: String) -> String {
        if let url = URL(string: sourcePath), isRemoteURL(url) {
            return remoteDirectoryURL(for: url).absoluteString
        }
        return URL(fileURLWithPath: sourcePath).deletingLastPathComponent().standardizedFileURL.path
    }

    private func resolvePath(_ path: String, relativeTo base: String) -> String {
        if isRemotePath(path) {
            return path
        }

        if let baseURL = URL(string: base), isRemoteURL(baseURL) {
            return URL(string: path, relativeTo: baseURL)?.absoluteURL.standardized.absoluteString ?? path
        }

        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: base, isDirectory: true)).standardizedFileURL.path
    }

    private func resolveDirectory(_ path: String, relativeTo base: String) -> String {
        let resolved = resolvePath(path, relativeTo: base)
        if let url = URL(string: resolved), isRemoteURL(url) {
            let value = url.absoluteString
            return value.hasSuffix("/") ? value : "\(value)/"
        }
        return resolved
    }

    private func isRemotePath(_ path: String) -> Bool {
        guard let url = URL(string: path) else { return false }
        return isRemoteURL(url)
    }

    private func isRemoteURL(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    private func remoteDirectoryURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let value = directory.absoluteString
        if value.hasSuffix("/") {
            return directory
        }
        return URL(string: "\(value)/") ?? directory
    }

    private func sanitizedURLString(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    private static func fetchRemoteInclude(from url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func parseService(
        name: String,
        mapping: [String: Any],
        sourcePath: String,
        diagnostics: inout [ComposeDiagnostic]
    ) throws -> ComposeService {
        diagnostics.append(contentsOf: warnForUnsupportedServiceFields(name: name, mapping: mapping))

        let image = mapping["image"] as? String
        let networkMode = parseNetworkMode(mapping["network_mode"], path: "services.\(name).network_mode", diagnostics: &diagnostics)
        let networkAttachments = implicitDefaultNetworkAttachmentsIfNeeded(
            parseServiceNetworkAttachments(
                mapping["networks"],
                path: "services.\(name).networks",
                diagnostics: &diagnostics
            ),
            networksWasOmitted: mapping["networks"] == nil,
            networkMode: networkMode
        )
        let networks = networkAttachments.map(\.name)
        let links = parseStringList(mapping["links"], path: "services.\(name).links", diagnostics: &diagnostics)
        let linkDependencies = parseLinkDependencies(links)
        let volumesFrom = parseStringList(mapping["volumes_from"], path: "services.\(name).volumes_from", diagnostics: &diagnostics)
        let volumesFromDependencies = parseVolumesFromDependencies(volumesFrom)
        let pidMode = parsePIDMode(mapping["pid"], path: "services.\(name).pid", diagnostics: &diagnostics)
        let ipcMode = parseIPCMode(mapping["ipc"], path: "services.\(name).ipc", diagnostics: &diagnostics)
        let namespaceDependencies = parseServiceNamespaceDependencies(
            networkMode: networkMode,
            pidMode: pidMode,
            ipcMode: ipcMode
        )
        let labelFiles = parseStringList(mapping["label_file"], path: "services.\(name).label_file", diagnostics: &diagnostics)
        let envFileEntries = parseEnvFiles(mapping["env_file"], path: "services.\(name).env_file", diagnostics: &diagnostics)
        let dependsOn = uniquePreservingOrder(
            parseNameReferences(mapping["depends_on"], path: "services.\(name).depends_on", diagnostics: &diagnostics)
            + linkDependencies
            + volumesFromDependencies
            + namespaceDependencies
        )
        let dependsOnMetadata = mergeImplicitDependencyMetadata(
            parseDependsOnMetadata(
                mapping["depends_on"],
                path: "services.\(name).depends_on",
                diagnostics: &diagnostics
            ),
            implicitDependencies: linkDependencies + volumesFromDependencies + namespaceDependencies
        )

        if networkMode != nil, mapping["networks"] != nil {
            diagnostics.append(.init(
                severity: .error,
                path: "services.\(name).network_mode",
                message: "network_mode cannot be used together with networks."
            ))
        }

        return ComposeService(
            name: name,
            image: image,
            pullPolicy: stringify(mapping["pull_policy"]),
            build: parseBuild(mapping["build"], path: "services.\(name).build", diagnostics: &diagnostics),
            command: parseCommand(mapping["command"], path: "services.\(name).command", diagnostics: &diagnostics),
            entrypoint: parseEntrypoint(mapping["entrypoint"], path: "services.\(name).entrypoint", diagnostics: &diagnostics),
            environment: parseEnvironment(mapping["environment"], path: "services.\(name).environment", diagnostics: &diagnostics),
            envFiles: envFileEntries.map(\.path),
            envFileEntries: envFileEntries,
            annotations: parseLabels(mapping["annotations"]),
            attach: parseOptionalBoolean(mapping["attach"], path: "services.\(name).attach", diagnostics: &diagnostics),
            blockIOConfig: parseBlockIOConfig(mapping["blkio_config"], path: "services.\(name).blkio_config", diagnostics: &diagnostics),
            ports: parsePorts(mapping["ports"], path: "services.\(name).ports", diagnostics: &diagnostics),
            exposedPorts: parseStringList(mapping["expose"], path: "services.\(name).expose", diagnostics: &diagnostics),
            volumes: parseVolumes(mapping["volumes"], path: "services.\(name).volumes", diagnostics: &diagnostics),
            networks: networks,
            networkAttachments: networkAttachments,
            networkMode: networkMode,
            pidMode: pidMode,
            ipcMode: ipcMode,
            utsMode: parseUTSMode(mapping["uts"], path: "services.\(name).uts", diagnostics: &diagnostics),
            usernsMode: parseUserNamespaceMode(
                mapping["userns_mode"],
                path: "services.\(name).userns_mode",
                diagnostics: &diagnostics
            ),
            isolation: parseIsolation(mapping["isolation"], path: "services.\(name).isolation", diagnostics: &diagnostics),
            cgroupMode: parseCgroupMode(mapping["cgroup"], path: "services.\(name).cgroup", diagnostics: &diagnostics),
            cgroupParent: parseCgroupParent(mapping["cgroup_parent"], path: "services.\(name).cgroup_parent", diagnostics: &diagnostics),
            deviceCgroupRules: parseDeviceCgroupRules(
                mapping["device_cgroup_rules"],
                path: "services.\(name).device_cgroup_rules",
                diagnostics: &diagnostics
            ),
            devices: parseServiceDevices(mapping["devices"], path: "services.\(name).devices", diagnostics: &diagnostics),
            gpus: parseGPUs(mapping["gpus"], path: "services.\(name).gpus", diagnostics: &diagnostics),
            groupAdd: parseGroupAdd(mapping["group_add"], path: "services.\(name).group_add", diagnostics: &diagnostics),
            sysctls: parseSysctls(mapping["sysctls"], path: "services.\(name).sysctls", diagnostics: &diagnostics),
            oomKillDisable: parseOptionalBoolean(mapping["oom_kill_disable"], path: "services.\(name).oom_kill_disable", diagnostics: &diagnostics),
            oomScoreAdjustment: parseOOMScoreAdjustment(mapping["oom_score_adj"], path: "services.\(name).oom_score_adj", diagnostics: &diagnostics),
            pidsLimit: parsePIDsLimit(mapping["pids_limit"], path: "services.\(name).pids_limit", diagnostics: &diagnostics),
            logging: parseLogging(mapping["logging"], path: "services.\(name).logging", diagnostics: &diagnostics),
            runtime: parseOptionalNonEmptyString(mapping["runtime"], path: "services.\(name).runtime", diagnostics: &diagnostics),
            scale: parseScale(mapping["scale"], path: "services.\(name).scale", diagnostics: &diagnostics),
            storageOptions: parseStringMap(mapping["storage_opt"], path: "services.\(name).storage_opt", diagnostics: &diagnostics),
            useAPISocket: parseOptionalBoolean(mapping["use_api_socket"], path: "services.\(name).use_api_socket", diagnostics: &diagnostics),
            provider: parseProvider(mapping["provider"], path: "services.\(name).provider", diagnostics: &diagnostics),
            credentialSpec: parseCredentialSpec(
                mapping["credential_spec"],
                path: "services.\(name).credential_spec",
                diagnostics: &diagnostics
            ),
            volumesFrom: volumesFrom,
            modelGrants: parseServiceModelGrants(
                mapping["models"],
                path: "services.\(name).models",
                diagnostics: &diagnostics
            ),
            develop: parseDevelop(mapping["develop"], path: "services.\(name).develop", diagnostics: &diagnostics),
            deploy: parseDeploy(mapping["deploy"], path: "services.\(name).deploy", diagnostics: &diagnostics),
            postStartHooks: parseLifecycleHooks(
                mapping["post_start"],
                path: "services.\(name).post_start",
                requiresCommand: true,
                allowsImage: false,
                allowsPerReplica: false,
                diagnostics: &diagnostics
            ),
            preStartHooks: parseLifecycleHooks(
                mapping["pre_start"],
                path: "services.\(name).pre_start",
                requiresCommand: false,
                allowsImage: true,
                allowsPerReplica: true,
                diagnostics: &diagnostics
            ),
            preStopHooks: parseLifecycleHooks(
                mapping["pre_stop"],
                path: "services.\(name).pre_stop",
                requiresCommand: true,
                allowsImage: false,
                allowsPerReplica: false,
                diagnostics: &diagnostics
            ),
            links: links,
            externalLinks: parseStringList(mapping["external_links"], path: "services.\(name).external_links", diagnostics: &diagnostics),
            dependsOn: dependsOn,
            dependsOnMetadata: dependsOnMetadata,
            healthcheck: parseHealthcheck(mapping["healthcheck"], path: "services.\(name).healthcheck", diagnostics: &diagnostics),
            profiles: parseStringList(mapping["profiles"], path: "services.\(name).profiles", diagnostics: &diagnostics),
            configs: parseServiceResourceGrants(
                mapping["configs"],
                kind: "configs",
                path: "services.\(name).configs",
                diagnostics: &diagnostics
            ),
            secrets: parseServiceResourceGrants(
                mapping["secrets"],
                kind: "secrets",
                path: "services.\(name).secrets",
                diagnostics: &diagnostics
            ),
            workingDirectory: mapping["working_dir"] as? String,
            user: mapping["user"] as? String,
            platform: mapping["platform"] as? String,
            cpus: stringify(mapping["cpus"]),
            cpuCount: parseOptionalInt(mapping["cpu_count"], path: "services.\(name).cpu_count", diagnostics: &diagnostics),
            cpuPercent: parseOptionalInt(mapping["cpu_percent"], path: "services.\(name).cpu_percent", diagnostics: &diagnostics),
            cpuShares: parseOptionalInt(mapping["cpu_shares"], path: "services.\(name).cpu_shares", diagnostics: &diagnostics),
            cpuPeriod: parseOptionalInt(mapping["cpu_period"], path: "services.\(name).cpu_period", diagnostics: &diagnostics),
            cpuQuota: parseOptionalInt(mapping["cpu_quota"], path: "services.\(name).cpu_quota", diagnostics: &diagnostics),
            cpuRTRuntime: parseOptionalNonEmptyString(mapping["cpu_rt_runtime"], path: "services.\(name).cpu_rt_runtime", diagnostics: &diagnostics),
            cpuRTPeriod: parseOptionalNonEmptyString(mapping["cpu_rt_period"], path: "services.\(name).cpu_rt_period", diagnostics: &diagnostics),
            cpuSet: parseOptionalNonEmptyString(mapping["cpuset"], path: "services.\(name).cpuset", diagnostics: &diagnostics),
            memory: stringify(mapping["mem_limit"] ?? mapping["memswap_limit"]),
            memoryReservation: stringify(mapping["mem_reservation"]),
            memorySwappiness: parseMemorySwappiness(mapping["mem_swappiness"], path: "services.\(name).mem_swappiness", diagnostics: &diagnostics),
            initProcess: parseBoolean(mapping["init"], defaultValue: false, path: "services.\(name).init", diagnostics: &diagnostics),
            stdinOpen: parseBoolean(mapping["stdin_open"], defaultValue: false, path: "services.\(name).stdin_open", diagnostics: &diagnostics),
            tty: parseBoolean(mapping["tty"], defaultValue: false, path: "services.\(name).tty", diagnostics: &diagnostics),
            readOnly: parseBoolean(mapping["read_only"], defaultValue: false, path: "services.\(name).read_only", diagnostics: &diagnostics),
            capAdd: parseStringList(mapping["cap_add"], path: "services.\(name).cap_add", diagnostics: &diagnostics),
            capDrop: parseStringList(mapping["cap_drop"], path: "services.\(name).cap_drop", diagnostics: &diagnostics),
            securityOptions: parseStringList(mapping["security_opt"], path: "services.\(name).security_opt", diagnostics: &diagnostics),
            dns: parseStringList(mapping["dns"], path: "services.\(name).dns", diagnostics: &diagnostics),
            dnsSearch: parseStringList(mapping["dns_search"], path: "services.\(name).dns_search", diagnostics: &diagnostics),
            dnsOptions: parseStringList(mapping["dns_opt"], path: "services.\(name).dns_opt", diagnostics: &diagnostics),
            shmSize: stringify(mapping["shm_size"]),
            tmpfs: parseStringList(mapping["tmpfs"], path: "services.\(name).tmpfs", diagnostics: &diagnostics),
            ulimits: parseUlimits(mapping["ulimits"], path: "services.\(name).ulimits", diagnostics: &diagnostics),
            restart: mapping["restart"] as? String,
            stopSignal: stringify(mapping["stop_signal"]),
            stopGracePeriod: stringify(mapping["stop_grace_period"]),
            labelFiles: labelFiles,
            labels: parseServiceLabels(
                labelFiles: labelFiles,
                labelsValue: mapping["labels"],
                sourcePath: sourcePath,
                path: "services.\(name)",
                diagnostics: &diagnostics
            ),
            containerName: parseContainerName(mapping["container_name"], path: "services.\(name).container_name", diagnostics: &diagnostics),
            hostname: parseRFC1123Hostname(
                mapping["hostname"],
                fieldName: "hostname",
                path: "services.\(name).hostname",
                diagnostics: &diagnostics
            ),
            domainName: parseRFC1123Hostname(
                mapping["domainname"],
                fieldName: "domainname",
                path: "services.\(name).domainname",
                diagnostics: &diagnostics
            ),
            macAddress: parseMACAddress(mapping["mac_address"], path: "services.\(name).mac_address", diagnostics: &diagnostics),
            extraHosts: parseKeyValueList(mapping["extra_hosts"], path: "services.\(name).extra_hosts", diagnostics: &diagnostics),
            privileged: parseOptionalBoolean(mapping["privileged"], path: "services.\(name).privileged", diagnostics: &diagnostics)
        )
    }

    private func implicitDefaultNetworkAttachmentsIfNeeded(
        _ attachments: [ComposeServiceNetworkAttachment],
        networksWasOmitted: Bool,
        networkMode: String?
    ) -> [ComposeServiceNetworkAttachment] {
        guard networksWasOmitted, networkMode == nil else {
            return attachments
        }
        return [ComposeServiceNetworkAttachment(name: "default")]
    }

    private func ensureImplicitDefaultNetwork(
        for services: [ComposeService],
        networks: inout [String: ComposeNetwork]
    ) {
        guard networks["default"] == nil else { return }
        guard services.contains(where: { $0.networks.contains("default") }) else { return }
        networks["default"] = ComposeNetwork(name: "default")
    }

    private func parseHealthcheck(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeHealthcheck? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a mapping for healthcheck."))
            return nil
        }

        let test = parseHealthcheckTest(map["test"], path: "\(path).test", diagnostics: &diagnostics)
        let disabledByTest = test.first?.uppercased() == "NONE"
        return ComposeHealthcheck(
            test: test,
            interval: stringify(map["interval"]),
            timeout: stringify(map["timeout"]),
            retries: parseOptionalInt(map["retries"], path: "\(path).retries", diagnostics: &diagnostics),
            startPeriod: stringify(map["start_period"]),
            startInterval: stringify(map["start_interval"]),
            disabled: parseBoolean(map["disable"], defaultValue: false, path: "\(path).disable", diagnostics: &diagnostics) || disabledByTest
        )
    }

    private func parseHealthcheckTest(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String] {
        guard let value else { return [] }
        if let string = stringify(value) {
            return ["CMD-SHELL", string]
        }
        if let list = value as? [Any] {
            let test = list.compactMap { stringify($0) }
            if let first = test.first?.uppercased(), !["NONE", "CMD", "CMD-SHELL"].contains(first) {
                diagnostics.append(.init(
                    severity: .warning,
                    path: path,
                    message: "Healthcheck test should start with NONE, CMD, or CMD-SHELL."
                ))
            }
            return test
        }
        diagnostics.append(.init(severity: .warning, path: path, message: "Expected a string or list for healthcheck test."))
        return []
    }

    private func parseProvider(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeProvider? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .error, path: path, message: "Expected a mapping for provider."))
            return nil
        }
        guard let type = parseOptionalNonEmptyString(map["type"], path: "\(path).type", diagnostics: &diagnostics) else {
            diagnostics.append(.init(severity: .error, path: "\(path).type", message: "provider.type is required."))
            return nil
        }

        return ComposeProvider(
            type: type,
            options: parseStringMap(map["options"], path: "\(path).options", diagnostics: &diagnostics)
        )
    }

    private func parseCredentialSpec(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeCredentialSpec? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .error, path: path, message: "Expected a mapping for credential_spec."))
            return nil
        }

        let spec = ComposeCredentialSpec(
            file: parseOptionalNonEmptyString(map["file"], path: "\(path).file", diagnostics: &diagnostics),
            registry: parseOptionalNonEmptyString(map["registry"], path: "\(path).registry", diagnostics: &diagnostics),
            config: parseOptionalNonEmptyString(map["config"], path: "\(path).config", diagnostics: &diagnostics)
        )
        if spec.file == nil, spec.registry == nil, spec.config == nil {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "credential_spec requires file, registry, or config."
            ))
            return nil
        }
        return spec
    }

    private func parseServiceModelGrants(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [ComposeServiceModelGrant] {
        guard let value else { return [] }
        if let list = value as? [Any] {
            return list.enumerated().compactMap { index, item in
                guard let name = parseOptionalNonEmptyString(item, path: "\(path)[\(index)]", diagnostics: &diagnostics) else {
                    diagnostics.append(.init(severity: .warning, path: "\(path)[\(index)]", message: "Unsupported model grant was ignored."))
                    return nil
                }
                return ComposeServiceModelGrant(name: name)
            }
        }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a list or mapping for models."))
            return []
        }

        return map.keys.sorted().compactMap { name in
            let grantPath = "\(path).\(name)"
            let value = map[name]
            if value == nil || value is NSNull {
                return ComposeServiceModelGrant(name: name)
            }
            guard let nested = value as? [String: Any] else {
                diagnostics.append(.init(severity: .warning, path: grantPath, message: "Expected a mapping for model grant options."))
                return ComposeServiceModelGrant(name: name)
            }

            diagnostics.append(contentsOf: warnForUnsupportedServiceModelGrantFields(path: grantPath, mapping: nested))
            return ComposeServiceModelGrant(
                name: name,
                endpointVariable: parseOptionalNonEmptyString(nested["endpoint_var"], path: "\(grantPath).endpoint_var", diagnostics: &diagnostics),
                modelVariable: parseOptionalNonEmptyString(nested["model_var"], path: "\(grantPath).model_var", diagnostics: &diagnostics)
            )
        }
    }

    private func parseDevelop(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeDevelop? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a mapping for develop."))
            return nil
        }

        diagnostics.append(contentsOf: warnForUnsupportedDevelopFields(path: path, mapping: map))
        return ComposeDevelop(
            watch: parseDevelopWatchRules(map["watch"], path: "\(path).watch", diagnostics: &diagnostics)
        )
    }

    private func parseDevelopWatchRules(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [ComposeDevelopWatchRule] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a list of develop watch rules."))
            return []
        }

        return list.enumerated().compactMap { index, item in
            let rulePath = "\(path)[\(index)]"
            guard let map = item as? [String: Any] else {
                diagnostics.append(.init(severity: .warning, path: rulePath, message: "Expected a mapping for develop watch rule."))
                return nil
            }

            diagnostics.append(contentsOf: warnForUnsupportedDevelopWatchFields(path: rulePath, mapping: map))
            guard
                let watchedPath = parseOptionalNonEmptyString(map["path"], path: "\(rulePath).path", diagnostics: &diagnostics),
                let action = parseOptionalNonEmptyString(map["action"], path: "\(rulePath).action", diagnostics: &diagnostics)
            else {
                diagnostics.append(.init(severity: .warning, path: rulePath, message: "Develop watch rule was ignored."))
                return nil
            }

            return ComposeDevelopWatchRule(
                path: watchedPath,
                action: action,
                target: parseOptionalNonEmptyString(map["target"], path: "\(rulePath).target", diagnostics: &diagnostics),
                ignore: parseStringList(map["ignore"], path: "\(rulePath).ignore", diagnostics: &diagnostics),
                include: parseStringList(map["include"], path: "\(rulePath).include", diagnostics: &diagnostics),
                initialSync: parseOptionalBoolean(map["initial_sync"], path: "\(rulePath).initial_sync", diagnostics: &diagnostics),
                exec: parseDevelopExec(map["exec"], path: "\(rulePath).exec", action: action, diagnostics: &diagnostics)
            )
        }
    }

    private func parseDevelopExec(
        _ value: Any?,
        path: String,
        action: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeDevelopExec? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a mapping for develop exec."))
            return nil
        }

        diagnostics.append(contentsOf: warnForUnsupportedDevelopExecFields(path: path, mapping: map))
        let command = parseCommand(map["command"], path: "\(path).command", diagnostics: &diagnostics)
        if action == "sync+exec", command.isEmpty {
            diagnostics.append(.init(
                severity: .error,
                path: "\(path).command",
                message: "Develop exec command is required for sync+exec."
            ))
        }

        return ComposeDevelopExec(
            command: command,
            user: parseOptionalNonEmptyString(map["user"], path: "\(path).user", diagnostics: &diagnostics),
            privileged: parseOptionalBoolean(map["privileged"], path: "\(path).privileged", diagnostics: &diagnostics),
            workingDirectory: parseOptionalNonEmptyString(map["working_dir"], path: "\(path).working_dir", diagnostics: &diagnostics),
            environment: parseEnvironment(map["environment"], path: "\(path).environment", diagnostics: &diagnostics)
        )
    }

    private func parseDeploy(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeDeploy? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a mapping for deploy."))
            return nil
        }

        diagnostics.append(contentsOf: warnForUnsupportedDeployFields(path: path, mapping: map))
        return ComposeDeploy(
            endpointMode: parseOptionalNonEmptyString(map["endpoint_mode"], path: "\(path).endpoint_mode", diagnostics: &diagnostics),
            labels: parseLabels(map["labels"]),
            mode: parseOptionalNonEmptyString(map["mode"], path: "\(path).mode", diagnostics: &diagnostics),
            replicas: parseOptionalInt(map["replicas"], path: "\(path).replicas", diagnostics: &diagnostics),
            placement: parseDeployPlacement(map["placement"], path: "\(path).placement", diagnostics: &diagnostics),
            resources: parseDeployResources(map["resources"], path: "\(path).resources", diagnostics: &diagnostics),
            restartPolicy: parseDeployRestartPolicy(map["restart_policy"], path: "\(path).restart_policy", diagnostics: &diagnostics),
            rollbackConfig: parseDeployUpdateConfig(map["rollback_config"], path: "\(path).rollback_config", diagnostics: &diagnostics),
            updateConfig: parseDeployUpdateConfig(map["update_config"], path: "\(path).update_config", diagnostics: &diagnostics)
        )
    }

    private func parseDeployPlacement(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeDeployPlacement? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a mapping for deploy placement."))
            return nil
        }

        diagnostics.append(contentsOf: warnForUnsupportedDeployPlacementFields(path: path, mapping: map))
        return ComposeDeployPlacement(
            constraints: parseStringList(map["constraints"], path: "\(path).constraints", diagnostics: &diagnostics),
            preferences: parseStringMapList(map["preferences"], path: "\(path).preferences", diagnostics: &diagnostics)
        )
    }

    private func parseDeployResources(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeDeployResources? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a mapping for deploy resources."))
            return nil
        }

        diagnostics.append(contentsOf: warnForUnsupportedDeployResourcesFields(path: path, mapping: map))
        return ComposeDeployResources(
            limits: parseDeployResourceSpec(map["limits"], path: "\(path).limits", diagnostics: &diagnostics),
            reservations: parseDeployResourceSpec(map["reservations"], path: "\(path).reservations", diagnostics: &diagnostics)
        )
    }

    private func parseDeployResourceSpec(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeDeployResourceSpec? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a mapping for deploy resource spec."))
            return nil
        }

        diagnostics.append(contentsOf: warnForUnsupportedDeployResourceSpecFields(path: path, mapping: map))
        return ComposeDeployResourceSpec(
            cpus: stringify(map["cpus"]),
            memory: stringify(map["memory"]),
            pids: parseOptionalInt(map["pids"], path: "\(path).pids", diagnostics: &diagnostics),
            devices: parseDeployDeviceReservations(map["devices"], path: "\(path).devices", diagnostics: &diagnostics),
            genericResources: parseDeployGenericResources(
                map["generic_resources"],
                path: "\(path).generic_resources",
                diagnostics: &diagnostics
            )
        )
    }

    private func parseDeployGenericResources(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [ComposeDeployGenericResource] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a list of deploy generic resources."))
            return []
        }

        return list.enumerated().compactMap { index, item in
            let itemPath = "\(path)[\(index)]"
            guard let map = item as? [String: Any] else {
                diagnostics.append(.init(severity: .warning, path: itemPath, message: "Expected a deploy generic resource mapping."))
                return nil
            }

            diagnostics.append(contentsOf: warnForUnsupportedDeployGenericResourceFields(path: itemPath, mapping: map))
            return ComposeDeployGenericResource(
                discreteResourceSpec: parseDeployGenericResourceSpec(
                    map["discrete_resource_spec"],
                    path: "\(itemPath).discrete_resource_spec",
                    diagnostics: &diagnostics
                ),
                namedResourceSpec: parseDeployGenericResourceSpec(
                    map["named_resource_spec"],
                    path: "\(itemPath).named_resource_spec",
                    diagnostics: &diagnostics
                )
            )
        }
    }

    private func parseDeployGenericResourceSpec(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeDeployGenericResourceSpec? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a deploy generic resource spec mapping."))
            return nil
        }

        diagnostics.append(contentsOf: warnForUnsupportedDeployGenericResourceSpecFields(path: path, mapping: map))
        return ComposeDeployGenericResourceSpec(
            kind: parseOptionalNonEmptyString(map["kind"], path: "\(path).kind", diagnostics: &diagnostics),
            value: stringify(map["value"])
        )
    }

    private func parseDeployDeviceReservations(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [ComposeDeployDeviceReservation] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a list of deploy device reservations."))
            return []
        }

        return list.enumerated().compactMap { index, item in
            let itemPath = "\(path)[\(index)]"
            guard let map = item as? [String: Any] else {
                diagnostics.append(.init(severity: .warning, path: itemPath, message: "Expected a deploy device reservation mapping."))
                return nil
            }

            diagnostics.append(contentsOf: warnForUnsupportedDeployDeviceFields(path: itemPath, mapping: map))
            let capabilities = parseStringList(map["capabilities"], path: "\(itemPath).capabilities", diagnostics: &diagnostics)
            if capabilities.isEmpty {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(itemPath).capabilities",
                    message: "Deploy device reservation capabilities are required."
                ))
            }
            if map["count"] != nil, map["device_ids"] != nil {
                diagnostics.append(.init(
                    severity: .error,
                    path: itemPath,
                    message: "Deploy device reservation count and device_ids are mutually exclusive."
                ))
            }
            return ComposeDeployDeviceReservation(
                capabilities: capabilities,
                driver: parseOptionalNonEmptyString(map["driver"], path: "\(itemPath).driver", diagnostics: &diagnostics),
                count: parseGPUCount(map["count"], path: "\(itemPath).count", diagnostics: &diagnostics),
                deviceIDs: parseStringList(map["device_ids"], path: "\(itemPath).device_ids", diagnostics: &diagnostics),
                options: parseStringMap(map["options"], path: "\(itemPath).options", diagnostics: &diagnostics)
            )
        }
    }

    private func parseDeployRestartPolicy(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeDeployRestartPolicy? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a mapping for deploy restart_policy."))
            return nil
        }

        diagnostics.append(contentsOf: warnForUnsupportedDeployRestartPolicyFields(path: path, mapping: map))
        return ComposeDeployRestartPolicy(
            condition: parseOptionalNonEmptyString(map["condition"], path: "\(path).condition", diagnostics: &diagnostics),
            delay: stringify(map["delay"]),
            maxAttempts: parseOptionalInt(map["max_attempts"], path: "\(path).max_attempts", diagnostics: &diagnostics),
            window: stringify(map["window"])
        )
    }

    private func parseDeployUpdateConfig(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeDeployUpdateConfig? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a mapping for deploy update config."))
            return nil
        }

        diagnostics.append(contentsOf: warnForUnsupportedDeployUpdateConfigFields(path: path, mapping: map))
        return ComposeDeployUpdateConfig(
            parallelism: parseOptionalInt(map["parallelism"], path: "\(path).parallelism", diagnostics: &diagnostics),
            delay: stringify(map["delay"]),
            failureAction: parseOptionalNonEmptyString(map["failure_action"], path: "\(path).failure_action", diagnostics: &diagnostics),
            monitor: stringify(map["monitor"]),
            maxFailureRatio: stringify(map["max_failure_ratio"]),
            order: parseOptionalNonEmptyString(map["order"], path: "\(path).order", diagnostics: &diagnostics)
        )
    }

    private func parseLifecycleHooks(
        _ value: Any?,
        path: String,
        requiresCommand: Bool,
        allowsImage: Bool,
        allowsPerReplica: Bool,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [ComposeLifecycleHook] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a list of lifecycle hook mappings."))
            return []
        }

        return list.enumerated().compactMap { index, item in
            let hookPath = "\(path)[\(index)]"
            guard let map = item as? [String: Any] else {
                diagnostics.append(.init(severity: .warning, path: hookPath, message: "Expected a mapping for lifecycle hook."))
                return nil
            }

            let command = parseCommand(map["command"], path: "\(hookPath).command", diagnostics: &diagnostics)
            if requiresCommand, command.isEmpty {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(hookPath).command",
                    message: "Lifecycle hook command is required."
                ))
            }

            return ComposeLifecycleHook(
                command: command,
                image: allowsImage ? parseOptionalNonEmptyString(map["image"], path: "\(hookPath).image", diagnostics: &diagnostics) : nil,
                user: parseOptionalNonEmptyString(map["user"], path: "\(hookPath).user", diagnostics: &diagnostics),
                privileged: parseOptionalBoolean(map["privileged"], path: "\(hookPath).privileged", diagnostics: &diagnostics),
                workingDirectory: parseOptionalNonEmptyString(map["working_dir"], path: "\(hookPath).working_dir", diagnostics: &diagnostics),
                environment: parseEnvironment(map["environment"], path: "\(hookPath).environment", diagnostics: &diagnostics),
                perReplica: allowsPerReplica ? parseOptionalBoolean(map["per_replica"], path: "\(hookPath).per_replica", diagnostics: &diagnostics) : nil
            )
        }
    }

    private func parseCommand(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String] {
        guard let value else { return [] }
        if let string = value as? String { return [string] }
        if let list = value as? [Any] { return list.compactMap { stringify($0) } }
        diagnostics.append(.init(severity: .warning, path: path, message: "Unsupported command format was ignored."))
        return []
    }

    private func parseEntrypoint(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let list = value as? [Any] {
            return list.compactMap { stringify($0) }.joined(separator: " ")
        }
        diagnostics.append(.init(severity: .warning, path: path, message: "Unsupported entrypoint format was ignored."))
        return nil
    }

    private func parseEnvironment(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String: String] {
        guard let value else { return [:] }
        if let map = value as? [String: Any] {
            return map.reduce(into: [:]) { result, pair in
                result[pair.key] = stringify(pair.value) ?? ""
            }
        }
        if let list = value as? [Any] {
            return list.reduce(into: [:]) { result, item in
                guard let raw = stringify(item) else { return }
                let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    result[String(parts[0])] = String(parts[1])
                } else {
                    result[raw] = ""
                }
            }
        }
        diagnostics.append(.init(severity: .warning, path: path, message: "Unsupported environment format was ignored."))
        return [:]
    }

    private func parseEnvFiles(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [ComposeEnvFile] {
        guard let value else { return [] }
        if let string = stringify(value) {
            return [ComposeEnvFile(path: string)]
        }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a string or list for env_file."))
            return []
        }

        return list.enumerated().compactMap { index, item in
            let itemPath = "\(path)[\(index)]"
            if let string = stringify(item) {
                return ComposeEnvFile(path: string)
            }
            guard let map = item as? [String: Any] else {
                diagnostics.append(.init(severity: .warning, path: itemPath, message: "Unsupported env_file item was ignored."))
                return nil
            }

            diagnostics.append(contentsOf: warnForUnsupportedEnvFileFields(path: itemPath, mapping: map))
            let required = parseOptionalBoolean(map["required"], path: "\(itemPath).required", diagnostics: &diagnostics) ?? true
            let format = parseOptionalNonEmptyString(map["format"], path: "\(itemPath).format", diagnostics: &diagnostics)
            guard let filePath = parseOptionalNonEmptyString(map["path"], path: "\(itemPath).path", diagnostics: &diagnostics) else {
                diagnostics.append(.init(severity: .warning, path: itemPath, message: "env_file item was ignored."))
                return nil
            }
            return ComposeEnvFile(
                path: filePath,
                required: required,
                format: format
            )
        }
    }

    private func parseStringList(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String] {
        guard let value else { return [] }
        if let string = stringify(value) { return [string] }
        if let list = value as? [Any] {
            return list.compactMap { stringify($0) }
        }
        diagnostics.append(.init(severity: .warning, path: path, message: "Expected a string or list of strings."))
        return []
    }

    private func parseBuild(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> ComposeBuild? {
        guard let value else { return nil }
        if let context = stringify(value) {
            return ComposeBuild(context: context)
        }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a string or mapping for build."))
            return nil
        }

        diagnostics.append(contentsOf: warnForUnsupportedBuildFields(path: path, mapping: map))
        return ComposeBuild(
            context: stringify(map["context"]) ?? ".",
            additionalContexts: parseKeyValueList(
                map["additional_contexts"],
                path: "\(path).additional_contexts",
                diagnostics: &diagnostics
            ),
            dockerfile: stringify(map["dockerfile"]),
            dockerfileInline: stringify(map["dockerfile_inline"]),
            args: parseBuildArgs(map["args"], path: "\(path).args", diagnostics: &diagnostics),
            cacheFrom: parseStringList(map["cache_from"], path: "\(path).cache_from", diagnostics: &diagnostics),
            cacheTo: parseStringList(map["cache_to"], path: "\(path).cache_to", diagnostics: &diagnostics),
            entitlements: parseStringList(map["entitlements"], path: "\(path).entitlements", diagnostics: &diagnostics),
            extraHosts: parseKeyValueList(map["extra_hosts"], path: "\(path).extra_hosts", diagnostics: &diagnostics),
            isolation: stringify(map["isolation"]),
            labels: parseServiceLabels(map["labels"], path: "\(path).labels", diagnostics: &diagnostics),
            network: stringify(map["network"]),
            privileged: parseOptionalBoolean(map["privileged"], path: "\(path).privileged", diagnostics: &diagnostics),
            secrets: parseServiceResourceGrants(
                map["secrets"],
                kind: "secrets",
                path: "\(path).secrets",
                diagnostics: &diagnostics
            ),
            shmSize: stringify(map["shm_size"]),
            ssh: parseStringList(map["ssh"], path: "\(path).ssh", diagnostics: &diagnostics),
            target: stringify(map["target"]),
            tags: parseStringList(map["tags"], path: "\(path).tags", diagnostics: &diagnostics),
            noCache: parseBoolean(map["no_cache"], defaultValue: false, path: "\(path).no_cache", diagnostics: &diagnostics),
            pull: parseBoolean(map["pull"], defaultValue: false, path: "\(path).pull", diagnostics: &diagnostics),
            platforms: parseStringList(map["platforms"], path: "\(path).platforms", diagnostics: &diagnostics),
            provenance: parseBuildScalar(map["provenance"], path: "\(path).provenance", diagnostics: &diagnostics),
            sbom: parseBuildScalar(map["sbom"], path: "\(path).sbom", diagnostics: &diagnostics),
            ulimits: parseUlimits(map["ulimits"], path: "\(path).ulimits", diagnostics: &diagnostics)
        )
    }

    private func parseKeyValueList(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String] {
        guard let value else { return [] }
        if let map = value as? [String: Any] {
            return map.keys.sorted().compactMap { key in
                guard let value = stringify(map[key]) else { return nil }
                return "\(key)=\(value)"
            }
        }
        return parseStringList(value, path: path, diagnostics: &diagnostics)
    }

    private func parseBuildScalar(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> String? {
        guard let value else { return nil }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let string = stringify(value) {
            return string
        }
        diagnostics.append(.init(severity: .warning, path: path, message: "Expected a string or boolean."))
        return nil
    }

    private func parseBuildArgs(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String] {
        guard let value else { return [] }
        if let map = value as? [String: Any] {
            return map.keys.sorted().map { key in
                guard let rawValue = map[key], let value = stringify(rawValue) else {
                    return key
                }
                return "\(key)=\(value)"
            }
        }
        if let list = value as? [Any] {
            return list.compactMap { stringify($0) }
        }
        diagnostics.append(.init(severity: .warning, path: path, message: "Expected a mapping or list of build args."))
        return []
    }

    private func parseUlimits(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String] {
        guard let value else { return [] }
        if let map = value as? [String: Any] {
            return map.keys.sorted().compactMap { key in
                guard let rawValue = map[key] else { return nil }
                if let nested = rawValue as? [String: Any] {
                    let soft = stringify(nested["soft"])
                    let hard = stringify(nested["hard"])
                    switch (soft, hard) {
                    case (.some(let soft), .some(let hard)):
                        return "\(key)=\(soft):\(hard)"
                    case (.some(let soft), .none):
                        return "\(key)=\(soft)"
                    case (.none, .some(let hard)):
                        return "\(key)=\(hard)"
                    case (.none, .none):
                        return key
                    }
                }
                guard let rawValue = stringify(rawValue) else { return key }
                return "\(key)=\(rawValue)"
            }
        }
        return parseStringList(value, path: path, diagnostics: &diagnostics)
    }

    private func parsePorts(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String] {
        guard let value else { return [] }
        if let string = stringify(value) { return [string] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a string, mapping, or list."))
            return []
        }
        return list.compactMap { item in
            if let string = stringify(item) { return string }
            if let map = item as? [String: Any] { return portSpec(from: map) }
            diagnostics.append(.init(severity: .warning, path: path, message: "Unsupported port item was ignored."))
            return nil
        }
    }

    private func parseVolumes(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String] {
        guard let value else { return [] }
        if let string = stringify(value) { return [string] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a string, mapping, or list."))
            return []
        }
        return list.compactMap { item in
            if let string = stringify(item) { return string }
            if let map = item as? [String: Any] { return volumeSpec(from: map) }
            diagnostics.append(.init(severity: .warning, path: path, message: "Unsupported volume item was ignored."))
            return nil
        }
    }

    private func portSpec(from map: [String: Any]) -> String? {
        guard let target = stringify(map["target"]) else { return nil }
        let protocolValue = stringify(map["protocol"])
        var prefix = ""
        if let hostIP = stringify(map["host_ip"] ?? map["hostIP"] ?? map["ip"]), !hostIP.isEmpty {
            prefix = "\(hostIP):"
        }
        let base: String
        if let published = stringify(map["published"]), !published.isEmpty {
            base = "\(prefix)\(published):\(target)"
        } else {
            base = target
        }
        if let protocolValue, !protocolValue.isEmpty, protocolValue != "tcp" {
            return "\(base)/\(protocolValue)"
        }
        return base
    }

    private func volumeSpec(from map: [String: Any]) -> String? {
        guard let target = stringify(map["target"] ?? map["destination"] ?? map["dst"]) else { return nil }
        guard let source = stringify(map["source"] ?? map["src"]) else { return target }
        var spec = "\(source):\(target)"
        if parseBool(map["read_only"]) == true {
            spec += ":ro"
        }
        return spec
    }

    private func parseNameReferences(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String] {
        guard let value else { return [] }
        if let list = value as? [Any] {
            return list.compactMap { stringify($0) }
        }
        if let map = value as? [String: Any] {
            return map.keys.sorted()
        }
        if let string = value as? String {
            return [string]
        }
        diagnostics.append(.init(severity: .warning, path: path, message: "Expected a string, list, or mapping."))
        return []
    }

    private func parseServiceNetworkAttachments(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [ComposeServiceNetworkAttachment] {
        guard let value else { return [] }
        if let string = stringify(value) {
            return [ComposeServiceNetworkAttachment(name: string)]
        }
        if let list = value as? [Any] {
            return list.enumerated().compactMap { index, item in
                guard let name = stringify(item), !name.isEmpty else {
                    diagnostics.append(.init(
                        severity: .warning,
                        path: "\(path)[\(index)]",
                        message: "Expected a network name string."
                    ))
                    return nil
                }
                return ComposeServiceNetworkAttachment(name: name)
            }
        }
        if let map = value as? [String: Any] {
            return map.keys.sorted().map { name in
                let attachmentPath = "\(path).\(name)"
                guard let options = map[name], !(options is NSNull) else {
                    return ComposeServiceNetworkAttachment(name: name)
                }
                guard let optionsMap = options as? [String: Any] else {
                    diagnostics.append(.init(
                        severity: .warning,
                        path: attachmentPath,
                        message: "Expected a mapping for service network options."
                    ))
                    return ComposeServiceNetworkAttachment(name: name)
                }

                diagnostics.append(contentsOf: warnForUnsupportedServiceNetworkFields(path: attachmentPath, mapping: optionsMap))
                return ComposeServiceNetworkAttachment(
                    name: name,
                    aliases: parseStringList(optionsMap["aliases"], path: "\(attachmentPath).aliases", diagnostics: &diagnostics),
                    interfaceName: parseOptionalNonEmptyString(
                        optionsMap["interface_name"],
                        path: "\(attachmentPath).interface_name",
                        diagnostics: &diagnostics
                    ),
                    ipv4Address: parseOptionalNonEmptyString(
                        optionsMap["ipv4_address"],
                        path: "\(attachmentPath).ipv4_address",
                        diagnostics: &diagnostics
                    ),
                    ipv6Address: parseOptionalNonEmptyString(
                        optionsMap["ipv6_address"],
                        path: "\(attachmentPath).ipv6_address",
                        diagnostics: &diagnostics
                    ),
                    linkLocalIPs: parseStringList(
                        optionsMap["link_local_ips"],
                        path: "\(attachmentPath).link_local_ips",
                        diagnostics: &diagnostics
                    ),
                    macAddress: parseMACAddress(optionsMap["mac_address"], path: "\(attachmentPath).mac_address", diagnostics: &diagnostics),
                    driverOptions: parseStringMap(optionsMap["driver_opts"], path: "\(attachmentPath).driver_opts", diagnostics: &diagnostics),
                    gatewayPriority: parseOptionalInt(optionsMap["gw_priority"], path: "\(attachmentPath).gw_priority", diagnostics: &diagnostics),
                    priority: parseOptionalInt(optionsMap["priority"], path: "\(attachmentPath).priority", diagnostics: &diagnostics)
                )
            }
        }
        diagnostics.append(.init(severity: .warning, path: path, message: "Expected a string, list, or mapping."))
        return []
    }

    private func parseLinkDependencies(_ links: [String]) -> [String] {
        links.compactMap { link in
            let service = link.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return service.isEmpty ? nil : service
        }
    }

    private func parseVolumesFromDependencies(_ volumesFrom: [String]) -> [String] {
        volumesFrom.compactMap { entry in
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let source = parts.first, source != "container", !source.isEmpty else { return nil }
            return source
        }
    }

    private func parseServiceNamespaceDependencies(
        networkMode: String?,
        pidMode: String?,
        ipcMode: String?
    ) -> [String] {
        [networkMode, pidMode, ipcMode].compactMap(serviceNamespaceDependency)
    }

    private func serviceNamespaceDependency(_ value: String?) -> String? {
        guard let value, value.hasPrefix("service:") else { return nil }
        let service = String(value.dropFirst("service:".count))
        return service.isEmpty ? nil : service
    }

    private func mergeImplicitDependencyMetadata(
        _ metadata: [String: ComposeServiceDependencyMetadata],
        implicitDependencies: [String]
    ) -> [String: ComposeServiceDependencyMetadata] {
        implicitDependencies.reduce(into: metadata) { result, dependency in
            result[dependency] = result[dependency] ?? ComposeServiceDependencyMetadata()
        }
    }

    private func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func parseDependsOnMetadata(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String: ComposeServiceDependencyMetadata] {
        guard let value else { return [:] }

        if let string = stringify(value) {
            return [string: ComposeServiceDependencyMetadata()]
        }

        if let list = value as? [Any] {
            return list.reduce(into: [String: ComposeServiceDependencyMetadata]()) { result, item in
                guard let service = stringify(item) else {
                    diagnostics.append(.init(
                        severity: .warning,
                        path: path,
                        message: "Unsupported depends_on item was ignored."
                    ))
                    return
                }
                result[service] = result[service] ?? ComposeServiceDependencyMetadata()
            }
        }

        if let map = value as? [String: Any] {
            return map.reduce(into: [String: ComposeServiceDependencyMetadata]()) { result, item in
                let service = item.key
                let dependencyPath = "\(path).\(service)"
                guard let dependencyMap = item.value as? [String: Any] else {
                    if item.value is NSNull {
                        result[service] = ComposeServiceDependencyMetadata()
                    } else {
                        diagnostics.append(.init(
                            severity: .warning,
                            path: dependencyPath,
                            message: "Expected a depends_on mapping for service dependency options."
                        ))
                        result[service] = ComposeServiceDependencyMetadata()
                    }
                    return
                }
                result[service] = parseDependencyMetadata(
                    dependencyMap,
                    path: dependencyPath,
                    diagnostics: &diagnostics
                )
            }
        } else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a string, list, or mapping."))
            return [:]
        }
    }

    private func parseDependencyMetadata(
        _ map: [String: Any],
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeServiceDependencyMetadata {
        let supported: Set<String> = ["condition", "restart", "required"]
        for key in map.keys.sorted() where !supported.contains(key) {
            diagnostics.append(.init(
                severity: .warning,
                path: "\(path).\(key)",
                message: "depends_on option is not implemented yet."
            ))
        }

        let condition: ComposeDependencyCondition
        if let rawCondition = stringify(map["condition"]) {
            if let parsed = ComposeDependencyCondition(rawValue: rawCondition) {
                condition = parsed
            } else {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "\(path).condition",
                    message: "Unknown depends_on condition '\(rawCondition)' was treated as service_started."
                ))
                condition = .serviceStarted
            }
        } else {
            condition = .serviceStarted
        }

        let restart = parseDependencyBool(
            map["restart"],
            defaultValue: false,
            path: "\(path).restart",
            diagnostics: &diagnostics
        )
        let required = parseDependencyBool(
            map["required"],
            defaultValue: true,
            path: "\(path).required",
            diagnostics: &diagnostics
        )

        return ComposeServiceDependencyMetadata(condition: condition, restart: restart, required: required)
    }

    private func parseDependencyBool(
        _ value: Any?,
        defaultValue: Bool,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> Bool {
        guard let value else { return defaultValue }
        if let parsed = parseBool(value) {
            return parsed
        }
        diagnostics.append(.init(
            severity: .warning,
            path: path,
            message: "Expected a boolean value; using \(defaultValue)."
        ))
        return defaultValue
    }

    private func parseBoolean(
        _ value: Any?,
        defaultValue: Bool,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> Bool {
        guard let value else { return defaultValue }
        if let parsed = parseBool(value) {
            return parsed
        }
        diagnostics.append(.init(
            severity: .warning,
            path: path,
            message: "Expected a boolean value; using \(defaultValue)."
        ))
        return defaultValue
    }

    private func parseOptionalBoolean(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> Bool? {
        guard let value else { return nil }
        if let parsed = parseBool(value) {
            return parsed
        }
        diagnostics.append(.init(
            severity: .warning,
            path: path,
            message: "Expected a boolean value."
        ))
        return nil
    }

    private func parseOptionalInt(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> Int? {
        guard let value else { return nil }
        if let int = value as? Int {
            return int
        }
        if let string = stringify(value), let int = Int(string) {
            return int
        }
        diagnostics.append(.init(
            severity: .warning,
            path: path,
            message: "Expected an integer value."
        ))
        return nil
    }

    private func parseServiceResourceGrants(
        _ value: Any?,
        kind: String,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [ComposeServiceResourceGrant] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a list."))
            return []
        }

        return list.compactMap { item in
            if let source = stringify(item) {
                return ComposeServiceResourceGrant(
                    source: source,
                    target: defaultResourceTarget(source: source, kind: kind)
                )
            }

            guard let map = item as? [String: Any], let source = stringify(map["source"]) else {
                diagnostics.append(.init(severity: .warning, path: path, message: "Unsupported resource grant was ignored."))
                return nil
            }

            return ComposeServiceResourceGrant(
                source: source,
                target: normalizeResourceTarget(
                    stringify(map["target"]),
                    source: source,
                    kind: kind
                ),
                uid: stringify(map["uid"]),
                gid: stringify(map["gid"]),
                mode: stringify(map["mode"])
            )
        }
    }

    private func defaultResourceTarget(source: String, kind: String) -> String {
        if kind == "secrets" {
            return "/run/secrets/\(source)"
        }
        return "/\(source)"
    }

    private func normalizeResourceTarget(_ target: String?, source: String, kind: String) -> String {
        guard let target, !target.isEmpty else {
            return defaultResourceTarget(source: source, kind: kind)
        }
        if target.hasPrefix("/") {
            return target
        }
        if kind == "secrets" {
            return "/run/secrets/\(target)"
        }
        return "/\(target)"
    }

    private func parseNetworks(_ value: Any?, diagnostics: inout [ComposeDiagnostic]) -> [String: ComposeNetwork] {
        guard let value else { return [:] }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: "networks", message: "Expected a mapping."))
            return [:]
        }
        return map.reduce(into: [:]) { result, pair in
            let mapping: [String: Any]
            if pair.value is NSNull {
                mapping = [:]
            } else if let nested = pair.value as? [String: Any] {
                mapping = nested
            } else {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "networks.\(pair.key)",
                    message: "Expected a mapping; using defaults."
                ))
                mapping = [:]
            }

            let name = pair.key
            let path = "networks.\(name)"
            diagnostics.append(contentsOf: warnForUnsupportedNetworkFields(path: path, mapping: mapping))
            result[name] = ComposeNetwork(
                name: name,
                customName: parseOptionalNonEmptyString(mapping["name"], path: "\(path).name", diagnostics: &diagnostics),
                external: parseExternal(mapping["external"]),
                externalName: parseExternalName(mapping["external"]),
                internalOnly: parseBool(mapping["internal"]) ?? false,
                attachable: parseOptionalBoolean(mapping["attachable"], path: "\(path).attachable", diagnostics: &diagnostics),
                driver: parseOptionalNonEmptyString(mapping["driver"], path: "\(path).driver", diagnostics: &diagnostics),
                driverOptions: parseStringMap(mapping["driver_opts"], path: "\(path).driver_opts", diagnostics: &diagnostics),
                enableIPv4: parseOptionalBoolean(mapping["enable_ipv4"], path: "\(path).enable_ipv4", diagnostics: &diagnostics),
                enableIPv6: parseOptionalBoolean(mapping["enable_ipv6"], path: "\(path).enable_ipv6", diagnostics: &diagnostics),
                ipam: parseNetworkIPAM(mapping["ipam"], path: "\(path).ipam", diagnostics: &diagnostics),
                labels: parseLabels(mapping["labels"])
            )
        }
    }

    private func parseNetworkIPAM(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> ComposeNetworkIPAM? {
        guard let value else { return nil }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a mapping for network ipam."))
            return nil
        }
        diagnostics.append(contentsOf: warnForUnsupportedNetworkIPAMFields(path: path, mapping: map))
        let config = parseNetworkIPAMConfigs(map["config"], path: "\(path).config", diagnostics: &diagnostics)
        return ComposeNetworkIPAM(
            driver: parseOptionalNonEmptyString(map["driver"], path: "\(path).driver", diagnostics: &diagnostics),
            options: parseStringMap(map["options"], path: "\(path).options", diagnostics: &diagnostics),
            config: config
        )
    }

    private func parseNetworkIPAMConfigs(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [ComposeNetworkIPAMConfig] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(severity: .warning, path: path, message: "Expected a list of network ipam config mappings."))
            return []
        }
        return list.enumerated().compactMap { index, item in
            let itemPath = "\(path)[\(index)]"
            guard let map = item as? [String: Any] else {
                diagnostics.append(.init(severity: .warning, path: itemPath, message: "Expected a mapping for network ipam config."))
                return nil
            }
            diagnostics.append(contentsOf: warnForUnsupportedNetworkIPAMConfigFields(path: itemPath, mapping: map))
            return ComposeNetworkIPAMConfig(
                subnet: parseOptionalNonEmptyString(map["subnet"], path: "\(itemPath).subnet", diagnostics: &diagnostics),
                ipRange: parseOptionalNonEmptyString(map["ip_range"], path: "\(itemPath).ip_range", diagnostics: &diagnostics),
                gateway: parseOptionalNonEmptyString(map["gateway"], path: "\(itemPath).gateway", diagnostics: &diagnostics),
                auxAddresses: parseStringMap(map["aux_addresses"], path: "\(itemPath).aux_addresses", diagnostics: &diagnostics)
            )
        }
    }

    private func parseVolumes(_ value: Any?, diagnostics: inout [ComposeDiagnostic]) -> [String: ComposeVolume] {
        guard let value else { return [:] }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: "volumes", message: "Expected a mapping."))
            return [:]
        }
        return map.reduce(into: [:]) { result, pair in
            let mapping: [String: Any]
            if pair.value is NSNull {
                mapping = [:]
            } else if let nested = pair.value as? [String: Any] {
                mapping = nested
            } else {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "volumes.\(pair.key)",
                    message: "Expected a mapping; using defaults."
                ))
                mapping = [:]
            }

            let name = pair.key
            let path = "volumes.\(name)"
            diagnostics.append(contentsOf: warnForUnsupportedVolumeFields(path: path, mapping: mapping))
            result[name] = ComposeVolume(
                name: name,
                customName: parseOptionalNonEmptyString(mapping["name"], path: "\(path).name", diagnostics: &diagnostics),
                external: parseExternal(mapping["external"]),
                externalName: parseExternalName(mapping["external"]),
                driver: parseOptionalNonEmptyString(mapping["driver"], path: "\(path).driver", diagnostics: &diagnostics),
                driverOptions: parseStringMap(mapping["driver_opts"], path: "\(path).driver_opts", diagnostics: &diagnostics),
                labels: parseLabels(mapping["labels"])
            )
        }
    }

    private func parseConfigs(_ value: Any?, diagnostics: inout [ComposeDiagnostic]) -> [String: ComposeConfig] {
        parseResourceMap(value, kind: "configs", diagnostics: &diagnostics) { name, mapping in
            ComposeConfig(
                name: name,
                file: stringify(mapping["file"]),
                environment: stringify(mapping["environment"]),
                content: stringify(mapping["content"]),
                external: parseExternal(mapping["external"]),
                externalName: parseExternalName(mapping["external"]) ?? stringify(mapping["name"])
            )
        }
    }

    private func parseSecrets(_ value: Any?, diagnostics: inout [ComposeDiagnostic]) -> [String: ComposeSecret] {
        parseResourceMap(value, kind: "secrets", diagnostics: &diagnostics) { name, mapping in
            ComposeSecret(
                name: name,
                file: stringify(mapping["file"]),
                environment: stringify(mapping["environment"]),
                external: parseExternal(mapping["external"]),
                externalName: parseExternalName(mapping["external"]) ?? stringify(mapping["name"])
            )
        }
    }

    private func parseModels(_ value: Any?, diagnostics: inout [ComposeDiagnostic]) -> [String: ComposeModelDefinition] {
        guard let value else { return [:] }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: "models", message: "Expected a mapping."))
            return [:]
        }

        return map.reduce(into: [:]) { result, pair in
            let path = "models.\(pair.key)"
            if pair.value is NSNull {
                result[pair.key] = ComposeModelDefinition(name: pair.key)
                return
            }
            if let model = stringify(pair.value) {
                result[pair.key] = ComposeModelDefinition(name: pair.key, model: model)
                return
            }
            guard let nested = pair.value as? [String: Any] else {
                diagnostics.append(.init(
                    severity: .warning,
                    path: path,
                    message: "Expected a string or mapping for model definition."
                ))
                result[pair.key] = ComposeModelDefinition(name: pair.key)
                return
            }

            diagnostics.append(contentsOf: warnForUnsupportedModelDefinitionFields(path: path, mapping: nested))
            result[pair.key] = ComposeModelDefinition(
                name: pair.key,
                model: stringify(nested["model"]),
                endpoint: stringify(nested["endpoint"]),
                options: parseModelDefinitionOptions(nested, path: path, diagnostics: &diagnostics)
            )
        }
    }

    private func parseModelDefinitionOptions(
        _ mapping: [String: Any],
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String: String] {
        mapping.reduce(into: [:]) { result, pair in
            guard !["model", "endpoint"].contains(pair.key), !isExtensionField(pair.key) else { return }
            if let value = stringify(pair.value) {
                result[pair.key] = value
            } else if !(pair.value is NSNull) {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "\(path).\(pair.key)",
                    message: "Unsupported model definition option value was ignored."
                ))
            }
        }
    }

    private func parseResourceMap<T>(
        _ value: Any?,
        kind: String,
        diagnostics: inout [ComposeDiagnostic],
        build: (String, [String: Any]) -> T
    ) -> [String: T] {
        guard let value else { return [:] }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(severity: .warning, path: kind, message: "Expected a mapping."))
            return [:]
        }
        return map.reduce(into: [:]) { result, pair in
            if pair.value is NSNull {
                result[pair.key] = build(pair.key, [:])
            } else if let nested = pair.value as? [String: Any] {
                result[pair.key] = build(pair.key, nested)
            } else {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "\(kind).\(pair.key)",
                    message: "Expected a mapping; using defaults."
                ))
                result[pair.key] = build(pair.key, [:])
            }
        }
    }

    private func parseExternal(_ value: Any?) -> Bool {
        if let bool = parseBool(value) { return bool }
        if value is [String: Any] { return true }
        return false
    }

    private func parseExternalName(_ value: Any?) -> String? {
        guard let map = value as? [String: Any] else { return nil }
        return stringify(map["name"])
    }

    private func parseBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        guard let string = value as? String else { return nil }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
    }

    private func parseLabels(_ value: Any?) -> [String] {
        if let list = value as? [Any] {
            return list.compactMap { stringify($0) }
        }
        if let map = value as? [String: Any] {
            return map.keys.sorted().map { "\($0)=\(stringify(map[$0]) ?? "")" }
        }
        return []
    }

    private func parseServiceLabels(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String] {
        validateServiceLabels(parseLabels(value), path: path, diagnostics: &diagnostics)
    }

    private func parseServiceLabels(
        labelFiles: [String],
        labelsValue: Any?,
        sourcePath: String,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String] {
        let fileLabels = labelFiles.enumerated().flatMap { index, labelFile in
            parseLabelFile(
                labelFile,
                sourcePath: sourcePath,
                path: "\(path).label_file[\(index)]",
                diagnostics: &diagnostics
            )
        }
        return validateServiceLabels(
            mergeLabels(fileLabels + parseLabels(labelsValue)),
            path: "\(path).labels",
            diagnostics: &diagnostics
        )
    }

    private func parseLabelFile(
        _ labelFile: String,
        sourcePath: String,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String] {
        let resolvedPath = resolvePath(labelFile, relativeTo: containingDirectory(for: sourcePath))
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            diagnostics.append(.init(
                severity: .warning,
                path: path,
                message: "Label file does not exist: \(labelFile)"
            ))
            return []
        }

        do {
            let contents = try String(contentsOfFile: resolvedPath, encoding: .utf8)
            return contents
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { line in
                    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else { return line }
                    return "\(parts[0])=\(parts[1])"
                }
        } catch {
            diagnostics.append(.init(
                severity: .warning,
                path: path,
                message: "Unable to read label file: \(labelFile)"
            ))
            return []
        }
    }

    private func mergeLabels(_ labels: [String]) -> [String] {
        labels.reduce(into: [String]()) { result, label in
            let key = label.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? label
            result.removeAll {
                let existingKey = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? $0
                return existingKey == key
            }
            result.append(label)
        }
    }

    private func validateServiceLabels(_ labels: [String], path: String, diagnostics: inout [ComposeDiagnostic]) -> [String] {
        return labels.compactMap { label in
            let key = label.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? label
            if key == "com.docker.compose" || key.hasPrefix("com.docker.compose.") {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(path).\(key)",
                    message: "The com.docker.compose label prefix is reserved by the Compose Specification."
                ))
                return nil
            }
            return label
        }
    }

    private func parseContainerName(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let name = stringify(value), !name.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty container_name string."
            ))
            return nil
        }

        guard isValidContainerName(name) else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "container_name must match [a-zA-Z0-9][a-zA-Z0-9_.-]+."
            ))
            return nil
        }

        return name
    }

    private func parseNetworkMode(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let mode = stringify(value), !mode.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty network_mode string."
            ))
            return nil
        }

        return mode
    }

    private func parsePIDMode(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let mode = stringify(value), !mode.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty pid string."
            ))
            return nil
        }

        return mode
    }

    private func parseIPCMode(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let mode = stringify(value), !mode.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty ipc string."
            ))
            return nil
        }

        return mode
    }

    private func parseUTSMode(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let mode = stringify(value), !mode.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty uts string."
            ))
            return nil
        }

        return mode
    }

    private func parseUserNamespaceMode(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let mode = stringify(value), !mode.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty userns_mode string."
            ))
            return nil
        }

        return mode
    }

    private func parseCgroupMode(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let mode = stringify(value), !mode.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty cgroup string."
            ))
            return nil
        }

        guard mode == "host" || mode == "private" else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "cgroup must be either 'host' or 'private'."
            ))
            return nil
        }

        return mode
    }

    private func parseIsolation(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let isolation = stringify(value), !isolation.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty isolation string."
            ))
            return nil
        }

        return isolation
    }

    private func parseCgroupParent(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let parent = stringify(value), !parent.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty cgroup_parent string."
            ))
            return nil
        }

        return parent
    }

    private func parseDeviceCgroupRules(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a list of strings."
            ))
            return []
        }

        var rules: [String] = []
        for (index, item) in list.enumerated() {
            guard let rule = stringify(item), !rule.isEmpty else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(path)[\(index)]",
                    message: "Expected a string value."
                ))
                continue
            }
            rules.append(rule)
        }
        return rules
    }

    private func parseServiceDevices(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a list of device mapping strings."
            ))
            return []
        }

        var devices: [String] = []
        for (index, item) in list.enumerated() {
            guard let device = stringify(item), !device.isEmpty else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(path)[\(index)]",
                    message: "Expected a non-empty device mapping string."
                ))
                continue
            }
            devices.append(device)
        }
        return devices
    }

    private func parseGPUs(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> ComposeGPURequest? {
        guard let value else { return nil }
        if let string = stringify(value) {
            guard string == "all" else {
                diagnostics.append(.init(
                    severity: .error,
                    path: path,
                    message: "gpus must be 'all' or a list of GPU device requests."
                ))
                return nil
            }
            return ComposeGPURequest(all: true)
        }

        guard let list = value as? [Any] else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "gpus must be 'all' or a list of GPU device requests."
            ))
            return nil
        }

        var requests: [ComposeGPUDeviceRequest] = []
        for (index, item) in list.enumerated() {
            guard let mapping = item as? [String: Any] else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(path)[\(index)]",
                    message: "Expected a GPU device request mapping."
                ))
                continue
            }

            diagnostics.append(contentsOf: warnForUnsupportedGPUFields(path: "\(path)[\(index)]", mapping: mapping))
            requests.append(ComposeGPUDeviceRequest(
                driver: parseOptionalNonEmptyString(mapping["driver"], path: "\(path)[\(index)].driver", diagnostics: &diagnostics),
                count: parseGPUCount(mapping["count"], path: "\(path)[\(index)].count", diagnostics: &diagnostics),
                deviceIDs: parseStringList(mapping["device_ids"], path: "\(path)[\(index)].device_ids", diagnostics: &diagnostics),
                capabilities: parseStringList(mapping["capabilities"], path: "\(path)[\(index)].capabilities", diagnostics: &diagnostics),
                options: parseStringMap(mapping["options"], path: "\(path)[\(index)].options", diagnostics: &diagnostics)
            ))
        }

        return ComposeGPURequest(devices: requests)
    }

    private func parseGroupAdd(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a list of group names or IDs."
            ))
            return []
        }

        var groups: [String] = []
        for (index, item) in list.enumerated() {
            guard let group = stringify(item), !group.isEmpty else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(path)[\(index)]",
                    message: "Expected a non-empty group name or ID."
                ))
                continue
            }
            groups.append(group)
        }
        return groups
    }

    private func parseSysctls(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String: String] {
        guard let value else { return [:] }
        if let mapping = value as? [String: Any] {
            return mapping.keys.sorted().reduce(into: [:]) { result, key in
                guard !key.isEmpty, let rawValue = mapping[key], let stringValue = stringify(rawValue) else {
                    diagnostics.append(.init(
                        severity: .error,
                        path: "\(path).\(key)",
                        message: "Expected a string, number, or boolean sysctl value."
                    ))
                    return
                }
                result[key] = stringValue
            }
        }

        guard let list = value as? [Any] else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a mapping or list of sysctl entries."
            ))
            return [:]
        }

        var sysctls: [String: String] = [:]
        for (index, item) in list.enumerated() {
            guard let entry = stringify(item), !entry.isEmpty else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(path)[\(index)]",
                    message: "Expected a non-empty sysctl entry."
                ))
                continue
            }
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(path)[\(index)]",
                    message: "Expected a sysctl entry in KEY=VALUE form."
                ))
                continue
            }
            sysctls[String(parts[0])] = String(parts[1])
        }
        return sysctls
    }

    private func parseOOMScoreAdjustment(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> Int? {
        guard let score = parseOptionalInt(value, path: path, diagnostics: &diagnostics) else { return nil }
        guard (-1000...1000).contains(score) else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "oom_score_adj must be within the [-1000, 1000] range."
            ))
            return nil
        }
        return score
    }

    private func parsePIDsLimit(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> Int? {
        guard let limit = parseOptionalInt(value, path: path, diagnostics: &diagnostics) else { return nil }
        guard limit >= -1 else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "pids_limit must be -1 or greater."
            ))
            return nil
        }
        return limit
    }

    private func parseScale(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> Int? {
        guard let scale = parseOptionalInt(value, path: path, diagnostics: &diagnostics) else { return nil }
        guard scale >= 0 else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "scale must be 0 or greater."
            ))
            return nil
        }
        return scale
    }

    private func parseMemorySwappiness(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> Int? {
        guard let swappiness = parseOptionalInt(value, path: path, diagnostics: &diagnostics) else { return nil }
        guard (0...100).contains(swappiness) else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "mem_swappiness must be within the [0, 100] range."
            ))
            return nil
        }
        return swappiness
    }

    private func parseLogging(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> ComposeLogging? {
        guard let value else { return nil }
        guard let mapping = value as? [String: Any] else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a logging mapping."
            ))
            return nil
        }

        return ComposeLogging(
            driver: parseOptionalNonEmptyString(mapping["driver"], path: "\(path).driver", diagnostics: &diagnostics),
            options: parseStringMap(mapping["options"], path: "\(path).options", diagnostics: &diagnostics)
        )
    }

    private func parseBlockIOConfig(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> ComposeBlockIOConfig? {
        guard let value else { return nil }
        guard let mapping = value as? [String: Any] else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a blkio_config mapping."
            ))
            return nil
        }

        return ComposeBlockIOConfig(
            weight: parseBlockIOWeight(mapping["weight"], path: "\(path).weight", diagnostics: &diagnostics),
            weightDevice: parseBlockIODeviceWeights(
                mapping["weight_device"],
                path: "\(path).weight_device",
                diagnostics: &diagnostics
            ),
            deviceReadBps: parseBlockIODeviceRates(
                mapping["device_read_bps"],
                path: "\(path).device_read_bps",
                diagnostics: &diagnostics
            ),
            deviceReadIOps: parseBlockIODeviceRates(
                mapping["device_read_iops"],
                path: "\(path).device_read_iops",
                diagnostics: &diagnostics
            ),
            deviceWriteBps: parseBlockIODeviceRates(
                mapping["device_write_bps"],
                path: "\(path).device_write_bps",
                diagnostics: &diagnostics
            ),
            deviceWriteIOps: parseBlockIODeviceRates(
                mapping["device_write_iops"],
                path: "\(path).device_write_iops",
                diagnostics: &diagnostics
            )
        )
    }

    private func parseBlockIOWeight(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> Int? {
        guard let weight = parseOptionalInt(value, path: path, diagnostics: &diagnostics) else { return nil }
        guard (10...1000).contains(weight) else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "blkio_config weight must be within the [10, 1000] range."
            ))
            return nil
        }
        return weight
    }

    private func parseBlockIODeviceWeights(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [ComposeBlockIODeviceWeight] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a list of blkio_config device weight mappings."
            ))
            return []
        }

        return list.enumerated().compactMap { index, item in
            guard let mapping = item as? [String: Any] else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(path)[\(index)]",
                    message: "Expected a blkio_config device weight mapping."
                ))
                return nil
            }
            guard let devicePath = parseRequiredNonEmptyString(
                mapping["path"],
                path: "\(path)[\(index)].path",
                diagnostics: &diagnostics
            ) else {
                return nil
            }
            guard let weight = parseRequiredBlockIOWeight(
                mapping["weight"],
                path: "\(path)[\(index)].weight",
                diagnostics: &diagnostics
            ) else {
                return nil
            }
            return ComposeBlockIODeviceWeight(path: devicePath, weight: weight)
        }
    }

    private func parseBlockIODeviceRates(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [ComposeBlockIODeviceRate] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a list of blkio_config device rate mappings."
            ))
            return []
        }

        return list.enumerated().compactMap { index, item in
            guard let mapping = item as? [String: Any] else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "\(path)[\(index)]",
                    message: "Expected a blkio_config device rate mapping."
                ))
                return nil
            }
            guard let devicePath = parseRequiredNonEmptyString(
                mapping["path"],
                path: "\(path)[\(index)].path",
                diagnostics: &diagnostics
            ) else {
                return nil
            }
            guard let rate = parseRequiredNonEmptyString(
                mapping["rate"],
                path: "\(path)[\(index)].rate",
                diagnostics: &diagnostics
            ) else {
                return nil
            }
            return ComposeBlockIODeviceRate(path: devicePath, rate: rate)
        }
    }

    private func parseRequiredBlockIOWeight(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> Int? {
        guard value != nil else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected an integer value."
            ))
            return nil
        }
        return parseBlockIOWeight(value, path: path, diagnostics: &diagnostics)
    }

    private func parseRequiredNonEmptyString(
        _ value: Any?,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> String? {
        guard value != nil else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty string."
            ))
            return nil
        }
        return parseOptionalNonEmptyString(value, path: path, diagnostics: &diagnostics)
    }

    private func parseGPUCount(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let count = stringify(value), !count.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty GPU count value."
            ))
            return nil
        }
        return count
    }

    private func parseOptionalNonEmptyString(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let string = stringify(value), !string.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty string."
            ))
            return nil
        }
        return string
    }

    private func parseStringMap(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [String: String] {
        guard let value else { return [:] }
        guard let mapping = value as? [String: Any] else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a string mapping."
            ))
            return [:]
        }

        return mapping.reduce(into: [:]) { result, pair in
            result[pair.key] = stringify(pair.value) ?? ""
        }
    }

    private func parseStringMapList(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> [[String: String]] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            diagnostics.append(.init(
                severity: .warning,
                path: path,
                message: "Expected a list of string mappings."
            ))
            return []
        }

        return list.enumerated().compactMap { index, item in
            guard let mapping = item as? [String: Any] else {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "\(path)[\(index)]",
                    message: "Expected a string mapping."
                ))
                return nil
            }
            return mapping.reduce(into: [:]) { result, pair in
                result[pair.key] = stringify(pair.value) ?? ""
            }
        }
    }

    private func parseMACAddress(_ value: Any?, path: String, diagnostics: inout [ComposeDiagnostic]) -> String? {
        guard let value else { return nil }
        guard let address = stringify(value), !address.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty mac_address string."
            ))
            return nil
        }

        guard isValidMACAddress(address) else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "mac_address must be a valid MAC address."
            ))
            return nil
        }

        return address
    }

    private func parseRFC1123Hostname(
        _ value: Any?,
        fieldName: String,
        path: String,
        diagnostics: inout [ComposeDiagnostic]
    ) -> String? {
        guard let value else { return nil }
        guard let hostname = stringify(value), !hostname.isEmpty else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "Expected a non-empty \(fieldName) string."
            ))
            return nil
        }

        guard isValidRFC1123Hostname(hostname) else {
            diagnostics.append(.init(
                severity: .error,
                path: path,
                message: "\(fieldName) must be a valid RFC 1123 hostname."
            ))
            return nil
        }

        return hostname
    }

    private func isValidContainerName(_ value: String) -> Bool {
        guard let first = value.first, isASCIIAlphanumeric(first), value.count >= 2 else {
            return false
        }
        return value.allSatisfy { isASCIIAlphanumeric($0) || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private func isValidRFC1123Hostname(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }

        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63 else { return false }
            guard let first = label.first, let last = label.last else { return false }
            return isASCIIAlphanumeric(first)
                && isASCIIAlphanumeric(last)
                && label.allSatisfy { isASCIIAlphanumeric($0) || $0 == "-" }
        }
    }

    private func isValidMACAddress(_ value: String) -> Bool {
        if value.count == 12 {
            return value.allSatisfy(isASCIIHexDigit)
        }

        let separator: Character
        if value.contains(":") {
            separator = ":"
        } else if value.contains("-") {
            separator = "-"
        } else {
            return false
        }

        let octets = value.split(separator: separator, omittingEmptySubsequences: false)
        return octets.count == 6 && octets.allSatisfy { octet in
            octet.count == 2 && octet.allSatisfy(isASCIIHexDigit)
        }
    }

    private func isASCIIHexDigit(_ character: Character) -> Bool {
        guard character.isASCII, let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        return (48...57).contains(scalar.value)
            || (65...70).contains(scalar.value)
            || (97...102).contains(scalar.value)
    }

    private func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    private func sanitize(_ value: String) -> String {
        let mapped = value.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    private func warnForUnsupportedTopLevel(_ root: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["name", "services", "networks", "volumes", "configs", "secrets", "models", "version", "include"]
        return root.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(severity: .warning, path: $0, message: "Top-level field is not implemented yet.")
        }
    }

    private func isExtensionField(_ key: String) -> Bool {
        key.hasPrefix("x-")
    }

    private func warnForUnsupportedServiceFields(name: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = [
            "image", "build", "command", "entrypoint", "environment", "env_file", "annotations", "attach", "blkio_config",
            "ports", "expose", "volumes", "volumes_from", "networks", "network_mode", "links", "external_links", "pid", "ipc", "uts", "userns_mode", "isolation", "cgroup", "cgroup_parent", "device_cgroup_rules", "devices", "gpus",
            "group_add", "sysctls", "depends_on", "profiles", "working_dir",
            "configs", "secrets", "user", "platform", "cpus", "cpu_count", "cpu_percent", "cpu_shares", "cpu_period", "cpu_quota", "cpu_rt_runtime", "cpu_rt_period", "cpuset", "mem_limit", "memswap_limit", "mem_reservation", "mem_swappiness", "restart", "labels", "label_file", "container_name",
            "pull_policy", "healthcheck", "stdin_open", "tty", "read_only", "cap_add", "cap_drop", "security_opt",
            "dns", "dns_search", "dns_opt", "shm_size", "tmpfs", "ulimits", "init", "oom_kill_disable", "oom_score_adj", "pids_limit", "stop_signal", "stop_grace_period",
            "extra_hosts", "privileged", "hostname", "domainname", "mac_address", "logging", "runtime", "scale", "storage_opt", "use_api_socket", "provider", "credential_spec",
            "models", "develop", "deploy", "post_start", "pre_start", "pre_stop"
        ]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "services.\(name).\($0)",
                message: "Service field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDeployFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = [
            "endpoint_mode", "labels", "mode", "replicas", "placement", "resources",
            "restart_policy", "rollback_config", "update_config"
        ]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Deploy field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDeployPlacementFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["constraints", "preferences"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Deploy placement field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDeployResourcesFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["limits", "reservations"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Deploy resources field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDeployResourceSpecFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["cpus", "memory", "pids", "devices", "generic_resources"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Deploy resource field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDeployGenericResourceFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["discrete_resource_spec", "named_resource_spec"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Deploy generic resource field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDeployGenericResourceSpecFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["kind", "value"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Deploy generic resource spec field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDeployDeviceFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["capabilities", "driver", "count", "device_ids", "options"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Deploy device reservation field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDeployRestartPolicyFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["condition", "delay", "max_attempts", "window"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Deploy restart_policy field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDeployUpdateConfigFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["parallelism", "delay", "failure_action", "monitor", "max_failure_ratio", "order"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Deploy update config field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedServiceNetworkFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = [
            "aliases", "interface_name", "ipv4_address", "ipv6_address", "link_local_ips",
            "mac_address", "driver_opts", "gw_priority", "priority"
        ]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Service network option is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedNetworkFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = [
            "name", "driver", "driver_opts", "attachable", "enable_ipv4", "enable_ipv6",
            "external", "internal", "ipam", "labels"
        ]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Network field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedNetworkIPAMFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["driver", "options", "config"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Network ipam field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedNetworkIPAMConfigFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["subnet", "ip_range", "gateway", "aux_addresses"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Network ipam config field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedVolumeFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["name", "driver", "driver_opts", "external", "labels"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Volume field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedEnvFileFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["format", "path", "required"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "env_file field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDevelopFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["watch"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Develop field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDevelopWatchFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["action", "exec", "ignore", "include", "initial_sync", "path", "target"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Develop watch field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedDevelopExecFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["command", "environment", "privileged", "user", "working_dir"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Develop exec field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedModelDefinitionFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["model", "endpoint"]
        return mapping.keys.sorted().filter {
            !supported.contains($0) && !isExtensionField($0) && stringify(mapping[$0]) == nil
        }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Model definition field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedServiceModelGrantFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["endpoint_var", "model_var"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Model grant field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedGPUFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = ["driver", "count", "device_ids", "capabilities", "options"]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "GPU device request field is not implemented yet."
            )
        }
    }

    private func warnForUnsupportedBuildFields(path: String, mapping: [String: Any]) -> [ComposeDiagnostic] {
        let supported: Set<String> = [
            "additional_contexts", "args", "cache_from", "cache_to", "context", "dockerfile",
            "dockerfile_inline", "entitlements", "extra_hosts", "isolation", "labels", "network",
            "privileged", "provenance", "pull", "sbom", "secrets", "shm_size", "ssh",
            "target", "tags", "no_cache", "platforms", "ulimits"
        ]
        return mapping.keys.sorted().filter { !supported.contains($0) && !isExtensionField($0) }.map {
            ComposeDiagnostic(
                severity: .warning,
                path: "\(path).\($0)",
                message: "Build option is not implemented yet."
            )
        }
    }

    private func stringify(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as Int:
            return String(value)
        case let value as Double:
            return String(value)
        case let value as Bool:
            return value ? "true" : "false"
        default:
            return nil
        }
    }
}

private struct IncludeEntry {
    let paths: [String]
    let envFiles: [String]?
    let includedFrom: String?

    init(paths: [String], envFiles: [String]? = nil, includedFrom: String? = nil) {
        self.paths = paths
        self.envFiles = envFiles
        self.includedFrom = includedFrom
    }
}

private struct ServiceExtendsReference {
    let service: String
    let file: String?

    init(service: String, file: String? = nil) {
        self.service = service
        self.file = file
    }
}

private struct ServiceExtendsKey: Hashable {
    let sourcePath: String
    let service: String
}

private struct ComposeTaggedValue {
    enum Kind {
        case reset
        case override
    }

    let kind: Kind
    let value: Any
}

private struct LoadedRoot {
    let root: [String: Any]
    let includeEntries: [IncludeEntry]
    let diagnostics: [ComposeDiagnostic]
    let remoteIncludes: [ComposeRemoteInclude]
}

private struct ResolvedRoot {
    let root: [String: Any]
    let remoteIncludes: [ComposeRemoteInclude]
}

private struct LoadedComposeSource {
    let yaml: String
    let remoteInclude: ComposeRemoteInclude?

    init(yaml: String, remoteInclude: ComposeRemoteInclude? = nil) {
        self.yaml = yaml
        self.remoteInclude = remoteInclude
    }
}
