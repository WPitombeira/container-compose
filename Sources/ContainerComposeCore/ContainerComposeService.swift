import Foundation

public enum ContainerComposeOperation: String, Codable, CaseIterable, Sendable {
    case config
    case plan
    case up
    case run
    case create
    case build
    case down
    case start
    case pull
    case push
    case images
    case stop
    case restart
    case kill
    case rm
    case exec
    case cp
    case logs
    case ps
    case stats
}

public struct ContainerComposePlanRequest: Equatable, Sendable {
    public var operation: ContainerComposeOperation
    public var files: [String]
    public var composeSources: [ComposeSource]
    public var composeYAML: String?
    public var composeYAMLSourcePath: String?
    public var projectDirectory: String
    public var projectName: String?
    public var profiles: Set<String>
    public var environment: [String: String]
    public var composeEnvFiles: [String]
    public var allowRemoteIncludes: Bool
    public var emitReadinessChecks: Bool
    public var runtimeStatus: AppleContainerRuntimeStatus?
    public var detach: Bool
    public var services: [String]
    public var follow: Bool
    public var tail: Int?
    public var all: Bool
    public var removeVolumes: Bool
    public var stopBeforeRemove: Bool
    public var noStream: Bool
    public var signal: String?
    public var execCommand: [String]
    public var execOptions: AppleContainerExecOptions
    public var copySource: String?
    public var copyDestination: String?
    public var copyOptions: AppleContainerCopyOptions
    public var pushOptions: AppleContainerPushOptions
    public var imagesOptions: AppleContainerImagesOptions
    public var runOptions: AppleContainerRunOptions
    public var createOptions: AppleContainerCreateOptions

    public init(
        operation: ContainerComposeOperation = .plan,
        files: [String] = [],
        composeSources: [ComposeSource] = [],
        composeYAML: String? = nil,
        composeYAMLSourcePath: String? = nil,
        projectDirectory: String = FileManager.default.currentDirectoryPath,
        projectName: String? = nil,
        profiles: Set<String> = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        composeEnvFiles: [String] = [],
        allowRemoteIncludes: Bool = false,
        emitReadinessChecks: Bool = false,
        runtimeStatus: AppleContainerRuntimeStatus? = nil,
        detach: Bool = true,
        services: [String] = [],
        follow: Bool = false,
        tail: Int? = nil,
        all: Bool = true,
        removeVolumes: Bool = false,
        stopBeforeRemove: Bool = false,
        noStream: Bool = false,
        signal: String? = nil,
        execCommand: [String] = [],
        execOptions: AppleContainerExecOptions = .init(),
        copySource: String? = nil,
        copyDestination: String? = nil,
        copyOptions: AppleContainerCopyOptions = .init(),
        pushOptions: AppleContainerPushOptions = .init(),
        imagesOptions: AppleContainerImagesOptions = .init(),
        runOptions: AppleContainerRunOptions = .init(),
        createOptions: AppleContainerCreateOptions = .init()
    ) {
        self.operation = operation
        self.files = files
        self.composeSources = composeSources
        self.composeYAML = composeYAML
        self.composeYAMLSourcePath = composeYAMLSourcePath
        self.projectDirectory = projectDirectory
        self.projectName = projectName
        self.profiles = profiles
        self.environment = environment
        self.composeEnvFiles = composeEnvFiles
        self.allowRemoteIncludes = allowRemoteIncludes
        self.emitReadinessChecks = emitReadinessChecks
        self.runtimeStatus = runtimeStatus
        self.detach = detach
        self.services = services
        self.follow = follow
        self.tail = tail
        self.all = all
        self.removeVolumes = removeVolumes
        self.stopBeforeRemove = stopBeforeRemove
        self.noStream = noStream
        self.signal = signal
        self.execCommand = execCommand
        self.execOptions = execOptions
        self.copySource = copySource
        self.copyDestination = copyDestination
        self.copyOptions = copyOptions
        self.pushOptions = pushOptions
        self.imagesOptions = imagesOptions
        self.runOptions = runOptions
        self.createOptions = createOptions
    }
}

public struct ContainerComposePlanResult: Codable, Equatable, Sendable {
    public var project: ComposeProject
    public var plan: AppleContainerPlan

    public init(project: ComposeProject, plan: AppleContainerPlan) {
        self.project = project
        self.plan = plan
    }
}

public struct ContainerComposeService: Sendable {
    private let remoteIncludeFetcher: ComposeLoader.RemoteIncludeFetcher?
    private let remoteIncludeResolver: ComposeLoader.RemoteIncludeResolver?

    public init(remoteIncludeFetcher: ComposeLoader.RemoteIncludeFetcher? = nil) {
        self.remoteIncludeFetcher = remoteIncludeFetcher
        self.remoteIncludeResolver = nil
    }

    public init(remoteIncludeResolver: @escaping ComposeLoader.RemoteIncludeResolver) {
        self.remoteIncludeFetcher = nil
        self.remoteIncludeResolver = remoteIncludeResolver
    }

    public func loadProject(_ request: ContainerComposePlanRequest) throws -> ComposeProject {
        let composeEnvironment = ComposeEnvironment(environment: request.environment)
        let effectiveFiles = request.files.isEmpty ? composeEnvironment.composeFilePaths : request.files
        let effectiveProfiles = request.profiles.isEmpty ? Set(composeEnvironment.composeProfiles) : request.profiles
        let loader: ComposeLoader
        if let remoteIncludeResolver {
            loader = ComposeLoader(
                environment: request.environment,
                envFiles: request.composeEnvFiles.isEmpty ? nil : request.composeEnvFiles,
                allowRemoteIncludes: request.allowRemoteIncludes,
                remoteIncludeResolver: remoteIncludeResolver
            )
        } else {
            loader = ComposeLoader(
                environment: request.environment,
                envFiles: request.composeEnvFiles.isEmpty ? nil : request.composeEnvFiles,
                allowRemoteIncludes: request.allowRemoteIncludes,
                remoteIncludeFetcher: remoteIncludeFetcher
            )
        }

        var project: ComposeProject
        if !request.composeSources.isEmpty {
            project = try loader.load(
                from: request.composeSources,
                workingDirectory: request.projectDirectory,
                activeProfiles: effectiveProfiles,
                targetedServices: targetedServicesForLoad(request)
            )
        } else if let composeYAML = request.composeYAML {
            project = try loader.load(
                yaml: composeYAML,
                sourcePath: composeYAMLSourcePath(for: request),
                activeProfiles: effectiveProfiles,
                targetedServices: targetedServicesForLoad(request)
            )
        } else if effectiveFiles.isEmpty {
            project = try loader.load(
                workingDirectory: request.projectDirectory,
                activeProfiles: effectiveProfiles,
                targetedServices: targetedServicesForLoad(request)
            )
        } else {
            project = try loader.load(
                from: effectiveFiles,
                workingDirectory: request.projectDirectory,
                activeProfiles: effectiveProfiles,
                targetedServices: targetedServicesForLoad(request)
            )
        }

        if let effectiveProjectName = request.projectName ?? composeEnvironment.composeProjectName {
            project.name = effectiveProjectName
            appendContainerNameCollisionDiagnostics(to: &project)
        }
        return project
    }

    private func composeYAMLSourcePath(for request: ContainerComposePlanRequest) -> String {
        guard let sourcePath = request.composeYAMLSourcePath, !sourcePath.isEmpty else {
            return URL(
                fileURLWithPath: "compose.yaml",
                relativeTo: URL(fileURLWithPath: request.projectDirectory, isDirectory: true)
            ).standardizedFileURL.path
        }
        if sourcePath.hasPrefix("/") {
            return URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        }
        return URL(
            fileURLWithPath: sourcePath,
            relativeTo: URL(fileURLWithPath: request.projectDirectory, isDirectory: true)
        ).standardizedFileURL.path
    }

    public func makePlan(_ request: ContainerComposePlanRequest) throws -> ContainerComposePlanResult {
        var project = try loadProject(request)
        appendMissingServiceDiagnostics(to: &project, request: request)
        appendBuildDiagnostics(to: &project, request: request)
        appendPullImageDiagnostics(to: &project, request: request)
        appendPushImageDiagnostics(to: &project, request: request)
        let commands = plannedCommands(for: request.operation, project: project, request: request)
        let operation = planOperationName(for: request.operation)
        return ContainerComposePlanResult(
            project: project,
            plan: AppleContainerPlan(
                project: project,
                operation: operation,
                commands: commands,
                runtimeStatus: request.runtimeStatus,
                selectedServices: selectedServicesForPlan(request),
                emitReadinessChecks: request.emitReadinessChecks
            )
        )
    }

    public func runtimeStatus(
        using probe: AppleContainerRuntimeProbing = AppleContainerRuntimeProbe()
    ) -> AppleContainerRuntimeStatus {
        probe.probe()
    }

    public func dryRun(_ request: ContainerComposePlanRequest) throws -> AppleContainerExecutionReport {
        let result = try makePlan(request)
        return execute(plan: result.plan, dryRun: true, executor: NoopContainerCommandExecutor())
    }

    public func execute(
        plan: AppleContainerPlan,
        dryRun: Bool,
        executor: ContainerCommandExecutor,
        enforceReadiness: Bool = false,
        readinessChecker: ContainerReadinessChecking = DefaultContainerReadinessChecker(),
        controls: AppleContainerExecutionControls = .init()
    ) -> AppleContainerExecutionReport {
        AppleContainerExecutionRunner().run(
            plan: plan,
            dryRun: dryRun,
            executor: executor,
            enforceReadiness: enforceReadiness,
            readinessChecker: readinessChecker,
            controls: controls
        )
    }

    public func execute(
        plan: AppleContainerPlan,
        dryRun: Bool,
        executor: AsyncContainerCommandExecutor,
        enforceReadiness: Bool = false,
        readinessChecker: AsyncContainerReadinessChecking = DefaultAsyncContainerReadinessChecker(),
        controls: AppleContainerExecutionControls = .init()
    ) async -> AppleContainerExecutionReport {
        await AppleContainerExecutionRunner().run(
            plan: plan,
            dryRun: dryRun,
            executor: executor,
            enforceReadiness: enforceReadiness,
            readinessChecker: readinessChecker,
            controls: controls
        )
    }

    private func plannedCommands(
        for operation: ContainerComposeOperation,
        project: ComposeProject,
        request: ContainerComposePlanRequest
    ) -> [PlannedCommand] {
        let planner = AppleContainerPlanner()
        switch operation {
        case .config:
            return []
        case .plan, .up:
            return planner.planUp(project: project, detach: request.detach, services: request.services)
        case .run:
            return planner.planRun(project: project, service: request.services.first, options: request.runOptions)
        case .create:
            return planner.planCreate(project: project, services: request.services, options: request.createOptions)
        case .build:
            return planner.planBuild(project: project, services: request.services)
        case .down:
            return planner.planDown(project: project, removeVolumes: request.removeVolumes)
        case .start:
            return planner.planStart(project: project, services: request.services)
        case .pull:
            return planner.planPull(project: project, services: request.services)
        case .push:
            return planner.planPush(project: project, services: request.services, options: request.pushOptions)
        case .images:
            return planner.planImages(project: project, services: request.services, options: request.imagesOptions)
        case .stop:
            return planner.planStop(project: project, services: request.services)
        case .restart:
            return planner.planRestart(project: project, services: request.services)
        case .kill:
            return planner.planKill(project: project, services: request.services, signal: request.signal)
        case .rm:
            return planner.planRemove(
                project: project,
                services: request.services,
                stop: request.stopBeforeRemove,
                removeVolumes: request.removeVolumes
            )
        case .exec:
            return planner.planExec(
                project: project,
                service: request.services.first,
                command: request.execCommand,
                options: request.execOptions
            )
        case .cp:
            return planner.planCopy(
                project: project,
                source: request.copySource,
                destination: request.copyDestination,
                options: request.copyOptions
            )
        case .logs:
            return planner.planLogs(project: project, services: request.services, follow: request.follow, tail: request.tail)
        case .ps:
            return planner.planPs(project: project, services: request.services, all: request.all)
        case .stats:
            return planner.planStats(project: project, services: request.services, noStream: request.noStream)
        }
    }

    private func appendMissingServiceDiagnostics(to project: inout ComposeProject, request: ContainerComposePlanRequest) {
        guard !request.services.isEmpty, operationUsesServiceTargets(request.operation) else { return }
        let availableServices = Set(project.services.map(\.name))
        for service in request.services where !availableServices.contains(service) {
            project.diagnostics.append(.init(
                severity: .warning,
                path: "services.\(service)",
                message: "Selected service is not present in the active Compose model. Check the service name or enabled profiles."
            ))
        }
    }

    private func appendContainerNameCollisionDiagnostics(to project: inout ComposeProject) {
        var firstServiceByContainerName: [String: String] = [:]
        for service in project.services {
            let containerName = service.containerName ?? "\(sanitize(project.name))_\(sanitize(service.name))_1"
            if let firstService = firstServiceByContainerName[containerName] {
                appendUniqueDiagnostic(
                    .init(
                        severity: .error,
                        path: service.containerName == nil ? "services.\(service.name)" : "services.\(service.name).container_name",
                        message: "container_name '\(containerName)' is already used by service '\(firstService)'."
                    ),
                    to: &project
                )
            } else {
                firstServiceByContainerName[containerName] = service.name
            }
        }
    }

    private func appendPullImageDiagnostics(to project: inout ComposeProject, request: ContainerComposePlanRequest) {
        guard request.operation == .pull else { return }
        let selectedServices = Set(request.services)
        for service in project.services.sorted(by: { $0.name < $1.name })
            where selectedServices.isEmpty || selectedServices.contains(service.name) {
            guard service.image == nil else { continue }
            appendUniqueDiagnostic(
                .init(
                    severity: .warning,
                    path: "services.\(service.name).image",
                    message: "Pull planning skipped service '\(service.name)' because it has no image."
                ),
                to: &project
            )
        }
    }

    private func appendPushImageDiagnostics(to project: inout ComposeProject, request: ContainerComposePlanRequest) {
        guard request.operation == .push else { return }
        let servicesForPush = request.pushOptions.includeDependencies
            ? servicesIncludingDependencies(project.services, selectedServices: request.services)
            : project.services.sorted(by: { $0.name < $1.name })
                .filter { request.services.isEmpty || Set(request.services).contains($0.name) }

        for service in servicesForPush where service.image == nil {
            appendUniqueDiagnostic(
                .init(
                    severity: .warning,
                    path: "services.\(service.name).image",
                    message: "Push planning skipped service '\(service.name)' because it has no image."
                ),
                to: &project
            )
        }
    }

    private func appendBuildDiagnostics(to project: inout ComposeProject, request: ContainerComposePlanRequest) {
        guard request.operation == .build else { return }
        let selectedServices = Set(request.services)
        for service in project.services.sorted(by: { $0.name < $1.name })
            where selectedServices.isEmpty || selectedServices.contains(service.name) {
            guard service.build == nil else { continue }
            appendUniqueDiagnostic(
                .init(
                    severity: .warning,
                    path: "services.\(service.name).build",
                    message: "Build planning skipped service '\(service.name)' because it has no build section."
                ),
                to: &project
            )
        }
    }

    private func appendUniqueDiagnostic(_ diagnostic: ComposeDiagnostic, to project: inout ComposeProject) {
        guard !project.diagnostics.contains(where: {
            $0.severity == diagnostic.severity
                && $0.path == diagnostic.path
                && $0.message == diagnostic.message
        }) else {
            return
        }
        project.diagnostics.append(diagnostic)
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

    private func planOperationName(for operation: ContainerComposeOperation) -> String {
        operation.rawValue
    }

    private func selectedServicesForPlan(_ request: ContainerComposePlanRequest) -> [String] {
        operationUsesServiceTargets(request.operation) ? request.services : []
    }

    private func targetedServicesForLoad(_ request: ContainerComposePlanRequest) -> Set<String> {
        operationUsesServiceTargets(request.operation) ? Set(request.services) : []
    }

    private func operationUsesServiceTargets(_ operation: ContainerComposeOperation) -> Bool {
        switch operation {
        case .plan, .up, .run, .create, .build, .start, .pull, .push, .images, .stop, .restart, .kill, .rm, .exec, .cp, .logs, .ps, .stats:
            return true
        case .config, .down:
            return false
        }
    }

    private func servicesIncludingDependencies(_ services: [ComposeService], selectedServices: [String]) -> [ComposeService] {
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
}

private struct NoopContainerCommandExecutor: ContainerCommandExecutor {
    func execute(arguments: [String]) throws -> CommandExecutionResult {
        throw ContainerCommandExecutionError.processFailed("dry-run executor should not be called")
    }
}
