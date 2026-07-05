import Foundation

public enum PlanAction: String, Codable, Sendable {
    case buildService
    case delegateService
    case pullImage
    case pushImage
    case listImages
    case createNetwork
    case createVolume
    case createService
    case runService
    case startService
    case stopService
    case restartService
    case killService
    case pauseService
    case unpauseService
    case attachService
    case waitService
    case scaleService
    case commitService
    case eventsProject
    case execService
    case copyService
    case logsService
    case listServices
    case topService
    case statsService
    case deleteService
    case deleteNetwork
    case deleteVolume
}

public enum PlannedGeneratedFileKind: String, Codable, Sendable {
    case inlineDockerfile
}

public struct PlannedGeneratedFile: Codable, Equatable, Sendable {
    public var kind: PlannedGeneratedFileKind
    public var path: String
    public var contents: String
    public var diagnosticsPath: String

    public init(
        kind: PlannedGeneratedFileKind,
        path: String,
        contents: String,
        diagnosticsPath: String
    ) {
        self.kind = kind
        self.path = path
        self.contents = contents
        self.diagnosticsPath = diagnosticsPath
    }
}

public struct PlannedCommand: Codable, Equatable, Sendable {
    public var action: PlanAction
    public var service: String?
    public var arguments: [String]
    public var diagnostics: [ComposeDiagnostic]
    public var generatedFiles: [PlannedGeneratedFile]

    public init(
        action: PlanAction,
        service: String? = nil,
        arguments: [String],
        diagnostics: [ComposeDiagnostic] = [],
        generatedFiles: [PlannedGeneratedFile] = []
    ) {
        self.action = action
        self.service = service
        self.arguments = arguments
        self.diagnostics = diagnostics
        self.generatedFiles = generatedFiles
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case service
        case arguments
        case diagnostics
        case generatedFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(PlanAction.self, forKey: .action)
        service = try container.decodeIfPresent(String.self, forKey: .service)
        arguments = try container.decode([String].self, forKey: .arguments)
        diagnostics = try container.decodeIfPresent([ComposeDiagnostic].self, forKey: .diagnostics) ?? []
        generatedFiles = try container.decodeIfPresent([PlannedGeneratedFile].self, forKey: .generatedFiles) ?? []
    }
}

public enum AppleContainerReadinessCondition: String, Codable, Sendable {
    case started
    case healthy
    case completedSuccessfully
}

public struct AppleContainerReadinessRequirement: Codable, Equatable, Sendable {
    public var service: String
    public var condition: AppleContainerReadinessCondition
    public var containerName: String
    public var timeoutMilliseconds: Int
    public var pollIntervalMilliseconds: Int

    public init(
        service: String,
        condition: AppleContainerReadinessCondition = .started,
        containerName: String,
        timeoutMilliseconds: Int = 30_000,
        pollIntervalMilliseconds: Int = 250
    ) {
        self.service = service
        self.condition = condition
        self.containerName = containerName
        self.timeoutMilliseconds = timeoutMilliseconds
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
    }
}

public struct AppleContainerExecutionNode: Codable, Equatable, Sendable {
    public var commandIndex: Int
    public var action: PlanAction
    public var service: String?
    public var dependsOnCommandIndexes: [Int]
    public var readiness: [AppleContainerReadinessRequirement]

    public init(
        commandIndex: Int,
        action: PlanAction,
        service: String? = nil,
        dependsOnCommandIndexes: [Int] = [],
        readiness: [AppleContainerReadinessRequirement] = []
    ) {
        self.commandIndex = commandIndex
        self.action = action
        self.service = service
        self.dependsOnCommandIndexes = dependsOnCommandIndexes
        self.readiness = readiness
    }
}

public struct AppleContainerExecutionEdge: Codable, Equatable, Sendable {
    public var fromCommandIndex: Int
    public var toCommandIndex: Int
    public var reason: String
    public var dependencyMetadata: AppleContainerDependencyMetadata?

    public init(
        fromCommandIndex: Int,
        toCommandIndex: Int,
        reason: String = "depends_on",
        dependencyMetadata: AppleContainerDependencyMetadata? = nil
    ) {
        self.fromCommandIndex = fromCommandIndex
        self.toCommandIndex = toCommandIndex
        self.reason = reason
        self.dependencyMetadata = dependencyMetadata
    }
}

public struct AppleContainerDependencyMetadata: Codable, Equatable, Sendable {
    public var condition: ComposeDependencyCondition
    public var restart: Bool
    public var required: Bool

    public init(
        condition: ComposeDependencyCondition = .serviceStarted,
        restart: Bool = false,
        required: Bool = true
    ) {
        self.condition = condition
        self.restart = restart
        self.required = required
    }
}

public struct AppleContainerExecutionGraph: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var nodes: [AppleContainerExecutionNode]
    public var edges: [AppleContainerExecutionEdge]

    public init(
        nodes: [AppleContainerExecutionNode],
        edges: [AppleContainerExecutionEdge],
        schemaVersion: String = ContainerComposeMetadata.executionGraphSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.nodes = nodes
        self.edges = edges
    }

    public init(
        project: ComposeProject,
        commands: [PlannedCommand],
        emitReadinessChecks: Bool = false
    ) {
        let servicesByName = Dictionary(uniqueKeysWithValues: project.services.map { ($0.name, $0) })
        let commandIndexByService = Self.commandIndexByService(commands)
        let buildCommandIndexByService = Self.buildCommandIndexByService(commands)
        let pullCommandIndexByService = Self.pullCommandIndexByService(commands)

        var edges: [AppleContainerExecutionEdge] = []
        var dependencyIndexesByCommandIndex: [Int: [Int]] = [:]
        var readinessByCommandIndex: [Int: [AppleContainerReadinessRequirement]] = [:]

        for (index, command) in commands.enumerated() {
            guard let serviceName = command.service, let service = servicesByName[serviceName] else {
                continue
            }

            if Self.commandUsesServiceImage(command.action), let buildIndex = buildCommandIndexByService[serviceName], buildIndex != index {
                edges.append(.init(
                    fromCommandIndex: buildIndex,
                    toCommandIndex: index,
                    reason: "build"
                ))
                dependencyIndexesByCommandIndex[index, default: []].append(buildIndex)
            }

            if Self.commandUsesServiceImage(command.action), let pullIndex = pullCommandIndexByService[serviceName], pullIndex != index {
                edges.append(.init(
                    fromCommandIndex: pullIndex,
                    toCommandIndex: index,
                    reason: "pull"
                ))
                dependencyIndexesByCommandIndex[index, default: []].append(pullIndex)
            }

            guard Self.commandDefinesServiceRuntime(command.action) else {
                continue
            }

            for dependency in service.dependsOn.sorted() {
                guard let dependencyIndex = commandIndexByService[dependency], dependencyIndex != index else {
                    continue
                }

                let metadata = service.dependsOnMetadata[dependency] ?? ComposeServiceDependencyMetadata()
                edges.append(.init(
                    fromCommandIndex: dependencyIndex,
                    toCommandIndex: index,
                    dependencyMetadata: .init(
                        condition: metadata.condition,
                        restart: metadata.restart,
                        required: metadata.required
                    )
                ))
                dependencyIndexesByCommandIndex[index, default: []].append(dependencyIndex)

                if emitReadinessChecks && Self.commandRequiresDependencyReadiness(command.action) {
                    let dependencyContainerName = servicesByName[dependency].map {
                        Self.containerName(project: project.name, service: $0)
                    } ?? Self.generatedContainerName(project: project.name, service: dependency)
                    readinessByCommandIndex[index, default: []].append(.init(
                        service: dependency,
                        condition: Self.readinessCondition(for: metadata.condition),
                        containerName: dependencyContainerName
                    ))
                }
            }
        }

        nodes = commands.enumerated().map { index, command in
            AppleContainerExecutionNode(
                commandIndex: index,
                action: command.action,
                service: command.service,
                dependsOnCommandIndexes: Array(Set(dependencyIndexesByCommandIndex[index] ?? [])).sorted(),
                readiness: readinessByCommandIndex[index] ?? []
            )
        }
        self.edges = edges
        schemaVersion = ContainerComposeMetadata.executionGraphSchemaVersion
    }

    private static func commandIndexByService(_ commands: [PlannedCommand]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, command) in commands.enumerated() {
            guard let service = command.service, commandDefinesServiceRuntime(command.action) else {
                continue
            }
            result[service] = result[service] ?? index
        }
        return result
    }

    private static func buildCommandIndexByService(_ commands: [PlannedCommand]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, command) in commands.enumerated() where command.action == .buildService {
            guard let service = command.service else { continue }
            result[service] = result[service] ?? index
        }
        return result
    }

    private static func pullCommandIndexByService(_ commands: [PlannedCommand]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, command) in commands.enumerated() where command.action == .pullImage {
            guard let service = command.service else { continue }
            result[service] = result[service] ?? index
        }
        return result
    }

    private static func commandDefinesServiceRuntime(_ action: PlanAction) -> Bool {
        switch action {
        case .createService, .delegateService, .runService, .startService, .restartService:
            return true
        case .buildService, .pullImage, .pushImage, .listImages, .createNetwork, .createVolume, .stopService, .killService, .pauseService, .unpauseService, .attachService, .waitService, .scaleService, .commitService, .eventsProject, .execService, .copyService, .logsService, .listServices, .topService, .statsService, .deleteService, .deleteNetwork, .deleteVolume:
            return false
        }
    }

    private static func commandUsesServiceImage(_ action: PlanAction) -> Bool {
        switch action {
        case .createService, .runService:
            return true
        case .buildService, .delegateService, .pullImage, .pushImage, .listImages, .createNetwork, .createVolume, .startService, .stopService, .restartService, .killService, .pauseService, .unpauseService, .attachService, .waitService, .scaleService, .commitService, .eventsProject, .execService, .copyService, .logsService, .listServices, .topService, .statsService, .deleteService, .deleteNetwork, .deleteVolume:
            return false
        }
    }

    private static func commandRequiresDependencyReadiness(_ action: PlanAction) -> Bool {
        switch action {
        case .runService, .startService, .restartService:
            return true
        case .createService, .delegateService, .buildService, .pullImage, .pushImage, .listImages, .createNetwork, .createVolume, .stopService, .killService, .pauseService, .unpauseService, .attachService, .waitService, .scaleService, .commitService, .eventsProject, .execService, .copyService, .logsService, .listServices, .topService, .statsService, .deleteService, .deleteNetwork, .deleteVolume:
            return false
        }
    }

    private static func readinessCondition(for condition: ComposeDependencyCondition) -> AppleContainerReadinessCondition {
        switch condition {
        case .serviceStarted:
            return .started
        case .serviceHealthy:
            return .healthy
        case .serviceCompletedSuccessfully:
            return .completedSuccessfully
        }
    }

    private static func containerName(project: String, service: ComposeService) -> String {
        service.containerName ?? generatedContainerName(project: project, service: service.name)
    }

    private static func generatedContainerName(project: String, service: String) -> String {
        "\(sanitize(project))_\(sanitize(service))_1"
    }

    private static func sanitize(_ value: String) -> String {
        let mapped = value.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }
}

public struct AppleContainerPlan: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var projectName: String
    public var sourcePath: String
    public var runtime: String
    public var executable: String
    public var runtimeStatus: AppleContainerRuntimeStatus?
    public var operation: String
    public var selectedServices: [String]
    public var commands: [PlannedCommand]
    public var executionGraph: AppleContainerExecutionGraph?
    public var diagnostics: [ComposeDiagnostic]

    public init(
        project: ComposeProject,
        operation: String,
        commands: [PlannedCommand],
        runtime: String = "apple-container",
        executable: String = "container",
        runtimeStatus: AppleContainerRuntimeStatus? = nil,
        schemaVersion: String = ContainerComposeMetadata.planSchemaVersion,
        selectedServices: [String] = [],
        emitReadinessChecks: Bool = false,
        executionGraph: AppleContainerExecutionGraph? = nil
    ) {
        self.schemaVersion = schemaVersion
        projectName = project.name
        sourcePath = project.sourcePath
        self.runtime = runtime
        self.executable = executable
        self.runtimeStatus = runtimeStatus
        self.operation = operation
        self.selectedServices = selectedServices
        self.commands = commands
        self.executionGraph = executionGraph ?? AppleContainerExecutionGraph(
            project: project,
            commands: commands,
            emitReadinessChecks: emitReadinessChecks
        )
        diagnostics = project.diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectName
        case sourcePath
        case runtime
        case executable
        case runtimeStatus
        case operation
        case selectedServices
        case commands
        case executionGraph
        case diagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        projectName = try container.decode(String.self, forKey: .projectName)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        runtime = try container.decode(String.self, forKey: .runtime)
        executable = try container.decode(String.self, forKey: .executable)
        runtimeStatus = try container.decodeIfPresent(AppleContainerRuntimeStatus.self, forKey: .runtimeStatus)
        operation = try container.decode(String.self, forKey: .operation)
        selectedServices = try container.decodeIfPresent([String].self, forKey: .selectedServices) ?? []
        commands = try container.decode([PlannedCommand].self, forKey: .commands)
        executionGraph = try container.decodeIfPresent(AppleContainerExecutionGraph.self, forKey: .executionGraph)
        diagnostics = try container.decode([ComposeDiagnostic].self, forKey: .diagnostics)
    }
}

public struct AppleContainerExecOptions: Codable, Equatable, Sendable {
    public var detach: Bool
    public var environment: [String]
    public var envFiles: [String]
    public var user: String?
    public var workdir: String?
    public var interactive: Bool
    public var tty: Bool
    public var replicaIndex: Int
    public var privileged: Bool

    public init(
        detach: Bool = false,
        environment: [String] = [],
        envFiles: [String] = [],
        user: String? = nil,
        workdir: String? = nil,
        interactive: Bool = true,
        tty: Bool = true,
        replicaIndex: Int = 1,
        privileged: Bool = false
    ) {
        self.detach = detach
        self.environment = environment
        self.envFiles = envFiles
        self.user = user
        self.workdir = workdir
        self.interactive = interactive
        self.tty = tty
        self.replicaIndex = replicaIndex
        self.privileged = privileged
    }
}

public struct AppleContainerAttachOptions: Codable, Equatable, Sendable {
    public var detachKeys: String?
    public var replicaIndex: Int
    public var attachStdin: Bool
    public var signalProxy: Bool

    public init(
        detachKeys: String? = nil,
        replicaIndex: Int = 1,
        attachStdin: Bool = true,
        signalProxy: Bool = true
    ) {
        self.detachKeys = detachKeys
        self.replicaIndex = replicaIndex
        self.attachStdin = attachStdin
        self.signalProxy = signalProxy
    }
}

public struct AppleContainerWaitOptions: Codable, Equatable, Sendable {
    public var downProject: Bool

    public init(downProject: Bool = false) {
        self.downProject = downProject
    }
}

public struct AppleContainerScaleOptions: Codable, Equatable, Sendable {
    public var noDependencies: Bool

    public init(noDependencies: Bool = false) {
        self.noDependencies = noDependencies
    }
}

public struct AppleContainerCommitOptions: Codable, Equatable, Sendable {
    public var author: String?
    public var changes: [String]
    public var message: String?
    public var replicaIndex: Int
    public var pause: Bool
    public var repository: String?

    public init(
        author: String? = nil,
        changes: [String] = [],
        message: String? = nil,
        replicaIndex: Int = 1,
        pause: Bool = true,
        repository: String? = nil
    ) {
        self.author = author
        self.changes = changes
        self.message = message
        self.replicaIndex = replicaIndex
        self.pause = pause
        self.repository = repository
    }
}

public struct AppleContainerEventsOptions: Codable, Equatable, Sendable {
    public var outputJSON: Bool
    public var since: String?
    public var until: String?

    public init(
        outputJSON: Bool = false,
        since: String? = nil,
        until: String? = nil
    ) {
        self.outputJSON = outputJSON
        self.since = since
        self.until = until
    }
}

public struct AppleContainerCopyOptions: Codable, Equatable, Sendable {
    public var replicaIndex: Int
    public var archive: Bool
    public var followLink: Bool
    public var includeRunContainers: Bool

    public init(
        replicaIndex: Int = 1,
        archive: Bool = false,
        followLink: Bool = false,
        includeRunContainers: Bool = false
    ) {
        self.replicaIndex = replicaIndex
        self.archive = archive
        self.followLink = followLink
        self.includeRunContainers = includeRunContainers
    }
}

public struct AppleContainerPushOptions: Codable, Equatable, Sendable {
    public var includeDependencies: Bool
    public var ignorePushFailures: Bool
    public var quiet: Bool

    public init(
        includeDependencies: Bool = false,
        ignorePushFailures: Bool = false,
        quiet: Bool = false
    ) {
        self.includeDependencies = includeDependencies
        self.ignorePushFailures = ignorePushFailures
        self.quiet = quiet
    }
}

public struct AppleContainerImagesOptions: Codable, Equatable, Sendable {
    public var format: String
    public var quiet: Bool
    public var verbose: Bool

    public init(
        format: String = "table",
        quiet: Bool = false,
        verbose: Bool = false
    ) {
        self.format = format
        self.quiet = quiet
        self.verbose = verbose
    }
}

public struct AppleContainerCreateOptions: Codable, Equatable, Sendable {
    public var noBuild: Bool

    public init(noBuild: Bool = false) {
        self.noBuild = noBuild
    }
}

public struct AppleContainerInlineDockerfilePathResolver: Sendable {
    public var rootDirectory: String

    public init(
        rootDirectory: String = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("container-compose")
            .appendingPathComponent("inline-dockerfiles")
            .path
    ) {
        self.rootDirectory = rootDirectory
    }

    public func path(
        projectName: String,
        serviceName: String,
        sourcePath: String,
        buildContext: String,
        contents: String
    ) -> String {
        let fingerprint = stableHexHash([
            projectName,
            serviceName,
            sourcePath,
            buildContext,
            contents
        ].joined(separator: "\u{1f}"))
        return URL(fileURLWithPath: rootDirectory)
            .appendingPathComponent(sanitizePathComponent(projectName))
            .appendingPathComponent("\(sanitizePathComponent(serviceName))-\(fingerprint).Dockerfile")
            .path
    }

    private func sanitizePathComponent(_ value: String) -> String {
        let mapped = value.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let sanitized = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? "default" : sanitized
    }

    private func stableHexHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

public struct AppleContainerRunOptions: Codable, Equatable, Sendable {
    public var detach: Bool
    public var remove: Bool
    public var noDependencies: Bool
    public var servicePorts: Bool
    public var publish: [String]
    public var name: String?
    public var entrypoint: String?
    public var command: [String]
    public var environment: [String]
    public var envFiles: [String]
    public var user: String?
    public var workdir: String?
    public var interactive: Bool
    public var tty: Bool

    public init(
        detach: Bool = false,
        remove: Bool = false,
        noDependencies: Bool = false,
        servicePorts: Bool = false,
        publish: [String] = [],
        name: String? = nil,
        entrypoint: String? = nil,
        command: [String] = [],
        environment: [String] = [],
        envFiles: [String] = [],
        user: String? = nil,
        workdir: String? = nil,
        interactive: Bool = true,
        tty: Bool = true
    ) {
        self.detach = detach
        self.remove = remove
        self.noDependencies = noDependencies
        self.servicePorts = servicePorts
        self.publish = publish
        self.name = name
        self.entrypoint = entrypoint
        self.command = command
        self.environment = environment
        self.envFiles = envFiles
        self.user = user
        self.workdir = workdir
        self.interactive = interactive
        self.tty = tty
    }
}

public struct AppleContainerPlanner: Sendable {
    private let inlineDockerfilePathResolver: AppleContainerInlineDockerfilePathResolver

    public init(inlineDockerfilePathResolver: AppleContainerInlineDockerfilePathResolver = .init()) {
        self.inlineDockerfilePathResolver = inlineDockerfilePathResolver
    }

    public func planUp(project: ComposeProject, detach: Bool = true, services selectedServices: [String] = []) -> [PlannedCommand] {
        var commands: [PlannedCommand] = []
        let servicesToRun = selectedServicesForUp(project.services, selectedServices: selectedServices)
        let isFullProjectPlan = selectedServices.isEmpty

        for service in servicesToRun {
            if let pullCommand = policyPullCommand(project: project, service: service) {
                commands.append(pullCommand)
            }
        }

        for service in servicesToRun where shouldPlanBuild(for: service) {
            commands.append(buildCommand(project: project, service: service))
        }

        commands.append(contentsOf: resourceCreationCommands(
            project: project,
            services: servicesToRun,
            isFullProjectPlan: isFullProjectPlan
        ))

        for service in servicesToRun {
            commands.append(planRun(
                project: project,
                service: service,
                detach: detach,
                runOptions: .init(
                    detach: detach,
                    servicePorts: true,
                    interactive: service.stdinOpen,
                    tty: service.tty
                ),
                oneOff: false
            ))
        }

        return commands
    }

    public func planRun(
        project: ComposeProject,
        service serviceName: String?,
        options: AppleContainerRunOptions = .init()
    ) -> [PlannedCommand] {
        guard let serviceName, !serviceName.isEmpty else {
            return [
                PlannedCommand(
                    action: .runService,
                    arguments: ["run"],
                    diagnostics: [
                        .init(
                            severity: .error,
                            path: "run.service",
                            message: "Run planning requires a service name."
                        )
                    ]
                )
            ]
        }

        guard let service = project.services.first(where: { $0.name == serviceName }) else {
            return [
                PlannedCommand(
                    action: .runService,
                    service: serviceName,
                    arguments: ["run"],
                    diagnostics: [
                        .init(
                            severity: .error,
                            path: "services.\(serviceName)",
                            message: "Selected service is not present in the active Compose model. Check the service name or enabled profiles."
                        )
                    ]
                )
            ]
        }

        var commands: [PlannedCommand] = []
        if !options.noDependencies, !service.dependsOn.isEmpty {
            commands.append(contentsOf: planUp(project: project, services: service.dependsOn))
        }
        commands.append(contentsOf: resourceCreationCommands(
            project: project,
            services: [service],
            isFullProjectPlan: false,
            excluding: commands
        ))

        if let pullCommand = policyPullCommand(project: project, service: service) {
            commands.append(pullCommand)
        }
        if shouldPlanBuild(for: service) {
            commands.append(buildCommand(project: project, service: service))
        }

        commands.append(planRun(project: project, service: service, detach: options.detach, runOptions: options))
        return commands
    }

    public func planCreate(
        project: ComposeProject,
        services selectedServices: [String] = [],
        options: AppleContainerCreateOptions = .init()
    ) -> [PlannedCommand] {
        var commands: [PlannedCommand] = []
        let servicesToCreate = selectedServicesForUp(project.services, selectedServices: selectedServices)
        let isFullProjectPlan = selectedServices.isEmpty

        for service in servicesToCreate {
            if let pullCommand = policyPullCommand(project: project, service: service) {
                commands.append(pullCommand)
            }
        }

        if !options.noBuild {
            for service in servicesToCreate where shouldPlanBuild(for: service) {
                commands.append(buildCommand(project: project, service: service))
            }
        }

        commands.append(contentsOf: resourceCreationCommands(
            project: project,
            services: servicesToCreate,
            isFullProjectPlan: isFullProjectPlan
        ))

        for service in servicesToCreate {
            commands.append(planRun(
                project: project,
                service: service,
                detach: false,
                runOptions: .init(
                    servicePorts: true,
                    interactive: service.stdinOpen,
                    tty: service.tty
                ),
                oneOff: false,
                verb: "create",
                action: .createService
            ))
        }

        return commands
    }

    public func planDown(project: ComposeProject, removeVolumes: Bool = false) -> [PlannedCommand] {
        var commands = orderedServices(project.services).reversed().flatMap { service in
            let name = containerName(project: project.name, service: service)
            return [
                stopCommand(project: project, service: service),
                PlannedCommand(action: .deleteService, service: service.name, arguments: ["delete", "--force", name])
            ]
        }

        let networks = project.networks.values
            .filter { !$0.external }
            .sorted { $0.name < $1.name }
            .map { networkResourceName(project: project.name, network: $0) }
        if !networks.isEmpty {
            commands.append(.init(action: .deleteNetwork, arguments: ["network", "delete"] + networks))
        }

        if removeVolumes {
            let volumes = project.volumes.values
                .filter { !$0.external }
                .sorted { $0.name < $1.name }
                .map { volumeResourceName(project: project.name, volume: $0) }
            if !volumes.isEmpty {
                commands.append(.init(action: .deleteVolume, arguments: ["volume", "delete"] + volumes))
            }
        }

        return commands
    }

    public func planStart(project: ComposeProject, services selectedServices: [String] = []) -> [PlannedCommand] {
        selectedOrderedServices(project.services, selectedServices: selectedServices).map { service in
            PlannedCommand(
                action: .startService,
                service: service.name,
                arguments: ["start", containerName(project: project.name, service: service)]
            )
        }
    }

    public func planPull(project: ComposeProject, services selectedServices: [String] = []) -> [PlannedCommand] {
        selectedOrderedServices(project.services, selectedServices: selectedServices).compactMap { service in
            imagePullCommand(for: service)
        }
    }

    public func planPush(
        project: ComposeProject,
        services selectedServices: [String] = [],
        options: AppleContainerPushOptions = .init()
    ) -> [PlannedCommand] {
        let servicesToPush = options.includeDependencies
            ? selectedServicesForUp(project.services, selectedServices: selectedServices)
            : selectedOrderedServices(project.services, selectedServices: selectedServices)

        return servicesToPush.compactMap { service in
            imagePushCommand(for: service, options: options)
        }
    }

    public func planImages(
        project: ComposeProject,
        services selectedServices: [String] = [],
        options: AppleContainerImagesOptions = .init()
    ) -> [PlannedCommand] {
        var arguments = ["image", "list"]
        if !options.format.isEmpty, options.format != "table" {
            arguments.append(contentsOf: ["--format", options.format])
        }
        if options.quiet {
            arguments.append("--quiet")
        }
        if options.verbose {
            arguments.append("--verbose")
        }

        var diagnostics: [ComposeDiagnostic] = [
            .init(
                severity: .warning,
                path: "images",
                message: "Apple Container does not expose Compose project filtering for image lists yet; this lists images from the local runtime."
            )
        ]
        if !selectedServices.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "images.services",
                message: "Docker Compose SERVICE filters cannot be mapped to container image list yet; selected services remain visible in plan metadata."
            ))
        }

        return [
            PlannedCommand(
                action: .listImages,
                arguments: arguments,
                diagnostics: diagnostics
            )
        ]
    }

    public func planBuild(project: ComposeProject, services selectedServices: [String] = []) -> [PlannedCommand] {
        selectedOrderedServices(project.services, selectedServices: selectedServices).compactMap { service in
            guard service.build != nil else { return nil }
            return buildCommand(project: project, service: service)
        }
    }

    public func planStop(project: ComposeProject, services selectedServices: [String] = []) -> [PlannedCommand] {
        selectedOrderedServices(project.services, selectedServices: selectedServices)
            .reversed()
            .map { stopCommand(project: project, service: $0) }
    }

    public func planRestart(project: ComposeProject, services selectedServices: [String] = []) -> [PlannedCommand] {
        let stopCommands = planStop(project: project, services: selectedServices)
        let startCommands = planStart(project: project, services: selectedServices).map { command in
            PlannedCommand(
                action: .restartService,
                service: command.service,
                arguments: command.arguments,
                diagnostics: command.diagnostics
            )
        }
        return stopCommands + startCommands
    }

    public func planKill(
        project: ComposeProject,
        services selectedServices: [String] = [],
        signal: String? = nil
    ) -> [PlannedCommand] {
        selectedOrderedServices(project.services, selectedServices: selectedServices)
            .reversed()
            .map { service in
                var arguments = ["kill"]
                if let signal, !signal.isEmpty {
                    arguments.append(contentsOf: ["--signal", signal])
                }
                arguments.append(containerName(project: project.name, service: service))
                return PlannedCommand(
                    action: .killService,
                    service: service.name,
                    arguments: arguments
                )
            }
    }

    public func planPause(project: ComposeProject, services selectedServices: [String] = []) -> [PlannedCommand] {
        selectedOrderedServices(project.services, selectedServices: selectedServices).map { service in
            PlannedCommand(
                action: .pauseService,
                service: service.name,
                arguments: ["pause", containerName(project: project.name, service: service)],
                diagnostics: [
                    .init(
                        severity: .warning,
                        path: "pause",
                        message: "Docker Compose pause suspends running service containers, but Apple Container pause support is unavailable or unverified; this planned action is not executable yet."
                    )
                ]
            )
        }
    }

    public func planUnpause(project: ComposeProject, services selectedServices: [String] = []) -> [PlannedCommand] {
        selectedOrderedServices(project.services, selectedServices: selectedServices).map { service in
            PlannedCommand(
                action: .unpauseService,
                service: service.name,
                arguments: ["unpause", containerName(project: project.name, service: service)],
                diagnostics: [
                    .init(
                        severity: .warning,
                        path: "unpause",
                        message: "Docker Compose unpause resumes paused service containers, but Apple Container unpause support is unavailable or unverified; this planned action is not executable yet."
                    )
                ]
            )
        }
    }

    public func planAttach(
        project: ComposeProject,
        service serviceName: String?,
        options: AppleContainerAttachOptions = .init()
    ) -> [PlannedCommand] {
        guard let serviceName, !serviceName.isEmpty else {
            return [
                PlannedCommand(
                    action: .attachService,
                    arguments: ["attach"],
                    diagnostics: [
                        .init(
                            severity: .error,
                            path: "attach.service",
                            message: "Attach planning requires a service name."
                        )
                    ]
                )
            ]
        }

        guard let service = selectedOrderedServices(project.services, selectedServices: [serviceName]).first else {
            return []
        }

        var arguments = ["attach"]
        var diagnostics: [ComposeDiagnostic] = [
            .init(
                severity: .warning,
                path: "attach",
                message: "Docker Compose attach connects local stdin, stdout, and stderr to a running service container, but Apple Container attach support is unavailable or unverified; this planned action is not executable yet."
            )
        ]

        if let detachKeys = options.detachKeys, !detachKeys.isEmpty {
            arguments.append(contentsOf: ["--detach-keys", detachKeys])
            diagnostics.append(.init(
                severity: .warning,
                path: "attach.detach_keys",
                message: "Docker Compose --detach-keys is preserved for attach intent, but Apple Container detach-key behavior is unverified."
            ))
        }

        let replicaIndex = max(options.replicaIndex, 1)
        if options.replicaIndex < 1 {
            diagnostics.append(.init(
                severity: .warning,
                path: "attach.index",
                message: "Replica index must be at least 1; using index 1 for Apple Container command planning."
            ))
        }

        if service.containerName != nil, replicaIndex != 1 {
            diagnostics.append(.init(
                severity: .warning,
                path: "attach.index",
                message: "Replica index is ignored for services that declare container_name."
            ))
        } else if replicaIndex != 1 {
            arguments.append(contentsOf: ["--index", String(replicaIndex)])
        }

        if !options.attachStdin {
            arguments.append("--no-stdin")
        }

        if !options.signalProxy {
            arguments.append("--sig-proxy=false")
            diagnostics.append(.init(
                severity: .warning,
                path: "attach.sig_proxy",
                message: "Docker Compose --sig-proxy=false is preserved for attach intent, but Apple Container signal proxy behavior is unverified."
            ))
        }

        arguments.append(containerName(project: project.name, service: service, replicaIndex: replicaIndex))
        return [
            PlannedCommand(
                action: .attachService,
                service: service.name,
                arguments: arguments,
                diagnostics: diagnostics
            )
        ]
    }

    public func planWait(
        project: ComposeProject,
        services selectedServices: [String] = [],
        options: AppleContainerWaitOptions = .init()
    ) -> [PlannedCommand] {
        selectedOrderedServices(project.services, selectedServices: selectedServices).map { service in
            var arguments = ["wait"]
            var diagnostics: [ComposeDiagnostic] = [
                .init(
                    severity: .warning,
                    path: "wait",
                    message: "Docker Compose wait blocks until service containers stop, but Apple Container wait support is unavailable or unverified; this planned action is not executable yet."
                )
            ]

            if options.downProject {
                arguments.append("--down-project")
                diagnostics.append(.init(
                    severity: .warning,
                    path: "wait.down_project",
                    message: "Docker Compose --down-project removes the project after the first container stops, but Container Compose only preserves this wait intent until runtime behavior is verified."
                ))
            }

            arguments.append(containerName(project: project.name, service: service))
            return PlannedCommand(
                action: .waitService,
                service: service.name,
                arguments: arguments,
                diagnostics: diagnostics
            )
        }
    }

    public func planScale(
        project: ComposeProject,
        targets: [String: Int],
        services selectedServices: [String] = [],
        options: AppleContainerScaleOptions = .init()
    ) -> [PlannedCommand] {
        guard !targets.isEmpty else {
            return [
                PlannedCommand(
                    action: .scaleService,
                    arguments: ["scale"],
                    diagnostics: [
                        .init(
                            severity: .error,
                            path: "scale",
                            message: "Scale planning requires at least one SERVICE=REPLICAS assignment."
                        )
                    ]
                )
            ]
        }

        let selected = selectedServices.isEmpty ? Array(targets.keys) : selectedServices
        return selectedOrderedServices(project.services, selectedServices: selected).compactMap { service in
            guard let replicas = targets[service.name] else { return nil }

            var arguments = ["scale"]
            var diagnostics: [ComposeDiagnostic] = [
                .init(
                    severity: .warning,
                    path: "scale",
                    message: "Docker Compose scale changes service replica counts, but Apple Container replica orchestration is unavailable or unverified; this planned action is not executable yet."
                )
            ]

            if options.noDependencies {
                arguments.append("--no-deps")
                diagnostics.append(.init(
                    severity: .warning,
                    path: "scale.no_deps",
                    message: "Docker Compose --no-deps is preserved for scale intent, but Container Compose does not start linked services while scale support is diagnostic-only."
                ))
            }

            if service.containerName != nil, replicas > 1 {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "services.\(service.name).container_name",
                    message: "Services that declare container_name cannot be safely scaled beyond one replica because replica containers would need unique names."
                ))
            }

            arguments.append("\(service.name)=\(replicas)")
            return PlannedCommand(
                action: .scaleService,
                service: service.name,
                arguments: arguments,
                diagnostics: diagnostics
            )
        }
    }

    public func planCommit(
        project: ComposeProject,
        service serviceName: String?,
        options: AppleContainerCommitOptions = .init()
    ) -> [PlannedCommand] {
        guard let serviceName, !serviceName.isEmpty else {
            return [
                PlannedCommand(
                    action: .commitService,
                    arguments: ["commit"],
                    diagnostics: [
                        .init(
                            severity: .error,
                            path: "commit.service",
                            message: "Commit planning requires a service name."
                        )
                    ]
                )
            ]
        }

        guard let service = selectedOrderedServices(project.services, selectedServices: [serviceName]).first else {
            return []
        }

        var arguments = ["commit"]
        var diagnostics: [ComposeDiagnostic] = [
            .init(
                severity: .warning,
                path: "commit",
                message: "Docker Compose commit creates an image from a service container, but Apple Container commit support is unavailable or unverified; this planned action is not executable yet."
            )
        ]

        if let author = options.author, !author.isEmpty {
            arguments.append(contentsOf: ["--author", author])
        }

        for change in options.changes where !change.isEmpty {
            arguments.append(contentsOf: ["--change", change])
            diagnostics.append(.init(
                severity: .warning,
                path: "commit.change",
                message: "Docker Compose --change applies Dockerfile instructions during commit; Container Compose preserves the intent until image commit behavior is verified."
            ))
        }

        if let message = options.message, !message.isEmpty {
            arguments.append(contentsOf: ["--message", message])
        }

        let replicaIndex = max(options.replicaIndex, 1)
        if options.replicaIndex < 1 {
            diagnostics.append(.init(
                severity: .warning,
                path: "commit.index",
                message: "Replica index must be at least 1; using index 1 for Apple Container command planning."
            ))
        }

        if service.containerName != nil, replicaIndex != 1 {
            diagnostics.append(.init(
                severity: .warning,
                path: "commit.index",
                message: "Replica index is ignored for services that declare container_name."
            ))
        } else if replicaIndex != 1 {
            arguments.append(contentsOf: ["--index", String(replicaIndex)])
        }

        if !options.pause {
            arguments.append("--pause=false")
            diagnostics.append(.init(
                severity: .warning,
                path: "commit.pause",
                message: "Docker Compose --pause=false is preserved for commit intent, but Apple Container pause-during-commit behavior is unverified."
            ))
        }

        arguments.append(containerName(project: project.name, service: service, replicaIndex: replicaIndex))
        if let repository = options.repository, !repository.isEmpty {
            arguments.append(repository)
        }

        return [
            PlannedCommand(
                action: .commitService,
                service: service.name,
                arguments: arguments,
                diagnostics: diagnostics
            )
        ]
    }

    public func planEvents(
        project: ComposeProject,
        services selectedServices: [String] = [],
        options: AppleContainerEventsOptions = .init()
    ) -> [PlannedCommand] {
        var arguments = ["events"]
        var diagnostics: [ComposeDiagnostic] = [
            .init(
                severity: .warning,
                path: "events",
                message: "Docker Compose events streams project container events, but Apple Container project-scoped event streaming is unavailable or unverified; this planned action is not executable yet."
            )
        ]

        if options.outputJSON {
            arguments.append("--json")
            diagnostics.append(.init(
                severity: .warning,
                path: "events.json",
                message: "Docker Compose --json changes event stream formatting; Container Compose preserves this event-output intent instead of treating it as an execution-report format flag."
            ))
        }

        if let since = options.since, !since.isEmpty {
            arguments.append(contentsOf: ["--since", since])
            diagnostics.append(.init(
                severity: .warning,
                path: "events.since",
                message: "Docker Compose --since filters event history; Container Compose preserves the filter until Apple Container event history behavior is verified."
            ))
        }

        if let until = options.until, !until.isEmpty {
            arguments.append(contentsOf: ["--until", until])
            diagnostics.append(.init(
                severity: .warning,
                path: "events.until",
                message: "Docker Compose --until stops event streaming at a timestamp; Container Compose preserves the filter until Apple Container event stream behavior is verified."
            ))
        }

        let services = selectedOrderedServices(project.services, selectedServices: selectedServices)
        arguments.append(contentsOf: services.map(\.name))

        return [
            PlannedCommand(
                action: .eventsProject,
                arguments: arguments,
                diagnostics: diagnostics
            )
        ]
    }

    public func planRemove(
        project: ComposeProject,
        services selectedServices: [String] = [],
        stop: Bool = false,
        removeVolumes: Bool = false
    ) -> [PlannedCommand] {
        selectedOrderedServices(project.services, selectedServices: selectedServices)
            .reversed()
            .flatMap { service in
                var commands: [PlannedCommand] = []
                if stop {
                    commands.append(stopCommand(project: project, service: service))
                }

                var diagnostics: [ComposeDiagnostic] = []
                if removeVolumes {
                    diagnostics.append(.init(
                        severity: .warning,
                        path: "rm.volumes",
                        message: "Docker Compose --volumes removes anonymous volumes, but Apple Container delete does not expose anonymous volume removal."
                    ))
                }

                commands.append(.init(
                    action: .deleteService,
                    service: service.name,
                    arguments: ["delete", containerName(project: project.name, service: service)],
                    diagnostics: diagnostics
                ))
                return commands
            }
    }

    public func planCopy(
        project: ComposeProject,
        source: String?,
        destination: String?,
        options: AppleContainerCopyOptions = .init()
    ) -> [PlannedCommand] {
        var diagnostics: [ComposeDiagnostic] = []

        guard let source, !source.isEmpty else {
            return [
                PlannedCommand(
                    action: .copyService,
                    arguments: ["copy", destination ?? ""].filter { !$0.isEmpty },
                    diagnostics: [
                        .init(
                            severity: .error,
                            path: "cp.source",
                            message: "Copy planning requires a source path."
                        )
                    ]
                )
            ]
        }

        guard let destination, !destination.isEmpty else {
            return [
                PlannedCommand(
                    action: .copyService,
                    arguments: ["copy", source],
                    diagnostics: [
                        .init(
                            severity: .error,
                            path: "cp.destination",
                            message: "Copy planning requires a destination path."
                        )
                    ]
                )
            ]
        }

        let replicaIndex = max(options.replicaIndex, 1)
        if options.replicaIndex < 1 {
            diagnostics.append(.init(
                severity: .warning,
                path: "cp.index",
                message: "Replica index must be at least 1; using index 1 for Apple Container command planning."
            ))
        }

        if options.archive {
            diagnostics.append(.init(
                severity: .warning,
                path: "cp.archive",
                message: "Docker Compose --archive is not mapped because Apple Container copy does not expose an archive mode option."
            ))
        }

        if options.followLink {
            diagnostics.append(.init(
                severity: .warning,
                path: "cp.follow_link",
                message: "Docker Compose --follow-link is not mapped because Apple Container copy does not expose a symlink-following option."
            ))
        }

        if options.includeRunContainers {
            diagnostics.append(.init(
                severity: .warning,
                path: "cp.all",
                message: "Docker Compose --all includes one-off run containers, which are not mapped to Apple Container copy planning yet."
            ))
        }

        let sourceEndpoint = copyEndpoint(source, project: project, replicaIndex: replicaIndex)
        let destinationEndpoint = copyEndpoint(destination, project: project, replicaIndex: replicaIndex)
        diagnostics.append(contentsOf: sourceEndpoint.diagnostics)
        diagnostics.append(contentsOf: destinationEndpoint.diagnostics)

        let matchedServices = [sourceEndpoint.service, destinationEndpoint.service].compactMap { $0 }
        if matchedServices.isEmpty {
            diagnostics.append(.init(
                severity: .error,
                path: "cp",
                message: "Copy planning requires either source or destination to use SERVICE:PATH syntax."
            ))
        } else if matchedServices.count > 1 {
            diagnostics.append(.init(
                severity: .error,
                path: "cp",
                message: "Copy planning requires exactly one service endpoint; copying directly between service containers is not supported."
            ))
        }

        return [
            PlannedCommand(
                action: .copyService,
                service: matchedServices.first?.name,
                arguments: ["copy", sourceEndpoint.value, destinationEndpoint.value],
                diagnostics: diagnostics
            )
        ]
    }

    public func planExec(
        project: ComposeProject,
        service serviceName: String?,
        command: [String],
        options: AppleContainerExecOptions = .init()
    ) -> [PlannedCommand] {
        guard let serviceName, !serviceName.isEmpty else {
            return [
                PlannedCommand(
                    action: .execService,
                    arguments: ["exec"] + command,
                    diagnostics: [
                        .init(
                            severity: .error,
                            path: "exec.service",
                            message: "Exec planning requires a service name."
                        )
                    ]
                )
            ]
        }

        guard let service = selectedOrderedServices(project.services, selectedServices: [serviceName]).first else {
            return []
        }

        var arguments = ["exec"]
        var diagnostics: [ComposeDiagnostic] = []

        if options.detach {
            arguments.append("--detach")
        }

        for value in options.environment {
            arguments.append(contentsOf: ["--env", value])
        }

        for envFile in options.envFiles {
            arguments.append(contentsOf: ["--env-file", envFile])
        }

        if options.interactive {
            arguments.append("--interactive")
        }

        if options.tty {
            arguments.append("--tty")
        }

        if let user = options.user, !user.isEmpty {
            arguments.append(contentsOf: ["--user", user])
        }

        if let workdir = options.workdir, !workdir.isEmpty {
            arguments.append(contentsOf: ["--workdir", workdir])
        }

        if options.privileged {
            diagnostics.append(.init(
                severity: .warning,
                path: "exec.privileged",
                message: "Docker Compose --privileged is not mapped because Apple Container exec does not expose an equivalent option."
            ))
        }

        let replicaIndex = max(options.replicaIndex, 1)
        if options.replicaIndex < 1 {
            diagnostics.append(.init(
                severity: .warning,
                path: "exec.index",
                message: "Replica index must be at least 1; using index 1 for Apple Container command planning."
            ))
        }

        if service.containerName != nil, replicaIndex != 1 {
            diagnostics.append(.init(
                severity: .warning,
                path: "exec.index",
                message: "Replica index is ignored for services that declare container_name."
            ))
        }

        if command.isEmpty {
            diagnostics.append(.init(
                severity: .error,
                path: "exec.command",
                message: "Exec planning requires a command to run in the service container."
            ))
        }

        arguments.append(containerName(project: project.name, service: service, replicaIndex: replicaIndex))
        arguments.append(contentsOf: command)
        return [
            PlannedCommand(
                action: .execService,
                service: service.name,
                arguments: arguments,
                diagnostics: diagnostics
            )
        ]
    }

    public func planLogs(
        project: ComposeProject,
        services selectedServices: [String] = [],
        follow: Bool = false,
        tail: Int? = nil
    ) -> [PlannedCommand] {
        selectedOrderedServices(project.services, selectedServices: selectedServices).map { service in
            var arguments = ["logs"]
            if follow {
                arguments.append("--follow")
            }
            if let tail {
                arguments.append(contentsOf: ["-n", String(tail)])
            }
            arguments.append(containerName(project: project.name, service: service))
            return PlannedCommand(action: .logsService, service: service.name, arguments: arguments)
        }
    }

    public func planPs(
        project: ComposeProject,
        services selectedServices: [String] = [],
        all: Bool = true
    ) -> [PlannedCommand] {
        var arguments = ["list"]
        if all {
            arguments.append("--all")
        }
        var diagnostics: [ComposeDiagnostic] = [
            .init(
                severity: .warning,
                path: "ps",
                message: "Apple Container does not expose project label filtering here yet; this lists containers from the local runtime."
            )
        ]
        if !selectedServices.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "ps.services",
                message: "Apple Container does not expose service filtering for container list yet; selected services are preserved as plan metadata only."
            ))
        }
        return [
            PlannedCommand(
                action: .listServices,
                arguments: arguments,
                diagnostics: diagnostics
            )
        ]
    }

    public func planStats(
        project: ComposeProject,
        services selectedServices: [String] = [],
        noStream: Bool = false
    ) -> [PlannedCommand] {
        var arguments = ["stats"]
        if noStream {
            arguments.append("--no-stream")
        }
        let names = selectedOrderedServices(project.services, selectedServices: selectedServices)
            .map { containerName(project: project.name, service: $0) }
        arguments.append(contentsOf: names)
        return [
            PlannedCommand(
                action: .statsService,
                arguments: arguments
            )
        ]
    }

    public func planTop(
        project: ComposeProject,
        services selectedServices: [String] = []
    ) -> [PlannedCommand] {
        selectedOrderedServices(project.services, selectedServices: selectedServices).map { service in
            PlannedCommand(
                action: .topService,
                service: service.name,
                arguments: ["exec", containerName(project: project.name, service: service), "ps"],
                diagnostics: [
                    .init(
                        severity: .warning,
                        path: "top",
                        message: "Docker Compose top displays Docker engine process information; Apple Container mapping executes ps inside each selected service container."
                    )
                ]
            )
        }
    }

    private func stopCommand(project: ComposeProject, service: ComposeService) -> PlannedCommand {
        var arguments = ["stop"]
        var diagnostics: [ComposeDiagnostic] = []
        if let signal = service.stopSignal {
            arguments.append(contentsOf: ["--signal", signal])
        }
        if let gracePeriod = service.stopGracePeriod {
            if let seconds = stopGracePeriodSeconds(gracePeriod) {
                arguments.append(contentsOf: ["--time", seconds])
            } else {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "services.\(service.name).stop_grace_period",
                    message: "stop_grace_period '\(gracePeriod)' could not be converted to whole seconds for Apple Container."
                ))
            }
        }
        arguments.append(containerName(project: project.name, service: service))
        return PlannedCommand(
            action: .stopService,
            service: service.name,
            arguments: arguments,
            diagnostics: diagnostics
        )
    }

    private func stopGracePeriodSeconds(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let seconds = Double(value), seconds >= 0, seconds.isFinite {
            return String(Int(seconds.rounded(.up)))
        }

        let pattern = #"([0-9]+(?:\.[0-9]+)?)(us|ms|s|m|h)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: fullRange)
        guard !matches.isEmpty else { return nil }

        var expectedLocation = fullRange.location
        var totalSeconds = 0.0
        for match in matches {
            guard match.range.location == expectedLocation,
                  let amountRange = Range(match.range(at: 1), in: value),
                  let unitRange = Range(match.range(at: 2), in: value),
                  let amount = Double(value[amountRange]),
                  amount >= 0,
                  amount.isFinite else {
                return nil
            }
            switch String(value[unitRange]) {
            case "us":
                totalSeconds += amount / 1_000_000
            case "ms":
                totalSeconds += amount / 1_000
            case "s":
                totalSeconds += amount
            case "m":
                totalSeconds += amount * 60
            case "h":
                totalSeconds += amount * 3_600
            default:
                return nil
            }
            expectedLocation = match.range.location + match.range.length
        }

        guard expectedLocation == fullRange.location + fullRange.length,
              totalSeconds.isFinite else {
            return nil
        }
        return String(Int(totalSeconds.rounded(.up)))
    }

    private func policyPullCommand(project _: ComposeProject, service: ComposeService) -> PlannedCommand? {
        guard pullPolicyKind(for: service) == .always else {
            return nil
        }
        return imagePullCommand(for: service)
    }

    private func imagePullCommand(for service: ComposeService) -> PlannedCommand? {
        guard let image = service.image else { return nil }
        var arguments = ["image", "pull"]
        if let platform = service.platform {
            arguments.append(contentsOf: ["--platform", platform])
        }
        arguments.append(image)
        return .init(action: .pullImage, service: service.name, arguments: arguments)
    }

    private func imagePushCommand(for service: ComposeService, options: AppleContainerPushOptions) -> PlannedCommand? {
        guard let image = service.image else { return nil }
        var arguments = ["image", "push"]
        var diagnostics: [ComposeDiagnostic] = []
        if options.quiet {
            arguments.append(contentsOf: ["--progress", "none"])
        }
        if let platform = service.platform {
            arguments.append(contentsOf: ["--platform", platform])
        }
        if options.ignorePushFailures {
            diagnostics.append(.init(
                severity: .warning,
                path: "push.ignore_push_failures",
                message: "Docker Compose --ignore-push-failures is not fully mapped because the current execution runner stops on the first failed command."
            ))
        }
        arguments.append(image)
        return .init(action: .pushImage, service: service.name, arguments: arguments, diagnostics: diagnostics)
    }

    private func shouldPlanBuild(for service: ComposeService) -> Bool {
        guard service.build != nil else { return false }
        switch pullPolicyKind(for: service) {
        case .always, .never, .missing, .timed:
            return false
        case .build, .unknown, .unspecified:
            return true
        }
    }

    private func buildCommand(project: ComposeProject, service: ComposeService) -> PlannedCommand {
        guard let build = service.build else {
            return .init(action: .buildService, service: service.name, arguments: ["build"])
        }

        var arguments = ["build"]
        var diagnostics: [ComposeDiagnostic] = []
        var generatedFiles: [PlannedGeneratedFile] = []

        for tag in buildTags(project: project.name, service: service) {
            arguments.append(contentsOf: ["--tag", tag])
        }

        if let dockerfile = build.dockerfile {
            arguments.append(contentsOf: ["--file", resolveBuildPath(dockerfile, sourcePath: project.sourcePath, context: build.context)])
        } else if let dockerfileInline = build.dockerfileInline {
            let path = inlineDockerfilePathResolver.path(
                projectName: project.name,
                serviceName: service.name,
                sourcePath: project.sourcePath,
                buildContext: build.context,
                contents: dockerfileInline
            )
            arguments.append(contentsOf: ["--file", path])
            generatedFiles.append(.init(
                kind: .inlineDockerfile,
                path: path,
                contents: dockerfileInline,
                diagnosticsPath: "services.\(service.name).build.dockerfile_inline"
            ))
        }

        for arg in build.args {
            arguments.append(contentsOf: ["--build-arg", arg])
        }

        for label in build.labels {
            arguments.append(contentsOf: ["--label", label])
        }

        appendUnsupportedBuildDiagnostics(build: build, serviceName: service.name, diagnostics: &diagnostics)

        appendBuildSecrets(
            build.secrets,
            resources: project.secrets,
            serviceName: service.name,
            sourcePath: project.sourcePath,
            arguments: &arguments,
            diagnostics: &diagnostics
        )

        if let target = build.target {
            arguments.append(contentsOf: ["--target", target])
        }

        if build.noCache {
            arguments.append("--no-cache")
        }

        if build.pull {
            arguments.append("--pull")
        }

        let platforms = build.platforms.isEmpty ? service.platform.map { [$0] } ?? [] : build.platforms
        for platform in platforms {
            arguments.append(contentsOf: ["--platform", platform])
        }

        if build.context.hasPrefix("/") {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).build.context",
                message: "Absolute build contexts reduce Compose file portability."
            ))
        }
        arguments.append(resolveBuildContext(build.context, sourcePath: project.sourcePath))

        return .init(
            action: .buildService,
            service: service.name,
            arguments: arguments,
            diagnostics: diagnostics,
            generatedFiles: generatedFiles
        )
    }

    private func planRun(
        project: ComposeProject,
        service: ComposeService,
        detach: Bool,
        runOptions: AppleContainerRunOptions,
        oneOff: Bool = true,
        verb: String = "run",
        action: PlanAction = .runService
    ) -> PlannedCommand {
        var diagnostics: [ComposeDiagnostic] = []
        var arguments = [verb]
        let projectName = project.name

        appendPullPolicyDiagnostics(service: service, diagnostics: &diagnostics)
        appendHealthcheckDiagnostics(project: project, service: service, diagnostics: &diagnostics)
        appendUnsupportedServiceRunDiagnostics(service: service, diagnostics: &diagnostics)

        if let provider = service.provider {
            diagnostics.append(.init(
                severity: .error,
                path: "services.\(service.name).provider",
                message: "Service provider '\(provider.type)' is preserved but delegated provider lifecycle is not executable through Apple Container yet."
            ))
            return .init(
                action: .delegateService,
                service: service.name,
                arguments: ["compose-provider", verb, service.name, provider.type],
                diagnostics: diagnostics
            )
        }

        guard let image = runtimeImage(project: projectName, service: service) else {
            diagnostics.append(.init(
                severity: .error,
                path: "services.\(service.name).image",
                message: "Apple Container \(verb) planning requires an image or build section."
            ))
            return .init(action: action, service: service.name, arguments: arguments, diagnostics: diagnostics)
        }

        let plannedName = oneOff
            ? runOptions.name ?? "\(sanitize(projectName))_\(sanitize(service.name))_run_1"
            : containerName(project: projectName, service: service)
        arguments.append(contentsOf: ["--name", plannedName])

        if detach {
            arguments.append("--detach")
        }

        if runOptions.remove {
            arguments.append("--rm")
        }

        if service.initProcess {
            arguments.append("--init")
        }

        if runOptions.interactive {
            arguments.append("--interactive")
        }

        if runOptions.tty {
            arguments.append("--tty")
        }

        for label in service.labels {
            arguments.append(contentsOf: ["--label", label])
        }

        if let entrypoint = runOptions.entrypoint ?? service.entrypoint {
            arguments.append(contentsOf: ["--entrypoint", entrypoint])
        }

        for item in service.environment.sorted(by: { $0.key < $1.key }) {
            arguments.append(contentsOf: ["--env", "\(item.key)=\(item.value)"])
        }
        for item in runOptions.environment {
            arguments.append(contentsOf: ["--env", item])
        }

        for envFile in serviceEnvFilesForRun(service: service, project: project, diagnostics: &diagnostics) {
            arguments.append(contentsOf: ["--env-file", envFile])
        }
        for envFile in runOptions.envFiles {
            arguments.append(contentsOf: ["--env-file", envFile])
        }

        if runOptions.servicePorts {
            for port in service.ports {
                arguments.append(contentsOf: ["--publish", port])
            }
        }
        for port in runOptions.publish {
            arguments.append(contentsOf: ["--publish", port])
        }

        for volume in service.volumes {
            arguments.append(contentsOf: ["--volume", normalizeVolume(volume, projectName: projectName, volumes: project.volumes)])
        }

        appendResourceMounts(
            service.configs,
            resources: project.configs,
            kind: "configs",
            serviceName: service.name,
            sourcePath: project.sourcePath,
            arguments: &arguments,
            diagnostics: &diagnostics
        )

        appendResourceMounts(
            service.secrets,
            resources: project.secrets,
            kind: "secrets",
            serviceName: service.name,
            sourcePath: project.sourcePath,
            arguments: &arguments,
            diagnostics: &diagnostics
        )

        for network in service.networks {
            let networkName = project.networks[network].map {
                networkResourceName(project: projectName, network: $0)
            } ?? resourceName(project: projectName, resource: network)
            arguments.append(contentsOf: ["--network", networkName])
            if project.networks[network]?.hasUnmappedOptions == true {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "networks.\(network)",
                    message: "Network definition options are preserved but not fully mapped to Apple Container network arguments yet."
                ))
            }
        }
        for attachment in service.networkAttachments where attachment.hasOptions {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).networks.\(attachment.name)",
                message: "Service network attachment options are preserved but not mapped to Apple Container network arguments yet."
            ))
        }

        if let workingDirectory = runOptions.workdir ?? service.workingDirectory {
            arguments.append(contentsOf: ["--workdir", workingDirectory])
        }

        if let user = runOptions.user ?? service.user {
            arguments.append(contentsOf: ["--user", user])
        }

        if let platform = service.platform {
            arguments.append(contentsOf: ["--platform", platform])
        }

        if let cpus = service.cpus {
            arguments.append(contentsOf: ["--cpus", cpus])
        }

        if let memory = service.memory {
            arguments.append(contentsOf: ["--memory", memory])
        }

        if service.readOnly {
            arguments.append("--read-only")
        }

        for capability in service.capAdd {
            arguments.append(contentsOf: ["--cap-add", capability])
        }

        for capability in service.capDrop {
            arguments.append(contentsOf: ["--cap-drop", capability])
        }

        for server in service.dns {
            arguments.append(contentsOf: ["--dns", server])
        }

        for searchDomain in service.dnsSearch {
            arguments.append(contentsOf: ["--dns-search", searchDomain])
        }

        for option in service.dnsOptions {
            arguments.append(contentsOf: ["--dns-option", option])
        }

        if let shmSize = service.shmSize {
            arguments.append(contentsOf: ["--shm-size", shmSize])
        }

        for mount in service.tmpfs {
            arguments.append(contentsOf: ["--tmpfs", mount])
        }

        for ulimit in service.ulimits {
            arguments.append(contentsOf: ["--ulimit", ulimit])
        }

        if let restart = service.restart, restart != "no" {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).restart",
                message: "Restart policy '\(restart)' is not mapped to Apple Container yet."
            ))
        }

        arguments.append(image)
        arguments.append(contentsOf: runOptions.command.isEmpty ? service.command : runOptions.command)
        return .init(action: action, service: service.name, arguments: arguments, diagnostics: diagnostics)
    }

    private func appendHealthcheckDiagnostics(
        project: ComposeProject,
        service: ComposeService,
        diagnostics: inout [ComposeDiagnostic]
    ) {
        if let healthcheck = service.healthcheck, !healthcheck.disabled {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).healthcheck",
                message: "Healthcheck is preserved in the Compose model but is not mapped to Apple Container run arguments yet."
            ))
        }

        let servicesByName = Dictionary(uniqueKeysWithValues: project.services.map { ($0.name, $0) })
        for dependency in service.dependsOn.sorted() {
            let metadata = service.dependsOnMetadata[dependency] ?? ComposeServiceDependencyMetadata()
            guard metadata.condition == .serviceHealthy else { continue }
            let dependencyHealthcheck = servicesByName[dependency]?.healthcheck
            if dependencyHealthcheck == nil || dependencyHealthcheck?.disabled == true {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "services.\(service.name).depends_on.\(dependency).condition",
                    message: "service_healthy depends on '\(dependency)', but that service has no enabled healthcheck in the active Compose model."
                ))
            }
        }
    }

    private enum PullPolicyKind: Equatable {
        case always
        case never
        case missing
        case build
        case timed
        case unknown(String)
        case unspecified
    }

    private func pullPolicyKind(for service: ComposeService) -> PullPolicyKind {
        guard let policy = service.pullPolicy?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !policy.isEmpty else {
            return .unspecified
        }
        switch policy {
        case "always":
            return .always
        case "never":
            return .never
        case "missing", "if_not_present":
            return .missing
        case "build":
            return .build
        case "daily", "weekly":
            return .timed
        default:
            if policy.hasPrefix("every_") {
                return .timed
            }
            return .unknown(policy)
        }
    }

    private func appendUnsupportedServiceRunDiagnostics(
        service: ComposeService,
        diagnostics: inout [ComposeDiagnostic]
    ) {
        if !service.extraHosts.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).extra_hosts",
                message: "Service extra_hosts entries are preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if !service.exposedPorts.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).expose",
                message: "Service expose entries are internal-only Compose ports and are preserved without publishing host ports."
            ))
        }
        if service.privileged == true {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).privileged",
                message: "Service privileged mode is preserved but not mapped because Apple Container run support is unavailable or unverified."
            ))
        }
        if service.hostname != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).hostname",
                message: "Service hostname is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.domainName != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).domainname",
                message: "Service domainname is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.networkMode != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).network_mode",
                message: "Service network_mode is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.macAddress != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).mac_address",
                message: "Service mac_address is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.pidMode != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).pid",
                message: "Service pid mode is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.ipcMode != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).ipc",
                message: "Service ipc mode is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.utsMode != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).uts",
                message: "Service uts mode is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.usernsMode != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).userns_mode",
                message: "Service userns_mode is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.isolation != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).isolation",
                message: "Service isolation is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.cgroupMode != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).cgroup",
                message: "Service cgroup mode is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.cgroupParent != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).cgroup_parent",
                message: "Service cgroup_parent is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if !service.deviceCgroupRules.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).device_cgroup_rules",
                message: "Service device_cgroup_rules entries are preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if !service.devices.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).devices",
                message: "Service devices entries are preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.gpus != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).gpus",
                message: "Service gpus request is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if !service.groupAdd.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).group_add",
                message: "Service group_add entries are preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if !service.sysctls.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).sysctls",
                message: "Service sysctls entries are preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.oomKillDisable != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).oom_kill_disable",
                message: "Service oom_kill_disable is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.oomScoreAdjustment != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).oom_score_adj",
                message: "Service oom_score_adj is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.pidsLimit != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).pids_limit",
                message: "Service pids_limit is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.logging != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).logging",
                message: "Service logging config is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.runtime != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).runtime",
                message: "Service runtime is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.scale != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).scale",
                message: "Service scale is preserved but not mapped to Apple Container replica planning yet."
            ))
        }
        if !service.storageOptions.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).storage_opt",
                message: "Service storage_opt entries are preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.useAPISocket == true {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).use_api_socket",
                message: "Service use_api_socket is preserved but not mapped to Apple Container engine socket behavior yet."
            ))
        }
        if service.credentialSpec != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).credential_spec",
                message: "Service credential_spec is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if !service.volumesFrom.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).volumes_from",
                message: "Service volumes_from entries are preserved and service references are applied as startup dependencies, but volume inheritance is not mapped to Apple Container run arguments yet."
            ))
        }
        if !service.modelGrants.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).models",
                message: "Service models grants are preserved but not mapped to Apple Container model-runner environment yet."
            ))
        }
        if service.develop != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).develop",
                message: "Service develop watch rules are preserved but not mapped to Apple Container file sync, rebuild, restart, or exec workflows yet."
            ))
        }
        if service.deploy != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).deploy",
                message: "Service deploy metadata is preserved but not mapped to Apple Container orchestration, placement, resource reservation, or rolling update behavior yet."
            ))
        }
        if !service.postStartHooks.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).post_start",
                message: "Service post_start hooks are preserved but not mapped to Apple Container lifecycle execution yet."
            ))
        }
        if !service.preStartHooks.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).pre_start",
                message: "Service pre_start hooks are preserved but not mapped to Apple Container lifecycle execution yet."
            ))
        }
        if !service.preStopHooks.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).pre_stop",
                message: "Service pre_stop hooks are preserved but not mapped to Apple Container lifecycle execution yet."
            ))
        }
        if !service.links.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).links",
                message: "Service links are preserved and applied as startup dependencies, but link aliases are not mapped to Apple Container run arguments yet."
            ))
        }
        if !service.externalLinks.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).external_links",
                message: "Service external_links entries are preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if !service.annotations.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).annotations",
                message: "Service annotations are preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.attach == false {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).attach",
                message: "Service attach=false is preserved but not mapped to Apple Container log collection behavior yet."
            ))
        }
        if service.blockIOConfig != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).blkio_config",
                message: "Service blkio_config is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.cpuCount != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).cpu_count",
                message: "Service cpu_count is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.cpuPercent != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).cpu_percent",
                message: "Service cpu_percent is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.cpuShares != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).cpu_shares",
                message: "Service cpu_shares is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.cpuPeriod != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).cpu_period",
                message: "Service cpu_period is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.cpuQuota != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).cpu_quota",
                message: "Service cpu_quota is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.cpuRTRuntime != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).cpu_rt_runtime",
                message: "Service cpu_rt_runtime is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.cpuRTPeriod != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).cpu_rt_period",
                message: "Service cpu_rt_period is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.cpuSet != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).cpuset",
                message: "Service cpuset is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.memoryReservation != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).mem_reservation",
                message: "Service mem_reservation is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if service.memorySwappiness != nil {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).mem_swappiness",
                message: "Service mem_swappiness is preserved but not mapped to Apple Container run arguments yet."
            ))
        }
        if !service.securityOptions.isEmpty {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).security_opt",
                message: "Service security_opt entries are preserved but not mapped to Apple Container run arguments yet."
            ))
        }
    }

    private func appendPullPolicyDiagnostics(service: ComposeService, diagnostics: inout [ComposeDiagnostic]) {
        let kind = pullPolicyKind(for: service)
        if case let .unknown(policy) = kind {
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).pull_policy",
                message: "Pull policy '\(policy)' is not recognized by the Compose specification."
            ))
        }

        guard service.image != nil, service.build != nil else { return }

        switch kind {
        case .unspecified:
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).pull_policy",
                message: "Compose pulls the image first and builds only as fallback when pull_policy is omitted; Container Compose plans the build directly."
            ))
        case .missing, .timed:
            diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service.name).pull_policy",
                message: "Cache-aware pull_policy handling for services with both image and build is preserved in config but is not fully represented in the static Apple Container plan yet."
            ))
        case .always, .never, .build, .unknown:
            break
        }
    }

    private func serviceEnvFilesForRun(
        service: ComposeService,
        project: ComposeProject,
        diagnostics: inout [ComposeDiagnostic]
    ) -> [String] {
        guard !service.envFileEntries.isEmpty else {
            return service.envFiles
        }

        return service.envFileEntries.compactMap { entry in
            if entry.required == false, !envFileExists(entry.path, sourcePath: project.sourcePath) {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "services.\(service.name).env_file",
                    message: "Optional env_file does not exist and was skipped: \(entry.path)"
                ))
                return nil
            }
            if let format = entry.format, !format.isEmpty {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "services.\(service.name).env_file",
                    message: "env_file format '\(format)' is preserved but not mapped to Apple Container env-file parsing yet."
                ))
            }
            return entry.path
        }
    }

    private func envFileExists(_ path: String, sourcePath: String) -> Bool {
        if isRemotePath(path) {
            return true
        }
        if path.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: path)
        }
        let base = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path)
    }

    private func isRemotePath(_ path: String) -> Bool {
        guard let url = URL(string: path), let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private func appendUnsupportedBuildDiagnostics(
        build: ComposeBuild,
        serviceName: String,
        diagnostics: inout [ComposeDiagnostic]
    ) {
        if !build.additionalContexts.isEmpty {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "additional_contexts",
                message: "Build additional_contexts are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if build.dockerfile != nil, build.dockerfileInline != nil {
            diagnostics.append(.init(
                severity: .error,
                path: "services.\(serviceName).build",
                message: "Compose build cannot set both dockerfile and dockerfile_inline."
            ))
        }
        if !build.cacheFrom.isEmpty {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "cache_from",
                message: "Build cache_from entries are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if !build.cacheTo.isEmpty {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "cache_to",
                message: "Build cache_to entries are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if !build.entitlements.isEmpty {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "entitlements",
                message: "Build entitlements are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if !build.extraHosts.isEmpty {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "extra_hosts",
                message: "Build extra_hosts entries are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if build.isolation != nil {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "isolation",
                message: "Build isolation settings are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if build.network != nil {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "network",
                message: "Build network settings are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if build.privileged != nil {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "privileged",
                message: "Build privileged settings are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if build.shmSize != nil {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "shm_size",
                message: "Build shm_size settings are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if !build.ssh.isEmpty {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "ssh",
                message: "Build SSH mounts are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if build.provenance != nil {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "provenance",
                message: "Build provenance settings are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if build.sbom != nil {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "sbom",
                message: "Build SBOM settings are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
        if !build.ulimits.isEmpty {
            diagnostics.append(unsupportedBuildDiagnostic(
                serviceName: serviceName,
                field: "ulimits",
                message: "Build ulimits are preserved but not mapped to Apple Container build arguments yet."
            ))
        }
    }

    private func unsupportedBuildDiagnostic(
        serviceName: String,
        field: String,
        message: String
    ) -> ComposeDiagnostic {
        .init(severity: .warning, path: "services.\(serviceName).build.\(field)", message: message)
    }

    private func appendBuildSecrets(
        _ grants: [ComposeServiceResourceGrant],
        resources: [String: ComposeSecret],
        serviceName: String,
        sourcePath: String,
        arguments: inout [String],
        diagnostics: inout [ComposeDiagnostic]
    ) {
        for grant in grants {
            guard let secret = resources[grant.source] else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "services.\(serviceName).build.secrets.\(grant.source)",
                    message: "Build references undefined secret '\(grant.source)'."
                ))
                continue
            }

            if grant.uid != nil || grant.gid != nil || grant.mode != nil {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "services.\(serviceName).build.secrets.\(grant.source)",
                    message: "Build secret uid, gid, and mode are not mapped to Apple Container build secrets."
                ))
            }

            let id = buildSecretID(for: grant)
            if let file = secret.file, !secret.external {
                let hostPath = resolveHostPath(file, sourcePath: sourcePath)
                if !FileManager.default.fileExists(atPath: hostPath) {
                    diagnostics.append(.init(
                        severity: .warning,
                        path: "secrets.\(grant.source).file",
                        message: "Build secret file does not exist: \(hostPath)"
                    ))
                    continue
                }
                arguments.append(contentsOf: ["--secret", "id=\(id),src=\(hostPath)"])
                continue
            }

            if let environment = secret.environment, !secret.external {
                arguments.append(contentsOf: ["--secret", "id=\(id),env=\(environment)"])
                continue
            }

            diagnostics.append(.init(
                severity: .warning,
                path: "secrets.\(grant.source)",
                message: "Build secret '\(grant.source)' is not file-backed or environment-backed and cannot be mapped to Apple Container build secrets."
            ))
        }
    }

    private func buildSecretID(for grant: ComposeServiceResourceGrant) -> String {
        let prefix = "/run/secrets/"
        if grant.target.hasPrefix(prefix) {
            return String(grant.target.dropFirst(prefix.count))
        }
        if grant.target.hasPrefix("/") {
            return grant.source
        }
        return grant.target
    }

    private func appendResourceMounts<Resource>(
        _ grants: [ComposeServiceResourceGrant],
        resources: [String: Resource],
        kind: String,
        serviceName: String,
        sourcePath: String,
        arguments: inout [String],
        diagnostics: inout [ComposeDiagnostic]
    ) {
        for grant in grants {
            guard let resource = resources[grant.source] else {
                diagnostics.append(.init(
                    severity: .error,
                    path: "services.\(serviceName).\(kind).\(grant.source)",
                    message: "Service references undefined \(singularKind(kind)) '\(grant.source)'."
                ))
                continue
            }

            guard let file = fileBackedPath(from: resource) else {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "\(kind).\(grant.source)",
                    message: "\(singularKind(kind).capitalized) '\(grant.source)' is not file-backed and cannot be mapped to Apple Container yet."
                ))
                continue
            }

            let hostPath = resolveHostPath(file, sourcePath: sourcePath)
            if !FileManager.default.fileExists(atPath: hostPath) {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "\(kind).\(grant.source).file",
                    message: "\(singularKind(kind).capitalized) file does not exist: \(hostPath)"
                ))
                continue
            }

            if grant.uid != nil || grant.gid != nil || grant.mode != nil {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "services.\(serviceName).\(kind).\(grant.source)",
                    message: "\(singularKind(kind).capitalized) uid, gid, and mode are not mapped to Apple Container bind mounts."
                ))
            }

            arguments.append(contentsOf: ["--volume", "\(hostPath):\(grant.target):ro"])
        }
    }

    private func fileBackedPath<Resource>(from resource: Resource) -> String? {
        if let config = resource as? ComposeConfig, !config.external {
            return config.file
        }
        if let secret = resource as? ComposeSecret, !secret.external {
            return secret.file
        }
        return nil
    }

    private func resolveHostPath(_ path: String, sourcePath: String) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let sourceDirectory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
        return URL(fileURLWithPath: path, relativeTo: sourceDirectory).standardizedFileURL.path
    }

    private func resolveBuildContext(_ context: String, sourcePath: String) -> String {
        resolveHostPath(context, sourcePath: sourcePath)
    }

    private func resolveBuildPath(_ path: String, sourcePath: String, context: String) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let contextURL = URL(fileURLWithPath: resolveBuildContext(context, sourcePath: sourcePath), isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: contextURL).standardizedFileURL.path
    }

    private func singularKind(_ kind: String) -> String {
        kind == "configs" ? "config" : "secret"
    }

    private func orderedServices(_ services: [ComposeService]) -> [ComposeService] {
        var servicesByName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        var visited = Set<String>()
        var visiting = Set<String>()
        var ordered: [ComposeService] = []

        func visit(_ service: ComposeService) {
            guard !visited.contains(service.name), !visiting.contains(service.name) else { return }
            visiting.insert(service.name)
            for dependency in service.dependsOn.sorted() {
                if let dependencyService = servicesByName[dependency] {
                    visit(dependencyService)
                }
            }
            visiting.remove(service.name)
            visited.insert(service.name)
            ordered.append(service)
        }

        for service in services.sorted(by: { $0.name < $1.name }) {
            visit(service)
        }

        servicesByName.removeAll()
        return ordered
    }

    private func selectedOrderedServices(_ services: [ComposeService], selectedServices: [String]) -> [ComposeService] {
        let ordered = orderedServices(services)
        guard !selectedServices.isEmpty else { return ordered }
        let selected = Set(selectedServices)
        return ordered.filter { selected.contains($0.name) }
    }

    private func selectedServicesForUp(_ services: [ComposeService], selectedServices: [String]) -> [ComposeService] {
        let ordered = orderedServices(services)
        guard !selectedServices.isEmpty else { return ordered }

        let servicesByName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        var included = Set<String>()
        var visiting = Set<String>()

        func include(_ serviceName: String) {
            guard !included.contains(serviceName), !visiting.contains(serviceName), let service = servicesByName[serviceName] else {
                return
            }
            visiting.insert(serviceName)
            for dependency in service.dependsOn.sorted() {
                include(dependency)
            }
            visiting.remove(serviceName)
            included.insert(serviceName)
        }

        for serviceName in selectedServices {
            include(serviceName)
        }

        return ordered.filter { included.contains($0.name) }
    }

    private func resourceCreationCommands(
        project: ComposeProject,
        services: [ComposeService],
        isFullProjectPlan: Bool,
        excluding existingCommands: [PlannedCommand] = []
    ) -> [PlannedCommand] {
        let existingNetworkNames = Set(existingCommands
            .filter { $0.action == .createNetwork }
            .compactMap { $0.arguments.last })
        let existingVolumeNames = Set(existingCommands
            .filter { $0.action == .createVolume }
            .compactMap { $0.arguments.last })
        var commands: [PlannedCommand] = []

        for network in project.networks.values.sorted(by: { $0.name < $1.name })
            where !network.external && shouldCreateNetwork(network, for: services, isFullProjectPlan: isFullProjectPlan) {
            let name = networkResourceName(project: project.name, network: network)
            guard !existingNetworkNames.contains(name) else {
                continue
            }

            var arguments = ["network", "create"]
            if network.internalOnly {
                arguments.append("--internal")
            }
            for label in network.labels {
                arguments.append(contentsOf: ["--label", label])
            }
            var diagnostics: [ComposeDiagnostic] = []
            if network.hasUnmappedOptions {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "networks.\(network.name)",
                    message: "Network definition options are preserved but not fully mapped to Apple Container network create arguments yet."
                ))
            }
            arguments.append(name)
            commands.append(.init(action: .createNetwork, arguments: arguments, diagnostics: diagnostics))
        }

        for volume in project.volumes.values.sorted(by: { $0.name < $1.name })
            where !volume.external && shouldCreateVolume(volume, for: services, isFullProjectPlan: isFullProjectPlan) {
            let name = volumeResourceName(project: project.name, volume: volume)
            guard !existingVolumeNames.contains(name) else {
                continue
            }

            var arguments = ["volume", "create"]
            for label in volume.labels {
                arguments.append(contentsOf: ["--label", label])
            }
            var diagnostics: [ComposeDiagnostic] = []
            if volume.hasUnmappedOptions {
                diagnostics.append(.init(
                    severity: .warning,
                    path: "volumes.\(volume.name)",
                    message: "Volume definition options are preserved but not fully mapped to Apple Container volume create arguments yet."
                ))
            }
            arguments.append(name)
            commands.append(.init(action: .createVolume, arguments: arguments, diagnostics: diagnostics))
        }

        return commands
    }

    private func shouldCreateNetwork(
        _ network: ComposeNetwork,
        for services: [ComposeService],
        isFullProjectPlan: Bool
    ) -> Bool {
        isFullProjectPlan || services.contains { $0.networks.contains(network.name) }
    }

    private func shouldCreateVolume(
        _ volume: ComposeVolume,
        for services: [ComposeService],
        isFullProjectPlan: Bool
    ) -> Bool {
        isFullProjectPlan || services.contains { service in
            service.volumes.contains { namedVolumeName(from: $0) == volume.name }
        }
    }

    private func namedVolumeName(from value: String) -> String? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let source = String(first)
        guard !source.contains("/") && !source.contains(".") else {
            return nil
        }
        return source
    }

    private func normalizeVolume(_ value: String, projectName: String, volumes: [String: ComposeVolume]) -> String {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, !String(first).contains("/") && !String(first).contains(".") else {
            return value
        }
        var normalized = parts.map(String.init)
        if let volume = volumes[normalized[0]] {
            normalized[0] = volumeResourceName(project: projectName, volume: volume)
        } else {
            normalized[0] = resourceName(project: projectName, resource: normalized[0])
        }
        return normalized.joined(separator: ":")
    }

    private func volumeResourceName(project: String, volume: ComposeVolume) -> String {
        if let externalName = volume.externalName {
            return externalName
        }
        if let customName = volume.customName {
            return customName
        }
        if volume.external {
            return volume.name
        }
        return resourceName(project: project, resource: volume.name)
    }

    private func networkResourceName(project: String, network: ComposeNetwork) -> String {
        if let externalName = network.externalName {
            return externalName
        }
        if let customName = network.customName {
            return customName
        }
        if network.external {
            return network.name
        }
        return resourceName(project: project, resource: network.name)
    }

    private func resourceName(project: String, resource: String) -> String {
        "\(sanitize(project))_\(sanitize(resource))"
    }

    private func copyEndpoint(
        _ value: String,
        project: ComposeProject,
        replicaIndex: Int
    ) -> (value: String, service: ComposeService?, diagnostics: [ComposeDiagnostic]) {
        guard let separator = value.firstIndex(of: ":") else {
            return (value, nil, [])
        }

        let serviceName = String(value[..<separator])
        guard !serviceName.isEmpty,
              let service = project.services.first(where: { $0.name == serviceName }) else {
            return (value, nil, [])
        }

        var diagnostics: [ComposeDiagnostic] = []
        if service.containerName != nil, replicaIndex != 1 {
            diagnostics.append(.init(
                severity: .warning,
                path: "cp.index",
                message: "Replica index is ignored for services that declare container_name."
            ))
        }

        let containerPath = String(value[value.index(after: separator)...])
        return (
            "\(containerName(project: project.name, service: service, replicaIndex: replicaIndex)):\(containerPath)",
            service,
            diagnostics
        )
    }

    private func runtimeImage(project: String, service: ComposeService) -> String? {
        service.image ?? service.build.map { _ in generatedImageTag(project: project, service: service.name) }
    }

    private func buildTags(project: String, service: ComposeService) -> [String] {
        var tags: [String] = []
        if let image = service.image {
            tags.append(image)
        } else if service.build != nil {
            tags.append(generatedImageTag(project: project, service: service.name))
        }
        for tag in service.build?.tags ?? [] where !tags.contains(tag) {
            tags.append(tag)
        }
        return tags
    }

    private func generatedImageTag(project: String, service: String) -> String {
        "\(resourceName(project: project, resource: service)):latest"
    }

    private func containerName(project: String, service: ComposeService, replicaIndex: Int = 1) -> String {
        service.containerName ?? generatedContainerName(project: project, service: service.name, replicaIndex: replicaIndex)
    }

    private func generatedContainerName(project: String, service: String, replicaIndex: Int = 1) -> String {
        "\(sanitize(project))_\(sanitize(service))_\(replicaIndex)"
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
}
