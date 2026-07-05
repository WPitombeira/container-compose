import Foundation

public enum AppleContainerExecutionEvent: Equatable, Sendable {
    case commandPlanned(commandIndex: Int, command: PlannedCommand)
    case commandStarted(commandIndex: Int, command: PlannedCommand)
    case commandFinished(PlannedCommandExecution)
    case commandSkipped(PlannedCommandExecution)
    case commandCancelled(PlannedCommandExecution)
    case readinessStarted(commandIndex: Int, requirement: AppleContainerReadinessRequirement)
    case readinessFinished(AppleContainerReadinessResult)
}

public struct AppleContainerExecutionControls: Sendable {
    public var isCancelled: @Sendable () -> Bool
    public var progress: (@Sendable (AppleContainerExecutionEvent) -> Void)?

    public init(
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (AppleContainerExecutionEvent) -> Void)? = nil
    ) {
        self.isCancelled = isCancelled
        self.progress = progress
    }

    public func emit(_ event: AppleContainerExecutionEvent) {
        progress?(event)
    }
}

public protocol ContainerCommandExecutor {
    @discardableResult
    func execute(arguments: [String]) throws -> CommandExecutionResult
}

public protocol AsyncContainerCommandExecutor {
    @discardableResult
    func execute(arguments: [String]) async throws -> CommandExecutionResult
}

public enum AppleContainerRuntimeAvailability: String, Codable, Sendable {
    case available
    case unavailable
    case unknown
}

public enum AppleContainerRuntimeIssueCode: String, Codable, Sendable {
    case containerCLIUnavailable
    case versionProbeFailed
    case versionCommandExitedNonZero
}

public struct AppleContainerRuntimeIssue: Codable, Equatable, Sendable {
    public var code: AppleContainerRuntimeIssueCode
    public var severity: DiagnosticSeverity
    public var message: String

    public init(
        code: AppleContainerRuntimeIssueCode,
        severity: DiagnosticSeverity = .error,
        message: String
    ) {
        self.code = code
        self.severity = severity
        self.message = message
    }
}

public struct AppleContainerRuntimeStatus: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var runtime: String
    public var executable: String
    public var executablePath: String?
    public var availability: AppleContainerRuntimeAvailability
    public var version: String?
    public var issues: [AppleContainerRuntimeIssue]

    public init(
        schemaVersion: String = ContainerComposeMetadata.runtimeStatusSchemaVersion,
        runtime: String = "apple-container",
        executable: String = "container",
        executablePath: String? = nil,
        availability: AppleContainerRuntimeAvailability,
        version: String? = nil,
        issues: [AppleContainerRuntimeIssue] = []
    ) {
        self.schemaVersion = schemaVersion
        self.runtime = runtime
        self.executable = executable
        self.executablePath = executablePath
        self.availability = availability
        self.version = version
        self.issues = issues
    }
}

public protocol AppleContainerRuntimeProbing {
    func probe() -> AppleContainerRuntimeStatus
}

public protocol ContainerReadinessChecking {
    func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: ContainerCommandExecutor
    ) -> AppleContainerReadinessResult

    func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: ContainerCommandExecutor,
        controls: AppleContainerExecutionControls
    ) -> AppleContainerReadinessResult
}

public protocol AsyncContainerReadinessChecking {
    func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: AsyncContainerCommandExecutor
    ) async -> AppleContainerReadinessResult

    func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: AsyncContainerCommandExecutor,
        controls: AppleContainerExecutionControls
    ) async -> AppleContainerReadinessResult
}

public extension ContainerReadinessChecking {
    func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: ContainerCommandExecutor,
        controls: AppleContainerExecutionControls
    ) -> AppleContainerReadinessResult {
        wait(for: requirement, executor: executor)
    }
}

public extension AsyncContainerReadinessChecking {
    func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: AsyncContainerCommandExecutor,
        controls: AppleContainerExecutionControls
    ) async -> AppleContainerReadinessResult {
        await wait(for: requirement, executor: executor)
    }
}

public enum ContainerCommandExecutionError: Error, Equatable {
    case containerCLIUnavailable
    case processFailed(String)
}

public enum AppleContainerExecutionErrorCode: String, Codable, Sendable {
    case containerCLIUnavailable
    case processFailed
    case nonZeroExit
    case readinessFailed
    case readinessTimedOut
    case readinessCancelled
    case executionCancelled
    case unsupportedPlanAction
    case skippedPreviousFailure
}

public enum PlannedCommandExecutionStatus: String, Codable, Sendable {
    case planned
    case executed
    case failed
    case skipped
    case cancelled
}

public struct CommandExecutionResult: Equatable, Codable {
    public let executablePath: String
    public let arguments: [String]
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let durationMilliseconds: Int

    public init(
        executablePath: String,
        arguments: [String],
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        durationMilliseconds: Int = 0
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.durationMilliseconds = durationMilliseconds
    }

    public var succeeded: Bool {
        exitCode == 0
    }
}

public struct PlannedCommandExecution: Codable, Equatable, Sendable {
    public var commandIndex: Int
    public var command: PlannedCommand
    public var status: PlannedCommandExecutionStatus
    public var executablePath: String?
    public var exitCode: Int32?
    public var succeeded: Bool
    public var standardOutput: String
    public var standardError: String
    public var errorCode: AppleContainerExecutionErrorCode?
    public var error: String?
    public var durationMilliseconds: Int

    public init(
        commandIndex: Int,
        command: PlannedCommand,
        status: PlannedCommandExecutionStatus,
        executablePath: String? = nil,
        exitCode: Int32? = nil,
        standardOutput: String = "",
        standardError: String = "",
        errorCode: AppleContainerExecutionErrorCode? = nil,
        error: String? = nil,
        durationMilliseconds: Int = 0
    ) {
        self.commandIndex = commandIndex
        self.command = command
        self.status = status
        self.executablePath = executablePath
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.errorCode = errorCode
        self.error = error
        self.durationMilliseconds = durationMilliseconds
        succeeded = status == .planned || status == .executed
    }

    public init(commandIndex: Int, command: PlannedCommand, result: CommandExecutionResult) {
        self.init(
            commandIndex: commandIndex,
            command: command,
            status: result.succeeded ? .executed : .failed,
            executablePath: result.executablePath,
            exitCode: result.exitCode,
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            errorCode: result.succeeded ? nil : .nonZeroExit,
            error: result.succeeded ? nil : Self.nonZeroExitMessage(for: result),
            durationMilliseconds: result.durationMilliseconds
        )
    }

    private enum CodingKeys: String, CodingKey {
        case commandIndex
        case command
        case status
        case executablePath
        case exitCode
        case succeeded
        case standardOutput
        case standardError
        case errorCode
        case error
        case durationMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandIndex = try container.decode(Int.self, forKey: .commandIndex)
        command = try container.decode(PlannedCommand.self, forKey: .command)
        status = try container.decode(PlannedCommandExecutionStatus.self, forKey: .status)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        succeeded = try container.decodeIfPresent(Bool.self, forKey: .succeeded) ?? (status == .planned || status == .executed)
        standardOutput = try container.decodeIfPresent(String.self, forKey: .standardOutput) ?? ""
        standardError = try container.decodeIfPresent(String.self, forKey: .standardError) ?? ""
        errorCode = try container.decodeIfPresent(AppleContainerExecutionErrorCode.self, forKey: .errorCode)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds) ?? 0
    }

    private static func nonZeroExitMessage(for result: CommandExecutionResult) -> String {
        let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return "container command exited with \(result.exitCode)."
        }
        return detail
    }
}

public enum AppleContainerReadinessStatus: String, Codable, Sendable {
    case ready
    case timedOut
    case failed
    case skipped
    case cancelled
}

public struct AppleContainerReadinessResult: Codable, Equatable, Sendable {
    public var commandIndex: Int?
    public var requirement: AppleContainerReadinessRequirement
    public var status: AppleContainerReadinessStatus
    public var attempts: Int
    public var durationMilliseconds: Int
    public var error: String?

    public init(
        commandIndex: Int? = nil,
        requirement: AppleContainerReadinessRequirement,
        status: AppleContainerReadinessStatus,
        attempts: Int = 0,
        durationMilliseconds: Int = 0,
        error: String? = nil
    ) {
        self.commandIndex = commandIndex
        self.requirement = requirement
        self.status = status
        self.attempts = attempts
        self.durationMilliseconds = durationMilliseconds
        self.error = error
    }

    public var succeeded: Bool {
        status == .ready || status == .skipped
    }
}

public struct AppleContainerExecutionSummary: Codable, Equatable, Sendable {
    public var total: Int
    public var succeeded: Int
    public var failed: Int
    public var skipped: Int
    public var cancelled: Int
    public var durationMilliseconds: Int

    public init(results: [PlannedCommandExecution]) {
        total = results.count
        succeeded = results.filter(\.succeeded).count
        failed = results.filter { $0.status == .failed }.count
        skipped = results.filter { $0.status == .skipped }.count
        cancelled = results.filter { $0.status == .cancelled }.count
        durationMilliseconds = results.reduce(0) { $0 + $1.durationMilliseconds }
    }

    private enum CodingKeys: String, CodingKey {
        case total
        case succeeded
        case failed
        case skipped
        case cancelled
        case durationMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(Int.self, forKey: .total)
        succeeded = try container.decode(Int.self, forKey: .succeeded)
        failed = try container.decode(Int.self, forKey: .failed)
        skipped = try container.decode(Int.self, forKey: .skipped)
        cancelled = try container.decodeIfPresent(Int.self, forKey: .cancelled) ?? 0
        durationMilliseconds = try container.decode(Int.self, forKey: .durationMilliseconds)
    }
}

public struct AppleContainerExecutionReport: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var projectName: String
    public var sourcePath: String
    public var runtime: String
    public var executable: String
    public var runtimeStatus: AppleContainerRuntimeStatus?
    public var operation: String
    public var selectedServices: [String]
    public var dryRun: Bool
    public var diagnostics: [ComposeDiagnostic]
    public var executionGraph: AppleContainerExecutionGraph?
    public var results: [PlannedCommandExecution]
    public var readinessResults: [AppleContainerReadinessResult]
    public var summary: AppleContainerExecutionSummary

    public init(
        plan: AppleContainerPlan,
        dryRun: Bool,
        results: [PlannedCommandExecution],
        readinessResults: [AppleContainerReadinessResult] = [],
        runtimeStatus: AppleContainerRuntimeStatus? = nil,
        schemaVersion: String? = nil
    ) {
        self.schemaVersion = schemaVersion ?? plan.schemaVersion
        projectName = plan.projectName
        sourcePath = plan.sourcePath
        runtime = plan.runtime
        executable = plan.executable
        self.runtimeStatus = runtimeStatus ?? plan.runtimeStatus
        operation = plan.operation
        selectedServices = plan.selectedServices
        self.dryRun = dryRun
        diagnostics = plan.diagnostics
        executionGraph = plan.executionGraph
        self.results = results
        self.readinessResults = readinessResults
        summary = AppleContainerExecutionSummary(results: results)
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
        case dryRun
        case diagnostics
        case executionGraph
        case results
        case readinessResults
        case summary
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
        dryRun = try container.decode(Bool.self, forKey: .dryRun)
        diagnostics = try container.decode([ComposeDiagnostic].self, forKey: .diagnostics)
        executionGraph = try container.decodeIfPresent(AppleContainerExecutionGraph.self, forKey: .executionGraph)
        results = try container.decode([PlannedCommandExecution].self, forKey: .results)
        readinessResults = try container.decodeIfPresent([AppleContainerReadinessResult].self, forKey: .readinessResults) ?? []
        summary = try container.decode(AppleContainerExecutionSummary.self, forKey: .summary)
    }
}

public struct AppleContainerExecutionRunner {
    public init() {}

    public func run(
        plan: AppleContainerPlan,
        dryRun: Bool,
        executor: ContainerCommandExecutor,
        enforceReadiness: Bool = false,
        readinessChecker: ContainerReadinessChecking = DefaultContainerReadinessChecker(),
        controls: AppleContainerExecutionControls = .init()
    ) -> AppleContainerExecutionReport {
        var results: [PlannedCommandExecution] = []
        var readinessResults: [AppleContainerReadinessResult] = []
        let graphNodeByCommandIndex = Dictionary(
            uniqueKeysWithValues: (plan.executionGraph?.nodes ?? []).map { ($0.commandIndex, $0) }
        )

        if !dryRun, plan.runtimeStatus?.availability == .unavailable {
            appendRuntimeUnavailableExecutions(
                for: plan,
                to: &results,
                controls: controls
            )
            return AppleContainerExecutionReport(
                plan: plan,
                dryRun: dryRun,
                results: results,
                readinessResults: readinessResults
            )
        }

        for (index, command) in plan.commands.enumerated() {
            if dryRun {
                let execution = PlannedCommandExecution(commandIndex: index, command: command, status: .planned)
                results.append(execution)
                controls.emit(.commandPlanned(commandIndex: index, command: command))
                continue
            }

            if controls.isCancelled() {
                let execution = cancelledExecution(commandIndex: index, command: command)
                results.append(execution)
                controls.emit(.commandCancelled(execution))
                appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                break
            }

            if enforceReadiness, let node = graphNodeByCommandIndex[index], !node.readiness.isEmpty {
                var checks: [AppleContainerReadinessResult] = []
                for requirement in node.readiness {
                    if controls.isCancelled() {
                        let execution = cancelledExecution(commandIndex: index, command: command)
                        results.append(execution)
                        controls.emit(.commandCancelled(execution))
                        appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                        return AppleContainerExecutionReport(
                            plan: plan,
                            dryRun: dryRun,
                            results: results,
                            readinessResults: readinessResults
                        )
                    }
                    controls.emit(.readinessStarted(commandIndex: index, requirement: requirement))
                    var result = readinessChecker.wait(for: requirement, executor: executor, controls: controls)
                    result.commandIndex = index
                    checks.append(result)
                    readinessResults.append(result)
                    controls.emit(.readinessFinished(result))
                }
                if let failedCheck = checks.first(where: { !$0.succeeded }) {
                    let status: PlannedCommandExecutionStatus = failedCheck.status == .cancelled ? .cancelled : .failed
                    let execution = PlannedCommandExecution(
                        commandIndex: index,
                        command: command,
                        status: status,
                        errorCode: readinessErrorCode(for: failedCheck),
                        error: readinessFailureMessage(for: failedCheck)
                    )
                    results.append(execution)
                    if status == .cancelled {
                        controls.emit(.commandCancelled(execution))
                    } else {
                        controls.emit(.commandFinished(execution))
                    }
                    appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                    break
                }
            }

            if let unsupported = unsupportedPlanActionExecution(commandIndex: index, command: command) {
                results.append(unsupported)
                controls.emit(.commandFinished(unsupported))
                appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                break
            }

            controls.emit(.commandStarted(commandIndex: index, command: command))
            do {
                let materializedFiles = try materializeGeneratedFiles(command.generatedFiles)
                defer { cleanupGeneratedFiles(materializedFiles) }
                let result = try executor.execute(arguments: command.arguments)
                let execution = PlannedCommandExecution(commandIndex: index, command: command, result: result)
                results.append(execution)
                controls.emit(.commandFinished(execution))
                if !execution.succeeded {
                    appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                    break
                }
            } catch {
                let execution = PlannedCommandExecution(
                    commandIndex: index,
                    command: command,
                    status: .failed,
                    errorCode: executionErrorCode(for: error),
                    error: String(describing: error)
                )
                results.append(execution)
                controls.emit(.commandFinished(execution))
                appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                break
            }
        }

        return AppleContainerExecutionReport(
            plan: plan,
            dryRun: dryRun,
            results: results,
            readinessResults: readinessResults
        )
    }

    public func run(
        plan: AppleContainerPlan,
        dryRun: Bool,
        executor: AsyncContainerCommandExecutor,
        enforceReadiness: Bool = false,
        readinessChecker: AsyncContainerReadinessChecking = DefaultAsyncContainerReadinessChecker(),
        controls: AppleContainerExecutionControls = .init()
    ) async -> AppleContainerExecutionReport {
        var results: [PlannedCommandExecution] = []
        var readinessResults: [AppleContainerReadinessResult] = []
        let graphNodeByCommandIndex = Dictionary(
            uniqueKeysWithValues: (plan.executionGraph?.nodes ?? []).map { ($0.commandIndex, $0) }
        )

        if !dryRun, plan.runtimeStatus?.availability == .unavailable {
            appendRuntimeUnavailableExecutions(
                for: plan,
                to: &results,
                controls: controls
            )
            return AppleContainerExecutionReport(
                plan: plan,
                dryRun: dryRun,
                results: results,
                readinessResults: readinessResults
            )
        }

        for (index, command) in plan.commands.enumerated() {
            if dryRun {
                let execution = PlannedCommandExecution(commandIndex: index, command: command, status: .planned)
                results.append(execution)
                controls.emit(.commandPlanned(commandIndex: index, command: command))
                continue
            }

            if controls.isCancelled() {
                let execution = cancelledExecution(commandIndex: index, command: command)
                results.append(execution)
                controls.emit(.commandCancelled(execution))
                appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                break
            }

            if enforceReadiness, let node = graphNodeByCommandIndex[index], !node.readiness.isEmpty {
                var checks: [AppleContainerReadinessResult] = []
                for requirement in node.readiness {
                    if controls.isCancelled() {
                        let execution = cancelledExecution(commandIndex: index, command: command)
                        results.append(execution)
                        controls.emit(.commandCancelled(execution))
                        appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                        return AppleContainerExecutionReport(
                            plan: plan,
                            dryRun: dryRun,
                            results: results,
                            readinessResults: readinessResults
                        )
                    }
                    controls.emit(.readinessStarted(commandIndex: index, requirement: requirement))
                    var result = await readinessChecker.wait(for: requirement, executor: executor, controls: controls)
                    result.commandIndex = index
                    checks.append(result)
                    readinessResults.append(result)
                    controls.emit(.readinessFinished(result))
                }
                if let failedCheck = checks.first(where: { !$0.succeeded }) {
                    let status: PlannedCommandExecutionStatus = failedCheck.status == .cancelled ? .cancelled : .failed
                    let execution = PlannedCommandExecution(
                        commandIndex: index,
                        command: command,
                        status: status,
                        errorCode: readinessErrorCode(for: failedCheck),
                        error: readinessFailureMessage(for: failedCheck)
                    )
                    results.append(execution)
                    if status == .cancelled {
                        controls.emit(.commandCancelled(execution))
                    } else {
                        controls.emit(.commandFinished(execution))
                    }
                    appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                    break
                }
            }

            if let unsupported = unsupportedPlanActionExecution(commandIndex: index, command: command) {
                results.append(unsupported)
                controls.emit(.commandFinished(unsupported))
                appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                break
            }

            controls.emit(.commandStarted(commandIndex: index, command: command))
            do {
                let materializedFiles = try materializeGeneratedFiles(command.generatedFiles)
                defer { cleanupGeneratedFiles(materializedFiles) }
                let result = try await executor.execute(arguments: command.arguments)
                let execution = PlannedCommandExecution(commandIndex: index, command: command, result: result)
                results.append(execution)
                controls.emit(.commandFinished(execution))
                if !execution.succeeded {
                    appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                    break
                }
            } catch {
                let execution = PlannedCommandExecution(
                    commandIndex: index,
                    command: command,
                    status: .failed,
                    errorCode: executionErrorCode(for: error),
                    error: String(describing: error)
                )
                results.append(execution)
                controls.emit(.commandFinished(execution))
                appendSkippedCommands(after: index, in: plan.commands, to: &results, controls: controls)
                break
            }
        }

        return AppleContainerExecutionReport(
            plan: plan,
            dryRun: dryRun,
            results: results,
            readinessResults: readinessResults
        )
    }

    private func materializeGeneratedFiles(_ files: [PlannedGeneratedFile]) throws -> [URL] {
        try files.map { file in
            let url = URL(fileURLWithPath: file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    private func cleanupGeneratedFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func readinessFailureMessage(for result: AppleContainerReadinessResult) -> String {
        let status = result.status.rawValue
        let service = result.requirement.service
        let condition = result.requirement.condition.rawValue
        let base = "Readiness check \(status) for service '\(service)' (\(condition))."
        guard let error = result.error, !error.isEmpty else { return base }
        return "\(base) \(error)"
    }

    private func readinessErrorCode(for result: AppleContainerReadinessResult) -> AppleContainerExecutionErrorCode {
        switch result.status {
        case .cancelled:
            return .readinessCancelled
        case .timedOut:
            return .readinessTimedOut
        case .failed:
            return .readinessFailed
        case .ready, .skipped:
            return .readinessFailed
        }
    }

    private func executionErrorCode(for error: Error) -> AppleContainerExecutionErrorCode {
        guard let executionError = error as? ContainerCommandExecutionError else {
            return .processFailed
        }
        switch executionError {
        case .containerCLIUnavailable:
            return .containerCLIUnavailable
        case .processFailed:
            return .processFailed
        }
    }

    private func cancelledExecution(commandIndex: Int, command: PlannedCommand) -> PlannedCommandExecution {
        PlannedCommandExecution(
            commandIndex: commandIndex,
            command: command,
            status: .cancelled,
            errorCode: .executionCancelled,
            error: "Execution cancelled."
        )
    }

    private func unsupportedPlanActionExecution(commandIndex: Int, command: PlannedCommand) -> PlannedCommandExecution? {
        guard command.action == .delegateService || command.action == .pauseService else { return nil }
        return PlannedCommandExecution(
            commandIndex: commandIndex,
            command: command,
            status: .failed,
            errorCode: .unsupportedPlanAction,
            error: "Planned action \(command.action.rawValue) is not executable through Apple Container yet."
        )
    }

    private func appendSkippedCommands(
        after failedIndex: Int,
        in commands: [PlannedCommand],
        to results: inout [PlannedCommandExecution],
        controls: AppleContainerExecutionControls
    ) {
        let nextIndex = failedIndex + 1
        guard nextIndex < commands.count else { return }
        for index in nextIndex..<commands.count {
            let execution = PlannedCommandExecution(
                commandIndex: index,
                command: commands[index],
                status: .skipped,
                errorCode: .skippedPreviousFailure,
                error: "Skipped because a previous command failed."
            )
            results.append(execution)
            controls.emit(.commandSkipped(execution))
        }
    }

    private func appendRuntimeUnavailableExecutions(
        for plan: AppleContainerPlan,
        to results: inout [PlannedCommandExecution],
        controls: AppleContainerExecutionControls
    ) {
        guard let firstCommand = plan.commands.first else { return }
        let message = plan.runtimeStatus?.issues.first?.message
            ?? "Apple container runtime is unavailable."
        let execution = PlannedCommandExecution(
            commandIndex: 0,
            command: firstCommand,
            status: .failed,
            errorCode: .containerCLIUnavailable,
            error: message
        )
        results.append(execution)
        controls.emit(.commandFinished(execution))
        appendSkippedCommands(after: 0, in: plan.commands, to: &results, controls: controls)
    }
}

public struct DefaultContainerReadinessChecker: ContainerReadinessChecking {
    private let sleeper: (TimeInterval) -> Void
    private let now: () -> Date

    public init(
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.sleeper = sleeper
        self.now = now
    }

    public func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: ContainerCommandExecutor
    ) -> AppleContainerReadinessResult {
        wait(for: requirement, executor: executor, controls: .init())
    }

    public func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: ContainerCommandExecutor,
        controls: AppleContainerExecutionControls
    ) -> AppleContainerReadinessResult {
        let startedAt = now()
        let timeout = TimeInterval(requirement.timeoutMilliseconds) / 1000
        let pollInterval = TimeInterval(requirement.pollIntervalMilliseconds) / 1000
        var attempts = 0
        var lastError: String?

        repeat {
            if controls.isCancelled() {
                return .init(
                    requirement: requirement,
                    status: .cancelled,
                    attempts: attempts,
                    durationMilliseconds: durationMilliseconds(since: startedAt),
                    error: "Readiness wait cancelled."
                )
            }

            attempts += 1
            do {
                let result = try executor.execute(arguments: ["inspect", requirement.containerName])
                if result.succeeded {
                    let state = AppleContainerInspectState(output: result.standardOutput)
                    if state.satisfies(requirement.condition) {
                        return .init(
                            requirement: requirement,
                            status: .ready,
                            attempts: attempts,
                            durationMilliseconds: durationMilliseconds(since: startedAt)
                        )
                    }
                    lastError = state.lastFailureDescription(for: requirement.condition)
                } else {
                    lastError = result.standardError.isEmpty ? "container inspect exited with \(result.exitCode)." : result.standardError
                }
            } catch {
                lastError = String(describing: error)
            }

            guard now().timeIntervalSince(startedAt) < timeout else { break }
            sleeper(pollInterval)
        } while true

        return .init(
            requirement: requirement,
            status: .timedOut,
            attempts: attempts,
            durationMilliseconds: durationMilliseconds(since: startedAt),
            error: lastError
        )
    }

    private func durationMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(now().timeIntervalSince(startedAt) * 1000))
    }
}

public struct DefaultAsyncContainerReadinessChecker: AsyncContainerReadinessChecking {
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date

    public init(
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { interval in
            let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sleeper = sleeper
        self.now = now
    }

    public func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: AsyncContainerCommandExecutor
    ) async -> AppleContainerReadinessResult {
        await wait(for: requirement, executor: executor, controls: .init())
    }

    public func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: AsyncContainerCommandExecutor,
        controls: AppleContainerExecutionControls
    ) async -> AppleContainerReadinessResult {
        let startedAt = now()
        let timeout = TimeInterval(requirement.timeoutMilliseconds) / 1000
        let pollInterval = TimeInterval(requirement.pollIntervalMilliseconds) / 1000
        var attempts = 0
        var lastError: String?

        repeat {
            if controls.isCancelled() {
                return .init(
                    requirement: requirement,
                    status: .cancelled,
                    attempts: attempts,
                    durationMilliseconds: durationMilliseconds(since: startedAt),
                    error: "Readiness wait cancelled."
                )
            }

            attempts += 1
            do {
                let result = try await executor.execute(arguments: ["inspect", requirement.containerName])
                if result.succeeded {
                    let state = AppleContainerInspectState(output: result.standardOutput)
                    if state.satisfies(requirement.condition) {
                        return .init(
                            requirement: requirement,
                            status: .ready,
                            attempts: attempts,
                            durationMilliseconds: durationMilliseconds(since: startedAt)
                        )
                    }
                    lastError = state.lastFailureDescription(for: requirement.condition)
                } else {
                    lastError = result.standardError.isEmpty ? "container inspect exited with \(result.exitCode)." : result.standardError
                }
            } catch {
                lastError = String(describing: error)
            }

            guard now().timeIntervalSince(startedAt) < timeout else { break }
            await sleeper(pollInterval)
        } while true

        return .init(
            requirement: requirement,
            status: .timedOut,
            attempts: attempts,
            durationMilliseconds: durationMilliseconds(since: startedAt),
            error: lastError
        )
    }

    private func durationMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(now().timeIntervalSince(startedAt) * 1000))
    }
}

private struct AppleContainerInspectState {
    private let value: Any?

    init(output: String) {
        guard let data = output.data(using: .utf8) else {
            value = nil
            return
        }
        value = try? JSONSerialization.jsonObject(with: data)
    }

    func satisfies(_ condition: AppleContainerReadinessCondition) -> Bool {
        switch condition {
        case .started:
            return boolValue(for: ["running", "isRunning"])
                ?? stringValue(for: ["status", "state", "phase"]).map(isStartedStatus)
                ?? (value != nil)
        case .healthy:
            return healthStatus().map { $0.lowercased() == "healthy" } ?? false
        case .completedSuccessfully:
            guard intValue(for: ["exitCode", "exit_code", "exitStatus"]) == 0 else { return false }
            return stringValue(for: ["status", "state", "phase"]).map(isCompletedStatus) ?? true
        }
    }

    func lastFailureDescription(for condition: AppleContainerReadinessCondition) -> String {
        switch condition {
        case .started:
            return "container is not started yet."
        case .healthy:
            return "container is not healthy yet."
        case .completedSuccessfully:
            return "container has not completed successfully yet."
        }
    }

    private func isStartedStatus(_ status: String) -> Bool {
        ["running", "started", "created"].contains(status.lowercased())
    }

    private func isCompletedStatus(_ status: String) -> Bool {
        ["exited", "stopped", "completed", "finished"].contains(status.lowercased())
    }

    private func boolValue(for keys: [String]) -> Bool? {
        firstValue(for: keys) as? Bool
    }

    private func intValue(for keys: [String]) -> Int? {
        if let int = firstValue(for: keys) as? Int {
            return int
        }
        if let number = firstValue(for: keys) as? NSNumber {
            return number.intValue
        }
        if let string = firstValue(for: keys) as? String {
            return Int(string)
        }
        return nil
    }

    private func stringValue(for keys: [String]) -> String? {
        firstValue(for: keys) as? String
    }

    private func healthStatus() -> String? {
        if let status = firstValue(for: ["healthStatus", "health_status"]) as? String {
            return status
        }
        if let health = firstValue(for: ["health"]) {
            if let string = health as? String {
                return string
            }
            if let dictionary = health as? [String: Any] {
                return dictionary["status"] as? String
                    ?? dictionary["Status"] as? String
                    ?? dictionary["healthStatus"] as? String
            }
        }
        return nil
    }

    private func firstValue(for keys: [String]) -> Any? {
        guard let value else { return nil }
        return firstValue(in: value, matching: Set(keys.map { $0.lowercased() }))
    }

    private func firstValue(in value: Any, matching keys: Set<String>) -> Any? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary where keys.contains(key.lowercased()) {
                return child
            }
            for child in dictionary.values {
                if let found = firstValue(in: child, matching: keys) {
                    return found
                }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let found = firstValue(in: child, matching: keys) {
                    return found
                }
            }
        }
        return nil
    }
}

public final class ContainerCLIPathResolver {
    private let knownContainerPaths: [String]
    private let pathEnvironment: () -> String?
    private let fileExists: (String) -> Bool
    private let isExecutable: (String) -> Bool

    public init(
        preferredContainerPaths: [String] = [
            "/usr/bin/container",
            "/usr/local/bin/container",
            "/opt/homebrew/bin/container",
            "/opt/local/bin/container"
        ],
        pathEnvironment: @escaping () -> String? = { ProcessInfo.processInfo.environment["PATH"] },
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.knownContainerPaths = preferredContainerPaths
        self.pathEnvironment = pathEnvironment
        self.fileExists = fileExists
        self.isExecutable = isExecutable
    }

    public func resolve() -> String? {
        for path in knownContainerPaths where isExecutablePath(path) {
            return path
        }

        guard let pathValue = pathEnvironment() else { return nil }
        let pathEntries = pathValue.split(separator: ":").map(String.init)

        for directory in pathEntries where !directory.isEmpty {
            if isExecutablePath("\(directory)/container") {
                return "\(directory)/container"
            }
        }

        return nil
    }

    private func isExecutablePath(_ path: String) -> Bool {
        fileExists(path) && isExecutable(path)
    }
}

public struct AppleContainerRuntimeProbe: AppleContainerRuntimeProbing {
    private let pathResolver: ContainerCLIPathResolver
    private let executor: ContainerCommandExecutor?

    public init(
        pathResolver: ContainerCLIPathResolver = .init(),
        executor: ContainerCommandExecutor? = nil
    ) {
        self.pathResolver = pathResolver
        self.executor = executor
    }

    public func probe() -> AppleContainerRuntimeStatus {
        guard let executablePath = pathResolver.resolve() else {
            return .init(
                executablePath: nil,
                availability: .unavailable,
                issues: [
                    .init(
                        code: .containerCLIUnavailable,
                        message: "Apple container CLI executable 'container' was not found in known install paths or PATH."
                    )
                ]
            )
        }

        let versionExecutor = executor ?? DefaultContainerCommandExecutor(pathResolver: pathResolver)
        do {
            let result = try versionExecutor.execute(arguments: ["--version"])
            let version = Self.versionString(stdout: result.standardOutput, stderr: result.standardError)
            if result.succeeded {
                return .init(
                    executablePath: executablePath,
                    availability: .available,
                    version: version,
                    issues: []
                )
            }
            return .init(
                executablePath: executablePath,
                availability: .unknown,
                version: version,
                issues: [
                    .init(
                        code: .versionCommandExitedNonZero,
                        severity: .warning,
                        message: Self.failureMessage(
                            prefix: "Apple container CLI version probe exited with \(result.exitCode).",
                            standardError: result.standardError
                        )
                    )
                ]
            )
        } catch {
            return .init(
                executablePath: executablePath,
                availability: .unknown,
                issues: [
                    .init(
                        code: .versionProbeFailed,
                        severity: .warning,
                        message: "Apple container CLI version probe failed: \(String(describing: error))"
                    )
                ]
            )
        }
    }

    private static func versionString(stdout: String, stderr: String) -> String? {
        let combined = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return combined
    }

    private static func failureMessage(prefix: String, standardError: String) -> String {
        let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return prefix }
        return "\(prefix) \(detail)"
    }
}

public final class DefaultContainerCommandExecutor: ContainerCommandExecutor {
    private let pathResolver: ContainerCLIPathResolver

    public init(pathResolver: ContainerCLIPathResolver = .init()) {
        self.pathResolver = pathResolver
    }

    public func execute(arguments: [String]) throws -> CommandExecutionResult {
        guard let executablePath = pathResolver.resolve() else {
            throw ContainerCommandExecutionError.containerCLIUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            throw ContainerCommandExecutionError.processFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let standardOutput = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        let standardError = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        let durationMilliseconds = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        return CommandExecutionResult(
            executablePath: executablePath,
            arguments: arguments,
            exitCode: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError,
            durationMilliseconds: durationMilliseconds
        )
    }
}
