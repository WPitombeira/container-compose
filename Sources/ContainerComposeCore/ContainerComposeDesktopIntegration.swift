import Foundation

public struct ContainerComposeDesktopSnapshot: Codable, Equatable, Sendable {
    public var project: ComposeProject
    public var plan: AppleContainerPlan
    public var report: AppleContainerExecutionReport?
    public var runtimeStatus: AppleContainerRuntimeStatus?
    public var commands: [ContainerComposeDesktopCommandPreview]
    public var diagnostics: [ComposeDiagnostic]
    public var readinessResults: [AppleContainerReadinessResult]

    public init(
        project: ComposeProject,
        plan: AppleContainerPlan,
        report: AppleContainerExecutionReport? = nil
    ) {
        self.project = project
        self.plan = plan
        self.report = report
        runtimeStatus = report?.runtimeStatus ?? plan.runtimeStatus
        commands = Self.commandPreviews(plan: plan, report: report)
        diagnostics = plan.diagnostics
        readinessResults = report?.readinessResults ?? []
    }

    private static func commandPreviews(
        plan: AppleContainerPlan,
        report: AppleContainerExecutionReport?
    ) -> [ContainerComposeDesktopCommandPreview] {
        let graphNodes = Dictionary(uniqueKeysWithValues: (plan.executionGraph?.nodes ?? []).map { ($0.commandIndex, $0) })
        let executions = Dictionary(uniqueKeysWithValues: (report?.results ?? []).map { ($0.commandIndex, $0) })
        return plan.commands.enumerated().map { index, command in
            ContainerComposeDesktopCommandPreview(
                commandIndex: index,
                command: command,
                displayCommand: ContainerComposeDisplayCommandFormatter.displayCommand(
                    executable: plan.executable,
                    arguments: command.arguments
                ),
                dependsOnCommandIndexes: graphNodes[index]?.dependsOnCommandIndexes ?? [],
                readiness: graphNodes[index]?.readiness ?? [],
                execution: executions[index]
            )
        }
    }
}

public struct ContainerComposeDesktopCommandPreview: Codable, Equatable, Sendable {
    public var commandIndex: Int
    public var action: PlanAction
    public var service: String?
    public var arguments: [String]
    public var displayCommand: String
    public var diagnostics: [ComposeDiagnostic]
    public var generatedFiles: [PlannedGeneratedFile]
    public var dependsOnCommandIndexes: [Int]
    public var readiness: [AppleContainerReadinessRequirement]
    public var execution: PlannedCommandExecution?

    public init(
        commandIndex: Int,
        command: PlannedCommand,
        displayCommand: String,
        dependsOnCommandIndexes: [Int] = [],
        readiness: [AppleContainerReadinessRequirement] = [],
        execution: PlannedCommandExecution? = nil
    ) {
        self.commandIndex = commandIndex
        action = command.action
        service = command.service
        arguments = command.arguments
        self.displayCommand = displayCommand
        diagnostics = command.diagnostics
        generatedFiles = command.generatedFiles
        self.dependsOnCommandIndexes = dependsOnCommandIndexes
        self.readiness = readiness
        self.execution = execution
    }

    private enum CodingKeys: String, CodingKey {
        case commandIndex
        case action
        case service
        case arguments
        case displayCommand
        case diagnostics
        case generatedFiles
        case dependsOnCommandIndexes
        case readiness
        case execution
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case commandIndex = "command_index"
        case displayCommand = "display_command"
        case dependsOnCommandIndexes = "depends_on_command_indexes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        commandIndex = try container.decodeIfPresent(Int.self, forKey: .commandIndex)
            ?? legacyContainer.decode(Int.self, forKey: .commandIndex)
        action = try container.decode(PlanAction.self, forKey: .action)
        service = try container.decodeIfPresent(String.self, forKey: .service)
        arguments = try container.decode([String].self, forKey: .arguments)
        displayCommand = try container.decodeIfPresent(String.self, forKey: .displayCommand)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .displayCommand)
            ?? ContainerComposeDisplayCommandFormatter.displayCommand(executable: "container", arguments: arguments)
        diagnostics = try container.decodeIfPresent([ComposeDiagnostic].self, forKey: .diagnostics) ?? []
        generatedFiles = try container.decodeIfPresent([PlannedGeneratedFile].self, forKey: .generatedFiles) ?? []
        dependsOnCommandIndexes = try container.decodeIfPresent([Int].self, forKey: .dependsOnCommandIndexes)
            ?? legacyContainer.decodeIfPresent([Int].self, forKey: .dependsOnCommandIndexes)
            ?? []
        readiness = try container.decodeIfPresent([AppleContainerReadinessRequirement].self, forKey: .readiness) ?? []
        execution = try container.decodeIfPresent(PlannedCommandExecution.self, forKey: .execution)
    }
}

public enum ContainerComposeDisplayCommandFormatter {
    public static func displayCommand(executable: String, arguments: [String]) -> String {
        shellEscaped([executable] + arguments)
    }

    public static func shellEscaped(_ arguments: [String]) -> String {
        arguments.map { argument in
            if argument.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "'\""))) == nil {
                return argument
            }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

public extension ContainerComposeService {
    func makeDesktopSnapshot(_ request: ContainerComposePlanRequest) throws -> ContainerComposeDesktopSnapshot {
        let result = try makePlan(request)
        return ContainerComposeDesktopSnapshot(project: result.project, plan: result.plan)
    }

    func dryRunDesktopSnapshot(_ request: ContainerComposePlanRequest) throws -> ContainerComposeDesktopSnapshot {
        let result = try makePlan(request)
        let report = execute(plan: result.plan, dryRun: true, executor: DesktopSnapshotNoopContainerCommandExecutor())
        return ContainerComposeDesktopSnapshot(project: result.project, plan: result.plan, report: report)
    }
}

private struct DesktopSnapshotNoopContainerCommandExecutor: ContainerCommandExecutor {
    func execute(arguments: [String]) throws -> CommandExecutionResult {
        throw ContainerCommandExecutionError.processFailed("dry-run executor should not be called")
    }
}
