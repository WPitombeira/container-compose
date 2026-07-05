import ArgumentParser
import ContainerComposeCore
import Foundation

@main
struct ContainerCompose: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-compose",
        abstract: "Compose-style orchestration for Apple's container runtime.",
        subcommands: [Config.self, Convert.self, Plan.self, Version.self, Compatibility.self, Doctor.self, Up.self, Run.self, Create.self, Build.self, Down.self, Start.self, Pull.self, Push.self, Publish.self, Images.self, Stop.self, Restart.self, Kill.self, Pause.self, Unpause.self, Attach.self, Wait.self, Scale.self, Commit.self, Export.self, Events.self, Watch.self, Ls.self, Volumes.self, Rm.self, Exec.self, Cp.self, Logs.self, Port.self, Ps.self, Top.self, Stats.self],
        defaultSubcommand: Plan.self
    )
}

struct ComposeOptions: ParsableArguments {
    @Option(name: [.short, .customLong("file")], help: "Compose file path. Can be specified multiple times; later files override earlier files. Use '-' to read one Compose file from stdin.")
    var files: [String] = []

    @Option(name: .customLong("project-directory"), help: "Working directory used to resolve Compose file paths.")
    var projectDirectory: String = FileManager.default.currentDirectoryPath

    @Option(name: [.short, .customLong("project-name")], help: "Override the Compose project name.")
    var projectName: String?

    @Option(name: .customLong("profile"), parsing: .upToNextOption, help: "Profiles to enable.")
    var profiles: [String] = []

    @Option(name: .customLong("env-file"), help: "Alternate environment file for Compose interpolation. Can be specified multiple times; later files override earlier files.")
    var envFiles: [String] = []

    @Flag(name: .customLong("allow-remote-includes"), help: "Allow Compose include entries to fetch http and https resources.")
    var allowRemoteIncludes = false

    func loadProject(operation: ContainerComposeOperation = .config) throws -> ComposeProject {
        try ContainerComposeService().loadProject(makeRequest(operation: operation))
    }

    func makeRequest(
        operation: ContainerComposeOperation,
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
        attachOptions: AppleContainerAttachOptions = .init(),
        waitOptions: AppleContainerWaitOptions = .init(),
        scaleTargets: [String: Int] = [:],
        scaleOptions: AppleContainerScaleOptions = .init(),
        commitOptions: AppleContainerCommitOptions = .init(),
        exportOptions: AppleContainerExportOptions = .init(),
        eventsOptions: AppleContainerEventsOptions = .init(),
        watchOptions: AppleContainerWatchOptions = .init(),
        publishOptions: AppleContainerPublishOptions = .init(),
        projectListOptions: AppleContainerProjectListOptions = .init(),
        volumesOptions: AppleContainerVolumesOptions = .init(),
        copySource: String? = nil,
        copyDestination: String? = nil,
        copyOptions: AppleContainerCopyOptions = .init(),
        pushOptions: AppleContainerPushOptions = .init(),
        imagesOptions: AppleContainerImagesOptions = .init(),
        runOptions: AppleContainerRunOptions = .init(),
        createOptions: AppleContainerCreateOptions = .init(),
        emitReadinessChecks: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        standardInput: FileHandle = .standardInput
    ) throws -> ContainerComposePlanRequest {
        let stdinComposeSources = try readComposeSourcesFromStandardInputIfRequested(
            environment: environment,
            standardInput: standardInput
        )
        return ContainerComposePlanRequest(
            operation: operation,
            files: stdinComposeSources == nil ? files : [],
            composeSources: stdinComposeSources ?? [],
            projectDirectory: projectDirectory,
            projectName: projectName,
            profiles: Set(profiles),
            environment: environment,
            composeEnvFiles: envFiles,
            allowRemoteIncludes: allowRemoteIncludes,
            emitReadinessChecks: emitReadinessChecks,
            detach: detach,
            services: services,
            follow: follow,
            tail: tail,
            all: all,
            removeVolumes: removeVolumes,
            stopBeforeRemove: stopBeforeRemove,
            noStream: noStream,
            signal: signal,
            execCommand: execCommand,
            execOptions: execOptions,
            attachOptions: attachOptions,
            waitOptions: waitOptions,
            scaleTargets: scaleTargets,
            scaleOptions: scaleOptions,
            commitOptions: commitOptions,
            exportOptions: exportOptions,
            eventsOptions: eventsOptions,
            watchOptions: watchOptions,
            publishOptions: publishOptions,
            projectListOptions: projectListOptions,
            volumesOptions: volumesOptions,
            copySource: copySource,
            copyDestination: copyDestination,
            copyOptions: copyOptions,
            pushOptions: pushOptions,
            imagesOptions: imagesOptions,
            runOptions: runOptions,
            createOptions: createOptions
        )
    }

    private func readComposeSourcesFromStandardInputIfRequested(
        environment: [String: String],
        standardInput: FileHandle
    ) throws -> [ComposeSource]? {
        let composeEnvironment = ComposeEnvironment(environment: environment)
        let effectiveFiles = files.isEmpty ? composeEnvironment.composeFilePaths : files
        guard effectiveFiles.contains("-") else {
            return nil
        }
        guard effectiveFiles.filter({ $0 == "-" }).count == 1 else {
            throw ValidationError("stdin Compose input with --file - can only be specified once")
        }
        let data = standardInput.readDataToEndOfFile()
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw ValidationError("stdin Compose input must be valid UTF-8")
        }
        return effectiveFiles.map { path in
            path == "-"
                ? ComposeSource(path: "compose.yaml", yaml: yaml)
                : ComposeSource(path: path)
        }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the normalized Container Compose model or config projections.")

    @OptionGroup var options: ComposeOptions
    @OptionGroup var renderOptions: ConfigRenderOptions

    func run() throws {
        let request = try options.makeRequest(operation: .config)
        let project = try ContainerComposeService().loadProject(request)
        try renderOptions.render(
            project: project,
            interpolationEnvironment: interpolationEnvironment(for: project, request: request),
            interpolationVariables: try interpolationVariables(for: project, request: request),
            commandName: "config"
        )
    }
}

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Convert the Compose model to Container Compose's canonical normalized format.")

    @OptionGroup var options: ComposeOptions
    @OptionGroup var renderOptions: ConfigRenderOptions

    func run() throws {
        let request = try options.makeRequest(operation: .convert)
        let project = try ContainerComposeService().loadProject(request)
        try renderOptions.render(
            project: project,
            interpolationEnvironment: interpolationEnvironment(for: project, request: request),
            interpolationVariables: try interpolationVariables(for: project, request: request),
            commandName: "convert"
        )
    }
}

private func interpolationEnvironment(
    for project: ComposeProject,
    request: ContainerComposePlanRequest
) -> [String: String] {
    let sourceDirectory = URL(fileURLWithPath: project.sourcePath)
        .deletingLastPathComponent()
        .standardizedFileURL
        .path
    return EnvironmentResolver(
        workingDirectory: sourceDirectory,
        environment: request.environment,
        envFiles: request.composeEnvFiles.isEmpty ? nil : request.composeEnvFiles
    ).interpolationEnvironment
}

private func interpolationVariables(
    for project: ComposeProject,
    request: ContainerComposePlanRequest
) throws -> [ComposeInterpolationVariable] {
    var variablesByName: [String: ComposeInterpolationVariable] = [:]
    for yaml in try interpolationVariableYAMLDocuments(for: project, request: request) {
        for variable in EnvironmentResolver.interpolationVariables(in: yaml) {
            merge(variable, into: &variablesByName)
        }
    }
    return variablesByName.values.sorted { $0.name < $1.name }
}

private func interpolationVariableYAMLDocuments(
    for project: ComposeProject,
    request: ContainerComposePlanRequest
) throws -> [String] {
    if !request.composeSources.isEmpty {
        return try request.composeSources.map { source in
            if let yaml = source.yaml {
                return yaml
            }
            return try String(contentsOfFile: resolvedComposePath(source.path, relativeTo: request.projectDirectory), encoding: .utf8)
        }
    }

    if let yaml = request.composeYAML {
        return [yaml]
    }

    let paths: [String]
    if request.files.isEmpty {
        paths = implicitComposeSourcePaths(from: project.sourcePath)
    } else {
        paths = request.files.map { resolvedComposePath($0, relativeTo: request.projectDirectory) }
    }

    return try paths.map {
        try String(contentsOfFile: $0, encoding: .utf8)
    }
}

private func implicitComposeSourcePaths(from sourcePath: String) -> [String] {
    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
    let sourceDirectory = sourceURL.deletingLastPathComponent()
    let overrideNames = [
        "compose.override.yaml",
        "compose.override.yml",
        "docker-compose.override.yaml",
        "docker-compose.override.yml"
    ]
    let overridePaths = overrideNames
        .map { sourceDirectory.appendingPathComponent($0).path }
        .filter { FileManager.default.fileExists(atPath: $0) }
    return [sourceURL.path] + overridePaths
}

private func resolvedComposePath(_ path: String, relativeTo projectDirectory: String) -> String {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
    return URL(
        fileURLWithPath: path,
        relativeTo: URL(fileURLWithPath: projectDirectory, isDirectory: true)
    ).standardizedFileURL.path
}

private func merge(
    _ variable: ComposeInterpolationVariable,
    into variablesByName: inout [String: ComposeInterpolationVariable]
) {
    guard let existing = variablesByName[variable.name] else {
        variablesByName[variable.name] = variable
        return
    }
    if existing.defaultValue == nil, variable.defaultValue != nil {
        variablesByName[variable.name] = variable
    }
}

struct ConfigRenderOptions: ParsableArguments {
    @Flag(name: .customLong("services"), help: "Print service names, one per line.")
    var services = false

    @Flag(name: .customLong("images"), help: "Print service image names, one per line.")
    var images = false

    @Flag(name: .customLong("profiles"), help: "Print profile names, one per line.")
    var profiles = false

    @Flag(name: .customLong("networks"), help: "Print network names, one per line.")
    var networks = false

    @Flag(name: .customLong("volumes"), help: "Print volume names, one per line.")
    var volumes = false

    @Flag(name: .customLong("models"), help: "Print model names, one per line.")
    var models = false

    @Flag(name: .customLong("environment"), help: "Print environment used for interpolation.")
    var environment = false

    @Flag(name: .customLong("variables"), help: "Print model variables and default values, one per line.")
    var variables = false

    @Option(name: .customLong("hash"), help: "Print a service config hash. Use '*' to print all service hashes.")
    var hash: String?

    @Flag(name: [.short, .customLong("quiet")], help: "Only validate the configuration.")
    var quiet = false

    @Option(name: .customLong("format"), help: "Output format for the normalized model. Values: json, yaml.")
    var format = "json"

    @Option(name: [.short, .customLong("output")], help: "Write config output to a file instead of stdout.")
    var output: String?

    func render(
        project: ComposeProject,
        interpolationEnvironment: [String: String] = [:],
        interpolationVariables: [ComposeInterpolationVariable] = [],
        commandName: String
    ) throws {
        let renderFormat = try ComposeConfigRenderer.parseFormat(format)
        if quiet {
            return
        }
        if let hash {
            try validateSingleProjection(commandName: commandName)
            let text = try ComposeConfigProjection.serviceHashValues(in: project, target: hash)
                .joined(separator: "\n") + "\n"
            try writeConfigOutput(text)
            return
        }
        if let projectionMode = try selectedProjectionMode(commandName: commandName) {
            let text = ComposeConfigProjection.values(
                for: projectionMode,
                in: project,
                interpolationEnvironment: interpolationEnvironment,
                interpolationVariables: interpolationVariables
            ).joined(separator: "\n") + "\n"
            try writeConfigOutput(text)
            return
        }
        let text = try ComposeConfigRenderer().render(project, format: renderFormat)
        try writeConfigOutput(text)
    }

    private func selectedProjectionMode(commandName: String) throws -> ComposeConfigProjectionMode? {
        try validateSingleProjection(commandName: commandName)
        return selectedProjectionModes.first
    }

    private var selectedProjectionModes: [ComposeConfigProjectionMode] {
        let selected: [(Bool, ComposeConfigProjectionMode)] = [
            (services, .services),
            (images, .images),
            (profiles, .profiles),
            (networks, .networks),
            (volumes, .volumes),
            (models, .models),
            (environment, .environment),
            (variables, .variables)
        ]
        return selected.compactMap { isSelected, mode in
            isSelected ? mode : nil
        }
    }

    private func validateSingleProjection(commandName: String) throws {
        let selectedCount = selectedProjectionModes.count + (hash == nil ? 0 : 1)
        guard selectedCount <= 1 else {
            throw ValidationError("\(commandName) accepts only one projection flag at a time")
        }
    }

    private func writeConfigOutput(_ text: String) throws {
        if let output {
            try text.write(toFile: output, atomically: true, encoding: .utf8)
        } else {
            FileHandle.standardOutput.writeText(text)
        }
    }
}

struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print planned Apple container commands as JSON.")

    @OptionGroup var options: ComposeOptions

    @Flag(help: "Plan foreground runs instead of detached services.")
    var foreground = false

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(operation: .plan, detach: !foreground))
        printJSON(result.plan)
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print Container Compose version and schema metadata.")

    @Option(name: .customLong("format"), help: "Output format. Values: text, json, yaml.")
    var format = "text"

    func run() throws {
        let info = ContainerComposeMetadata.currentVersionInfo
        switch format.lowercased() {
        case "text":
            print("\(info.name) \(info.version)")
            print("package: \(info.packageName)")
            print("command: \(info.commandName)")
            print("runtime target: \(info.runtimeTarget)")
            print("container desktop integration: \(info.containerDesktopIntegration)")
            print("schemas:")
            print("  plan: \(info.schemas.plan)")
            print("  execution report: \(info.schemas.executionReport)")
            print("  execution graph: \(info.schemas.executionGraph)")
            print("  runtime status: \(info.schemas.runtimeStatus)")
        case "json", "yaml":
            let renderFormat = try ComposeConfigRenderer.parseFormat(format)
            print(try ComposeConfigRenderer().render(info, format: renderFormat), terminator: "")
        default:
            throw ValidationError("Unsupported version format '\(format)'. Expected one of: text, json, yaml.")
        }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check Apple container runtime availability.")

    @Flag(name: .customLong("json"), help: "Print a machine-readable runtime status.")
    var json = false

    func run() throws {
        let status = ContainerComposeService().runtimeStatus()
        if json {
            printJSON(status)
        } else {
            print("runtime: \(status.runtime)")
            print("executable: \(status.executable)")
            print("availability: \(status.availability.rawValue)")
            if let executablePath = status.executablePath {
                print("path: \(executablePath)")
            }
            if let version = status.version {
                print("version: \(version)")
            }
            for issue in status.issues {
                FileHandle.standardError.writeLine("\(issue.severity.rawValue)[code=\(issue.code.rawValue)]: \(issue.message)")
            }
        }
        if status.availability == .unavailable {
            throw ExitCode(1)
        }
    }
}

struct Compatibility: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the Compose compatibility matrix.")

    @Option(name: .customLong("format"), help: "Output format. Values: text, json, yaml.")
    var format = "text"

    @Option(name: .customLong("status"), help: "Filter by status: mapped, preservedDiagnostic, rejectedDiagnostic, unsupported.")
    var status: String?

    @Option(name: .customLong("area"), help: "Filter by area: loader, planner, runtime, integration.")
    var area: String?

    func run() throws {
        let matrix = ComposeCompatibilityMatrix.current
        let entries = matrix.entries(with: try parsedStatus(), area: try parsedArea())
        switch format.lowercased() {
        case "text":
            printText(entries)
        case "json", "yaml":
            let renderFormat = try ComposeConfigRenderer.parseFormat(format)
            let filtered = ComposeCompatibilityMatrix(generatedFrom: matrix.generatedFrom, entries: entries)
            print(try ComposeConfigRenderer().render(filtered, format: renderFormat), terminator: "")
        default:
            throw ValidationError("Unsupported compatibility format '\(format)'. Expected one of: text, json, yaml.")
        }
    }

    private func parsedStatus() throws -> ComposeCompatibilityStatus? {
        guard let status else { return nil }
        if let exact = ComposeCompatibilityStatus(rawValue: status) {
            return exact
        }
        let normalized = status.lowercased().replacingOccurrences(of: "-", with: "")
        for candidate in ComposeCompatibilityStatus.allCases where candidate.rawValue.lowercased() == normalized {
            return candidate
        }
        throw ValidationError("Unsupported compatibility status '\(status)'.")
    }

    private func parsedArea() throws -> ComposeCompatibilityArea? {
        guard let area else { return nil }
        if let exact = ComposeCompatibilityArea(rawValue: area) {
            return exact
        }
        let normalized = area.lowercased().replacingOccurrences(of: "-", with: "")
        for candidate in ComposeCompatibilityArea.allCases where candidate.rawValue.lowercased() == normalized {
            return candidate
        }
        throw ValidationError("Unsupported compatibility area '\(area)'.")
    }

    private func printText(_ entries: [ComposeCompatibilityEntry]) {
        for status in ComposeCompatibilityStatus.allCases {
            let section = entries.filter { $0.status == status }
            guard !section.isEmpty else { continue }
            print(status.rawValue)
            for entry in section {
                print("  \(entry.composePath) [\(entry.area.rawValue)] \(entry.note)")
            }
        }
    }
}

struct Up: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create resources and run services with Apple container.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: [.short, .customLong("detach")], help: "Run services in the background.")
    var detach = false

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Flag(name: .customLong("wait"), help: "Wait for dependency containers to satisfy depends_on readiness conditions before starting dependents. Implies --detach.")
    var wait = false

    @Argument(help: "Optional service names to create and run with their dependencies.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .up,
            detach: wait ? true : detach,
            services: services,
            emitReadinessChecks: wait
        ))
        try execute(result.plan, dryRun: dryRun, json: json, enforceReadiness: wait)
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a one-off command for a service with Apple container.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: [.short, .customLong("detach")], help: "Run the one-off container in the background.")
    var detach = false

    @Flag(name: [.customShort("T"), .customLong("no-tty")], help: "Disable pseudo-TTY allocation.")
    var noTTY = false

    @Flag(name: .customLong("no-interactive"), help: "Disable interactive stdin.")
    var noInteractive = false

    @Flag(name: .customLong("rm"), help: "Remove the one-off container after it stops.")
    var remove = false

    @Flag(name: .customLong("no-deps"), help: "Do not start linked services before running the command.")
    var noDependencies = false

    @Flag(name: .customLong("service-ports"), help: "Publish service ports for the one-off container.")
    var servicePorts = false

    @Option(name: .customLong("publish"), help: "Publish an additional port for the one-off container.")
    var publish: [String] = []

    @Option(name: .customLong("name"), help: "Assign a custom container name.")
    var name: String?

    @Option(name: .customLong("entrypoint"), help: "Override the service entrypoint.")
    var entrypoint: String?

    @Option(name: [.short, .customLong("env")], help: "Set environment variables for the one-off container.")
    var environment: [String] = []

    @Option(name: .customLong("env-file"), help: "Read environment variables from a file.")
    var envFiles: [String] = []

    @Option(name: [.short, .customLong("user")], help: "Run the command as this user.")
    var user: String?

    @Option(name: [.short, .customLong("workdir")], help: "Path to the working directory for this command.")
    var workdir: String?

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Service name to run.")
    var service: String

    @Argument(parsing: .captureForPassthrough, help: "Optional command and arguments.")
    var command: [String] = []

    func run() throws {
        let runOptions = AppleContainerRunOptions(
            detach: detach,
            remove: remove,
            noDependencies: noDependencies,
            servicePorts: servicePorts,
            publish: publish,
            name: name,
            entrypoint: entrypoint,
            command: command,
            environment: environment,
            envFiles: envFiles,
            user: user,
            workdir: workdir,
            interactive: !noInteractive,
            tty: !noTTY
        )
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .run,
            services: [service],
            runOptions: runOptions
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create stopped service containers with Apple container.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("no-build"), help: "Do not build images before creating service containers.")
    var noBuild = false

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to create with their dependencies.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .create,
            services: services,
            createOptions: .init(noBuild: noBuild)
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Down: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop and delete project service containers.")

    @OptionGroup var options: ComposeOptions

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Flag(name: [.short, .customLong("volumes")], help: "Remove named volumes declared by the Compose project.")
    var volumes = false

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(operation: .down, removeVolumes: volumes))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build service images with Apple container.")

    @OptionGroup var options: ComposeOptions

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to build.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(operation: .build, services: services))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start project service containers.")

    @OptionGroup var options: ComposeOptions

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to start.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(operation: .start, services: services))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop project service containers.")

    @OptionGroup var options: ComposeOptions

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to stop.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(operation: .stop, services: services))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Pull: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pull service images with Apple container.")

    @OptionGroup var options: ComposeOptions

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to pull.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(operation: .pull, services: services))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Push: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Push service images with Apple container.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("ignore-push-failures"), help: "Accept Docker Compose ignore-failures mode and emit an execution compatibility diagnostic.")
    var ignorePushFailures = false

    @Flag(name: .customLong("include-deps"), help: "Also push images for selected service dependencies.")
    var includeDependencies = false

    @Flag(name: [.short, .customLong("quiet")], help: "Push without printing progress information.")
    var quiet = false

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to push.")
    var services: [String] = []

    func run() throws {
        let pushOptions = AppleContainerPushOptions(
            includeDependencies: includeDependencies,
            ignorePushFailures: ignorePushFailures,
            quiet: quiet
        )
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .push,
            services: services,
            pushOptions: pushOptions
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Publish: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview Docker Compose publish intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("app"), help: "Publish the Compose application including referenced images.")
    var app = false

    @Option(name: .customLong("oci-version"), help: "OCI image or artifact specification version.")
    var ociVersion: String?

    @Flag(name: .customLong("resolve-image-digests"), help: "Pin image tags to digests.")
    var resolveImageDigests = false

    @Flag(name: .customLong("with-env"), help: "Include environment variables in the published OCI artifact.")
    var withEnvironment = false

    @Flag(name: [.short, .customLong("yes")], help: "Assume yes as answer to all prompts.")
    var yes = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable planned execution report.")
    var json = false

    @Argument(help: "Target repository or repository:tag.")
    var repository: String

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .publish,
            publishOptions: .init(
                app: app,
                ociVersion: ociVersion,
                resolveImageDigests: resolveImageDigests,
                withEnvironment: withEnvironment,
                yes: yes,
                repository: repository
            )
        ))
        try execute(result.plan, dryRun: true, json: json, enforceReadiness: true)
    }
}

struct Images: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List images from the Apple container runtime.")

    @OptionGroup var options: ComposeOptions

    @Option(name: .customLong("format"), help: "Output format. Values supported by Apple Container include table, json, yaml, and toml.")
    var format = "table"

    @Flag(name: [.short, .customLong("quiet")], help: "Only output image names.")
    var quiet = false

    @Flag(name: .customLong("verbose"), help: "Show verbose image details.")
    var verbose = false

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names retained as plan metadata; Apple Container image listing cannot filter by service yet.")
    var services: [String] = []

    func run() throws {
        let imagesOptions = AppleContainerImagesOptions(
            format: format,
            quiet: quiet,
            verbose: verbose
        )
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .images,
            services: services,
            imagesOptions: imagesOptions
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Restart: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restart project service containers.")

    @OptionGroup var options: ComposeOptions

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to restart.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(operation: .restart, services: services))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Kill: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Force stop project service containers.")

    @OptionGroup var options: ComposeOptions

    @Option(name: [.short, .customLong("signal")], help: "Signal to send to service containers.")
    var signal: String?

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to kill.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .kill,
            services: services,
            signal: signal
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview Docker Compose pause intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("json"), help: "Print a machine-readable planned execution report.")
    var json = false

    @Argument(help: "Optional service names to pause.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(operation: .pause, services: services))
        try execute(result.plan, dryRun: true, json: json, enforceReadiness: true)
    }
}

struct Unpause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview Docker Compose unpause intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("json"), help: "Print a machine-readable planned execution report.")
    var json = false

    @Argument(help: "Optional service names to unpause.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(operation: .unpause, services: services))
        try execute(result.plan, dryRun: true, json: json, enforceReadiness: true)
    }
}

struct Attach: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview Docker Compose attach intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Option(name: .customLong("detach-keys"), help: "Override the key sequence for detaching from a container.")
    var detachKeys: String?

    @Option(name: .customLong("index"), help: "Replica index for the service container.")
    var index = 1

    @Flag(name: .customLong("no-stdin"), help: "Do not attach STDIN.")
    var noStdin = false

    @Option(name: .customLong("sig-proxy"), help: "Proxy received signals to the process. Defaults to true.")
    var sigProxy = true

    @Flag(name: .customLong("json"), help: "Print a machine-readable planned execution report.")
    var json = false

    @Argument(help: "Service name to attach to.")
    var service: String

    func run() throws {
        let attachOptions = AppleContainerAttachOptions(
            detachKeys: detachKeys,
            replicaIndex: index,
            attachStdin: !noStdin,
            signalProxy: sigProxy
        )
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .attach,
            services: [service],
            attachOptions: attachOptions
        ))
        try execute(result.plan, dryRun: true, json: json, enforceReadiness: true)
    }
}

struct Wait: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview Docker Compose wait intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("down-project"), help: "Preserve Docker Compose project cleanup intent after the first container stops.")
    var downProject = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable planned execution report.")
    var json = false

    @Argument(help: "Optional service names to wait for.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .wait,
            services: services,
            waitOptions: .init(downProject: downProject)
        ))
        try execute(result.plan, dryRun: true, json: json, enforceReadiness: true)
    }
}

struct Scale: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview Docker Compose scale intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("no-deps"), help: "Do not start linked services while preserving Docker Compose scale intent.")
    var noDependencies = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable planned execution report.")
    var json = false

    @Argument(help: "Service scale assignments like web=2.")
    var assignments: [String] = []

    func run() throws {
        let parsed = try parseScaleAssignments(assignments)
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .scale,
            services: parsed.services,
            scaleTargets: parsed.targets,
            scaleOptions: .init(noDependencies: noDependencies)
        ))
        try execute(result.plan, dryRun: true, json: json, enforceReadiness: true)
    }

    private func parseScaleAssignments(_ assignments: [String]) throws -> (services: [String], targets: [String: Int]) {
        guard !assignments.isEmpty else {
            throw ValidationError("scale requires at least one SERVICE=REPLICAS assignment")
        }

        var services: [String] = []
        var targets: [String: Int] = [:]

        for assignment in assignments {
            let parts = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw ValidationError("scale assignment '\(assignment)' must use SERVICE=REPLICAS syntax")
            }

            let service = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let replicaValue = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !service.isEmpty else {
                throw ValidationError("scale assignment '\(assignment)' is missing a service name")
            }
            guard !replicaValue.isEmpty else {
                throw ValidationError("scale assignment '\(assignment)' is missing a replica count")
            }
            guard targets[service] == nil else {
                throw ValidationError("scale assignment for service '\(service)' was specified more than once")
            }
            guard let replicas = Int(replicaValue), replicas >= 0 else {
                throw ValidationError("scale assignment '\(assignment)' must use a non-negative integer replica count")
            }

            services.append(service)
            targets[service] = replicas
        }

        return (services, targets)
    }
}

struct Commit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview Docker Compose commit intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Option(name: [.short, .customLong("author")], help: "Author for the created image.")
    var author: String?

    @Option(name: [.short, .customLong("change")], help: "Dockerfile instruction to apply to the created image. Can be specified multiple times.")
    var changes: [String] = []

    @Option(name: .customLong("index"), help: "Replica index for the service container.")
    var index = 1

    @Option(name: [.short, .customLong("message")], help: "Commit message.")
    var message: String?

    @Option(name: .customLong("pause"), help: "Pause the container during commit. Defaults to true.")
    var pause = true

    @Flag(name: .customLong("json"), help: "Print a machine-readable planned execution report.")
    var json = false

    @Argument(help: "Service name to commit.")
    var service: String

    @Argument(help: "Optional target repository or repository:tag.")
    var repository: String?

    func run() throws {
        let commitOptions = AppleContainerCommitOptions(
            author: author,
            changes: changes,
            message: message,
            replicaIndex: index,
            pause: pause,
            repository: repository
        )
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .commit,
            services: [service],
            commitOptions: commitOptions
        ))
        try execute(result.plan, dryRun: true, json: json, enforceReadiness: true)
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview Docker Compose export intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Option(name: .customLong("index"), help: "Replica index for the service container.")
    var index = 1

    @Option(name: [.short, .customLong("output")], help: "Write the tar archive to a file instead of stdout.")
    var output: String?

    @Flag(name: .customLong("json"), help: "Print a machine-readable planned execution report.")
    var json = false

    @Argument(help: "Service name to export.")
    var service: String

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .export,
            services: [service],
            exportOptions: .init(
                replicaIndex: index,
                output: output
            )
        ))
        try execute(result.plan, dryRun: true, json: json, enforceReadiness: true)
    }
}

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview Docker Compose events intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("json"), help: "Preserve Docker Compose JSON event stream formatting intent.")
    var outputJSON = false

    @Option(name: .customLong("since"), help: "Show events created since this timestamp or relative duration.")
    var since: String?

    @Option(name: .customLong("until"), help: "Stream events until this timestamp or relative duration.")
    var until: String?

    @Argument(help: "Optional service names to watch for events.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .events,
            services: services,
            eventsOptions: .init(
                outputJSON: outputJSON,
                since: since,
                until: until
            )
        ))
        try execute(result.plan, dryRun: true, json: false, enforceReadiness: true)
    }
}

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview Docker Compose watch intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("no-up"), help: "Do not build and start services before watching.")
    var noUp = false

    @Option(name: .customLong("prune"), help: "Prune dangling images on rebuild. Defaults to true.")
    var prune = true

    @Flag(name: .customLong("quiet"), help: "Hide build output.")
    var quiet = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable planned execution report.")
    var json = false

    @Argument(help: "Optional service names to watch.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .watch,
            services: services,
            watchOptions: .init(
                noUp: noUp,
                prune: prune,
                quiet: quiet
            )
        ))
        try execute(result.plan, dryRun: true, json: json, enforceReadiness: true)
    }
}

struct Ls: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "Preview Docker Compose project-list intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: [.short, .customLong("all")], help: "Show all stopped Compose projects.")
    var all = false

    @Option(name: .customLong("filter"), help: "Filter output based on a condition. Can be specified multiple times.")
    var filters: [String] = []

    @Option(name: .customLong("format"), help: "Output format for project listing intent. Docker Compose supports table or json.")
    var format = "table"

    @Flag(name: [.short, .customLong("quiet")], help: "Only display project names.")
    var quiet = false

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .ls,
            projectListOptions: .init(
                all: all,
                filters: filters,
                format: format,
                quiet: quiet
            )
        ))
        try execute(result.plan, dryRun: true, json: false, enforceReadiness: true)
    }
}

struct Volumes: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview Docker Compose volume-list intent with Apple Container compatibility diagnostics.")

    @OptionGroup var options: ComposeOptions

    @Option(name: .customLong("format"), help: "Output format for volume listing intent. Docker Compose supports table, table templates, json, and custom templates.")
    var format = "table"

    @Flag(name: [.short, .customLong("quiet")], help: "Only display volume names.")
    var quiet = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable planned execution report.")
    var json = false

    @Argument(help: "Optional service names used to scope volume listing.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .volumes,
            services: services,
            volumesOptions: .init(
                format: format,
                quiet: quiet
            )
        ))
        try execute(result.plan, dryRun: true, json: json, enforceReadiness: true)
    }
}

struct Rm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove stopped project service containers.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("force"), help: "Do not ask to confirm removal. Container Compose is non-interactive, and -f remains reserved for --file.")
    var force = false

    @Flag(name: [.short, .customLong("stop")], help: "Stop containers before removing them.")
    var stop = false

    @Flag(name: [.short, .customLong("volumes")], help: "Accept Docker Compose --volumes and emit an Apple Container compatibility diagnostic.")
    var volumes = false

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to remove.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .rm,
            services: services,
            removeVolumes: volumes,
            stopBeforeRemove: stop
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Exec: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Execute a command in a running service container.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: [.short, .customLong("detach")], help: "Run the command in the background.")
    var detach = false

    @Option(name: [.short, .customLong("env")], help: "Set environment variables for the exec process.")
    var environment: [String] = []

    @Option(name: .customLong("env-file"), help: "Read environment variables from a file.")
    var envFiles: [String] = []

    @Option(name: .customLong("index"), help: "Replica index for the service container.")
    var index = 1

    @Flag(name: [.customShort("T"), .customLong("no-tty")], help: "Disable pseudo-TTY allocation.")
    var noTTY = false

    @Flag(name: .customLong("no-interactive"), help: "Disable interactive stdin.")
    var noInteractive = false

    @Flag(name: .customLong("privileged"), help: "Accept Docker Compose --privileged and emit an Apple Container compatibility diagnostic.")
    var privileged = false

    @Option(name: [.short, .customLong("user")], help: "Run the command as this user.")
    var user: String?

    @Option(name: [.short, .customLong("workdir")], help: "Path to the working directory for this command.")
    var workdir: String?

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Service name to execute the command in.")
    var service: String

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments to execute.")
    var command: [String] = []

    func run() throws {
        guard !command.isEmpty else {
            throw ValidationError("exec requires a command after the service name")
        }

        let execOptions = AppleContainerExecOptions(
            detach: detach,
            environment: environment,
            envFiles: envFiles,
            user: user,
            workdir: workdir,
            interactive: !noInteractive,
            tty: !noTTY,
            replicaIndex: index,
            privileged: privileged
        )
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .exec,
            services: [service],
            execCommand: command,
            execOptions: execOptions
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Cp: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cp", abstract: "Copy files between a service container and the local filesystem.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("all"), help: "Accept Docker Compose --all and emit an Apple Container compatibility diagnostic.")
    var all = false

    @Flag(name: [.short, .customLong("archive")], help: "Accept Docker Compose archive mode and emit an Apple Container compatibility diagnostic.")
    var archive = false

    @Flag(name: [.customShort("L"), .customLong("follow-link")], help: "Accept Docker Compose symlink-following mode and emit an Apple Container compatibility diagnostic.")
    var followLink = false

    @Option(name: .customLong("index"), help: "Replica index for the service container.")
    var index = 1

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Source path. Use SERVICE:PATH for service-container sources.")
    var source: String

    @Argument(help: "Destination path. Use SERVICE:PATH for service-container destinations.")
    var destination: String

    func run() throws {
        let copyOptions = AppleContainerCopyOptions(
            replicaIndex: index,
            archive: archive,
            followLink: followLink,
            includeRunContainers: all
        )
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .cp,
            services: inferredServices(source: source, destination: destination),
            copySource: source,
            copyDestination: destination,
            copyOptions: copyOptions
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }

    private func inferredServices(source: String, destination: String) -> [String] {
        [servicePrefix(from: source), servicePrefix(from: destination)]
            .compactMap { $0 }
    }

    private func servicePrefix(from endpoint: String) -> String? {
        guard let separator = endpoint.firstIndex(of: ":") else { return nil }
        let prefix = String(endpoint[..<separator])
        return prefix.isEmpty ? nil : prefix
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Fetch service logs.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("follow"), help: "Follow log output.")
    var follow = false

    @Option(name: [.customShort("n"), .customLong("tail")], help: "Number of lines to show from the end of the logs.")
    var tail: Int?

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to read logs from.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .logs,
            services: services,
            follow: follow,
            tail: tail
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Port: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the published host endpoint for a service port.")

    @OptionGroup var options: ComposeOptions

    @Option(name: .customLong("index"), help: "Replica index for the service container.")
    var index = 1

    @Option(name: .customLong("protocol"), help: "Port protocol. Values: tcp or udp.")
    var protocolValue = "tcp"

    @Argument(help: "Service name to inspect.")
    var service: String

    @Argument(help: "Private service port to resolve.")
    var privatePort: String

    func run() throws {
        do {
            let resolution = try ContainerComposeService().resolvePort(
                try options.makeRequest(operation: .port, services: [service]),
                serviceName: service,
                privatePort: privatePort,
                protocolValue: protocolValue,
                replicaIndex: index
            )
            printDiagnostics(resolution.diagnostics)
            print(resolution.endpoint)
        } catch let error as ComposePortResolutionError {
            throw ValidationError(error.localizedDescription)
        }
    }
}

struct Ps: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List containers from the Apple container runtime.")

    @OptionGroup var options: ComposeOptions

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Flag(name: [.short, .customLong("all")], help: "Include containers that are not running.")
    var all = false

    @Argument(help: "Optional service names retained as plan metadata; Apple Container listing cannot filter by service yet.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .ps,
            services: services,
            all: all
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Top: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Display running processes for service containers.")

    @OptionGroup var options: ComposeOptions

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to inspect.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .top,
            services: services
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Display service container resource usage.")

    @OptionGroup var options: ComposeOptions

    @Flag(name: .customLong("no-stream"), help: "Return only the first stats snapshot.")
    var noStream = false

    @Flag(help: "Print commands without executing them.")
    var dryRun = false

    @Flag(name: .customLong("json"), help: "Print a machine-readable execution report.")
    var json = false

    @Argument(help: "Optional service names to inspect.")
    var services: [String] = []

    func run() throws {
        let result = try ContainerComposeService().makePlan(try options.makeRequest(
            operation: .stats,
            services: services,
            noStream: noStream
        ))
        try execute(result.plan, dryRun: dryRun, json: json)
    }
}

func execute(_ plan: AppleContainerPlan, dryRun: Bool, json: Bool, enforceReadiness: Bool = false) throws {
    let executionPlan = planWithRuntimeStatus(plan, dryRun: dryRun)

    if json || enforceReadiness {
        let report = ContainerComposeService().execute(
            plan: executionPlan,
            dryRun: dryRun,
            executor: DefaultContainerCommandExecutor(),
            enforceReadiness: enforceReadiness
        )
        if json {
            printJSON(report)
        } else if dryRun {
            printCommands(plan)
        } else {
            printDiagnostics(plan.diagnostics)
            printExecutionOutput(report.results)
        }
        if !dryRun, report.summary.failed > 0 {
            let exitCode = report.results.first { $0.status == .failed }?.exitCode ?? Int32(1)
            throw ExitCode(exitCode)
        }
        return
    }

    try execute(executionPlan, dryRun: dryRun)
}

func execute(_ plan: AppleContainerPlan, dryRun: Bool) throws {
    printDiagnostics(plan.diagnostics)
    if !dryRun, plan.runtimeStatus?.availability == .unavailable {
        printRuntimeIssues(plan.runtimeStatus)
        throw ExitCode(1)
    }
    let executor = DefaultContainerCommandExecutor()
    for command in plan.commands {
        printDiagnostics(command.diagnostics)
        let printable = shellEscaped(["container"] + command.arguments)
        if dryRun {
            print(printable)
            continue
        }
        let result = try executor.execute(arguments: command.arguments)
        FileHandle.standardOutput.writeText(result.standardOutput)
        FileHandle.standardError.writeText(result.standardError)
        if result.exitCode != 0 {
            throw ExitCode(result.exitCode)
        }
    }
}

func planWithRuntimeStatus(_ plan: AppleContainerPlan, dryRun: Bool) -> AppleContainerPlan {
    guard !dryRun else { return plan }
    var executionPlan = plan
    executionPlan.runtimeStatus = ContainerComposeService().runtimeStatus()
    return executionPlan
}

func printRuntimeIssues(_ status: AppleContainerRuntimeStatus?) {
    for issue in status?.issues ?? [] {
        FileHandle.standardError.writeLine("\(issue.severity.rawValue)[code=\(issue.code.rawValue)]: \(issue.message)")
    }
}

func printCommands(_ plan: AppleContainerPlan) {
    printDiagnostics(plan.diagnostics)
    for command in plan.commands {
        printDiagnostics(command.diagnostics)
        print(shellEscaped(["container"] + command.arguments))
    }
}

func printDiagnostics(_ diagnostics: [ComposeDiagnostic]) {
    for diagnostic in diagnostics {
        FileHandle.standardError.writeLine("\(diagnostic.severity.rawValue): \(diagnostic.path): \(diagnostic.message)")
    }
}

func printExecutionOutput(_ results: [PlannedCommandExecution]) {
    for result in results {
        FileHandle.standardOutput.writeText(result.standardOutput)
        FileHandle.standardError.writeText(result.standardError)
        if let error = result.error, !error.isEmpty {
            FileHandle.standardError.writeLine(error)
        }
    }
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func shellEscaped(_ arguments: [String]) -> String {
    arguments.map { argument in
        if argument.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "'\""))) == nil {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}

extension FileHandle {
    func writeLine(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) {
            write(data)
        }
    }

    func writeText(_ text: String) {
        if let data = text.data(using: .utf8) {
            write(data)
        }
    }
}
