import ArgumentParser
import ContainerComposeCore
import Foundation

@main
struct ContainerCompose: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-compose",
        abstract: "Compose-style orchestration for Apple's container runtime.",
        subcommands: [Config.self, Plan.self, Compatibility.self, Doctor.self, Up.self, Run.self, Create.self, Build.self, Down.self, Start.self, Pull.self, Push.self, Images.self, Stop.self, Restart.self, Kill.self, Rm.self, Exec.self, Cp.self, Logs.self, Ps.self, Stats.self],
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

    func loadProject() throws -> ComposeProject {
        try ContainerComposeService().loadProject(makeRequest(operation: .config))
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

    @Flag(name: [.short, .customLong("quiet")], help: "Only validate the configuration.")
    var quiet = false

    @Option(name: .customLong("format"), help: "Output format for the normalized model. Values: json, yaml.")
    var format = "json"

    @Option(name: [.short, .customLong("output")], help: "Write config output to a file instead of stdout.")
    var output: String?

    func run() throws {
        let project = try options.loadProject()
        let renderFormat = try ComposeConfigRenderer.parseFormat(format)
        if quiet {
            return
        }
        if let projectionMode = try selectedProjectionMode() {
            let text = ComposeConfigProjection.values(for: projectionMode, in: project).joined(separator: "\n") + "\n"
            try writeConfigOutput(text)
            return
        }
        let text = try ComposeConfigRenderer().render(project, format: renderFormat)
        try writeConfigOutput(text)
    }

    private func selectedProjectionMode() throws -> ComposeConfigProjectionMode? {
        let selected: [(Bool, ComposeConfigProjectionMode)] = [
            (services, .services),
            (images, .images),
            (profiles, .profiles),
            (networks, .networks),
            (volumes, .volumes)
        ]
        let modes = selected.compactMap { isSelected, mode in
            isSelected ? mode : nil
        }
        guard modes.count <= 1 else {
            throw ValidationError("config accepts only one projection flag at a time")
        }
        return modes.first
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
