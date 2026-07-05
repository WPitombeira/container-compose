import Foundation
import XCTest
@testable import ContainerComposeCore

final class ContainerRuntimeTests: XCTestCase {
    func testContainerCLIPathResolverPrefersContainerPathsBeforePATH() {
        let resolver = ContainerCLIPathResolver(
            preferredContainerPaths: [
                "/usr/bin/container",
                "/usr/local/bin/container",
                "/opt/homebrew/bin/container",
                "/opt/local/bin/container"
            ],
            pathEnvironment: { "/tmp/bin:/opt/local/bin" },
            fileExists: { path in
                return path == "/opt/homebrew/bin/container" || path == "/tmp/bin/container"
            },
            isExecutable: { path in
                return path == "/opt/homebrew/bin/container" || path == "/tmp/bin/container"
            }
        )

        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/container")
    }

    func testContainerCLIPathResolverFallsBackToPATHWhenKnownPathsMissing() {
        let resolver = ContainerCLIPathResolver(
            pathEnvironment: { "/tmp/bin:/usr/bin/bin:/opt/custom" },
            fileExists: { path in
                return path == "/opt/custom/container"
            },
            isExecutable: { path in
                return path == "/opt/custom/container"
            }
        )

        XCTAssertEqual(resolver.resolve(), "/opt/custom/container")
    }

    func testContainerCLIPathResolverReturnsNilWhenMissing() {
        let resolver = ContainerCLIPathResolver(
            pathEnvironment: { "/tmp/bin" },
            fileExists: { _ in false },
            isExecutable: { _ in false }
        )

        XCTAssertNil(resolver.resolve())
    }

    func testRuntimeProbeReportsUnavailableWhenContainerCLIMissing() {
        let resolver = ContainerCLIPathResolver(
            pathEnvironment: { nil },
            fileExists: { _ in false },
            isExecutable: { _ in false }
        )

        let status = AppleContainerRuntimeProbe(pathResolver: resolver).probe()

        XCTAssertEqual(status.schemaVersion, "1.0.0")
        XCTAssertEqual(status.runtime, "apple-container")
        XCTAssertEqual(status.executable, "container")
        XCTAssertNil(status.executablePath)
        XCTAssertEqual(status.availability, .unavailable)
        XCTAssertEqual(status.issues.map(\.code), [.containerCLIUnavailable])
    }

    func testRuntimeProbeCapturesExecutablePathAndVersion() {
        let resolver = ContainerCLIPathResolver(
            preferredContainerPaths: ["/opt/homebrew/bin/container"],
            pathEnvironment: { nil },
            fileExists: { $0 == "/opt/homebrew/bin/container" },
            isExecutable: { $0 == "/opt/homebrew/bin/container" }
        )
        let executor = FakeContainerCommandExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/opt/homebrew/bin/container",
                arguments: ["--version"],
                exitCode: 0,
                standardOutput: "container 1.2.3\n",
                standardError: ""
            ))
        ])

        let status = AppleContainerRuntimeProbe(pathResolver: resolver, executor: executor).probe()

        XCTAssertEqual(executor.calls, [["--version"]])
        XCTAssertEqual(status.executablePath, "/opt/homebrew/bin/container")
        XCTAssertEqual(status.availability, .available)
        XCTAssertEqual(status.version, "container 1.2.3")
        XCTAssertEqual(status.issues, [])
    }

    func testRuntimeProbeKeepsRuntimeUnknownWhenVersionProbeFails() {
        let resolver = ContainerCLIPathResolver(
            preferredContainerPaths: ["/usr/local/bin/container"],
            pathEnvironment: { nil },
            fileExists: { $0 == "/usr/local/bin/container" },
            isExecutable: { $0 == "/usr/local/bin/container" }
        )
        let executor = FakeContainerCommandExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/usr/local/bin/container",
                arguments: ["--version"],
                exitCode: 64,
                standardOutput: "",
                standardError: "unknown option\n"
            ))
        ])

        let status = AppleContainerRuntimeProbe(pathResolver: resolver, executor: executor).probe()

        XCTAssertEqual(status.availability, .unknown)
        XCTAssertEqual(status.issues.map(\.code), [.versionCommandExitedNonZero])
        XCTAssertEqual(status.issues.map(\.severity), [.warning])
    }

    func testExecutorRunsContainerWithArrayArguments() throws {
        let tempDirectory = try createTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let executablePath = tempDirectory.appendingPathComponent("container")
        try createContainerScript(at: executablePath, with: [
            "#!/bin/sh",
            "echo \"stdout:$1:$2\"",
            "echo \"stderr:$1:$2\" >&2",
            "exit 4"
        ].joined(separator: "\n"))

        let resolver = ContainerCLIPathResolver(
            preferredContainerPaths: [executablePath.path],
            fileExists: { $0 == executablePath.path },
            isExecutable: { $0 == executablePath.path }
        )

        let result = try DefaultContainerCommandExecutor(pathResolver: resolver)
            .execute(arguments: ["alpha", "beta"])

        XCTAssertEqual(result.executablePath, executablePath.path)
        XCTAssertEqual(result.arguments, ["alpha", "beta"])
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 4)
        XCTAssertEqual(result.standardOutput, "stdout:alpha:beta\n")
        XCTAssertEqual(result.standardError, "stderr:alpha:beta\n")
        XCTAssertGreaterThanOrEqual(result.durationMilliseconds, 0)
    }

    func testExecutorThrowsWhenCLIUnavailable() {
        let resolver = ContainerCLIPathResolver(
            pathEnvironment: { nil },
            fileExists: { _ in false },
            isExecutable: { _ in false }
        )

        XCTAssertThrowsError(try DefaultContainerCommandExecutor(pathResolver: resolver).execute(arguments: ["test"])) { error in
            XCTAssertEqual(error as? ContainerCommandExecutionError, .containerCLIUnavailable)
        }
    }

    func testExecutionRunnerDryRunPlansWithoutCallingExecutor() {
        let executor = FakeContainerCommandExecutor()
        let readinessChecker = FakeContainerReadinessChecker(results: [
            .init(
                requirement: .init(service: "db", containerName: "demo_db_1"),
                status: .ready
            )
        ])
        let plan = makePlan(commands: [
            PlannedCommand(action: .runService, service: "db", arguments: ["run", "--name", "demo_db_1", "postgres"]),
            PlannedCommand(action: .runService, service: "web", arguments: ["run", "--name", "demo_web_1", "nginx"])
        ], emitReadinessChecks: true)

        let report = AppleContainerExecutionRunner().run(
            plan: plan,
            dryRun: true,
            executor: executor,
            enforceReadiness: true,
            readinessChecker: readinessChecker
        )

        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertTrue(readinessChecker.requirements.isEmpty)
        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.results.map(\.status), [.planned, .planned])
        XCTAssertEqual(report.readinessResults, [])
        XCTAssertEqual(report.summary.total, 2)
        XCTAssertEqual(report.summary.succeeded, 2)
        XCTAssertEqual(report.summary.failed, 0)
        XCTAssertEqual(report.summary.skipped, 0)
    }

    func testExecutionRunnerCapturesSuccessfulCommandResults() {
        let executor = FakeContainerCommandExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["start", "demo_web_1"],
                exitCode: 0,
                standardOutput: "started\n",
                standardError: "",
                durationMilliseconds: 12
            ))
        ])
        let plan = makePlan(commands: [
            PlannedCommand(action: .startService, service: "web", arguments: ["start", "demo_web_1"])
        ])

        let report = AppleContainerExecutionRunner().run(plan: plan, dryRun: false, executor: executor)

        XCTAssertEqual(executor.calls, [["start", "demo_web_1"]])
        XCTAssertFalse(report.dryRun)
        XCTAssertEqual(report.results.first?.status, .executed)
        XCTAssertEqual(report.results.first?.standardOutput, "started\n")
        XCTAssertEqual(report.summary.succeeded, 1)
        XCTAssertEqual(report.summary.durationMilliseconds, 12)
    }

    func testExecutionRunnerMaterializesGeneratedFilesDuringCommand() throws {
        let tempDirectory = try createTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let dockerfileURL = tempDirectory
            .appendingPathComponent("generated")
            .appendingPathComponent("api.Dockerfile")
        let contents = "FROM scratch\nLABEL app=api\n"
        let command = PlannedCommand(
            action: .buildService,
            service: "api",
            arguments: ["build", "--file", dockerfileURL.path, "."],
            generatedFiles: [
                PlannedGeneratedFile(
                    kind: .inlineDockerfile,
                    path: dockerfileURL.path,
                    contents: contents,
                    diagnosticsPath: "services.api.build.dockerfile_inline"
                )
            ]
        )
        let executor = FakeContainerCommandExecutor(
            results: [
                .success(CommandExecutionResult(
                    executablePath: "/usr/bin/container",
                    arguments: command.arguments,
                    exitCode: 0,
                    standardOutput: "built\n",
                    standardError: ""
                ))
            ],
            onExecute: { _ in
                XCTAssertTrue(FileManager.default.fileExists(atPath: dockerfileURL.path))
                XCTAssertEqual(try String(contentsOf: dockerfileURL, encoding: .utf8), contents)
            }
        )

        let report = AppleContainerExecutionRunner().run(
            plan: makePlan(commands: [command]),
            dryRun: false,
            executor: executor
        )

        XCTAssertEqual(executor.calls, [command.arguments])
        XCTAssertEqual(report.results.map(\.status), [.executed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dockerfileURL.path))
    }

    func testExecutionRunnerWaitsForReadinessBeforeDependentCommands() {
        let executor = FakeContainerCommandExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["run", "--name", "demo_db_1", "postgres"],
                exitCode: 0,
                standardOutput: "db\n",
                standardError: ""
            )),
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["run", "--name", "demo_web_1", "nginx"],
                exitCode: 0,
                standardOutput: "web\n",
                standardError: ""
            ))
        ])
        let readinessChecker = FakeContainerReadinessChecker(results: [
            .init(
                requirement: .init(service: "db", condition: .healthy, containerName: "demo_db_1"),
                status: .ready,
                attempts: 2
            )
        ])
        let plan = makePlan(commands: [
            PlannedCommand(action: .runService, service: "db", arguments: ["run", "--name", "demo_db_1", "postgres"]),
            PlannedCommand(action: .runService, service: "web", arguments: ["run", "--name", "demo_web_1", "nginx"])
        ], dependencyCondition: .serviceHealthy, emitReadinessChecks: true)

        let report = AppleContainerExecutionRunner().run(
            plan: plan,
            dryRun: false,
            executor: executor,
            enforceReadiness: true,
            readinessChecker: readinessChecker
        )

        XCTAssertEqual(executor.calls, [
            ["run", "--name", "demo_db_1", "postgres"],
            ["run", "--name", "demo_web_1", "nginx"]
        ])
        XCTAssertEqual(readinessChecker.requirements.map(\.containerName), ["demo_db_1"])
        XCTAssertEqual(report.readinessResults.map(\.commandIndex), [1])
        XCTAssertEqual(report.readinessResults.map(\.status), [.ready])
        XCTAssertEqual(report.results.map(\.status), [.executed, .executed])
    }

    func testAsyncExecutionRunnerWaitsForReadinessBeforeDependentCommands() async {
        let executor = FakeAsyncContainerCommandExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["run", "--name", "demo_db_1", "postgres"],
                exitCode: 0,
                standardOutput: "db\n",
                standardError: ""
            )),
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["run", "--name", "demo_web_1", "nginx"],
                exitCode: 0,
                standardOutput: "web\n",
                standardError: ""
            ))
        ])
        let readinessChecker = FakeAsyncContainerReadinessChecker(results: [
            .init(
                requirement: .init(service: "db", condition: .healthy, containerName: "demo_db_1"),
                status: .ready,
                attempts: 2
            )
        ])
        let plan = makePlan(commands: [
            PlannedCommand(action: .runService, service: "db", arguments: ["run", "--name", "demo_db_1", "postgres"]),
            PlannedCommand(action: .runService, service: "web", arguments: ["run", "--name", "demo_web_1", "nginx"])
        ], dependencyCondition: .serviceHealthy, emitReadinessChecks: true)

        let report = await AppleContainerExecutionRunner().run(
            plan: plan,
            dryRun: false,
            executor: executor,
            enforceReadiness: true,
            readinessChecker: readinessChecker
        )

        XCTAssertEqual(executor.calls, [
            ["run", "--name", "demo_db_1", "postgres"],
            ["run", "--name", "demo_web_1", "nginx"]
        ])
        XCTAssertEqual(readinessChecker.requirements.map(\.containerName), ["demo_db_1"])
        XCTAssertEqual(report.readinessResults.map(\.commandIndex), [1])
        XCTAssertEqual(report.readinessResults.map(\.status), [.ready])
        XCTAssertEqual(report.results.map(\.status), [.executed, .executed])
    }

    func testDefaultAsyncReadinessCheckerUsesAsyncInspect() async {
        let executor = FakeAsyncContainerCommandExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["inspect", "demo_db_1"],
                exitCode: 0,
                standardOutput: #"{"running":true}"#,
                standardError: ""
            ))
        ])
        let checker = DefaultAsyncContainerReadinessChecker(sleeper: { _ in })

        let result = await checker.wait(
            for: .init(service: "db", condition: .started, containerName: "demo_db_1"),
            executor: executor
        )

        XCTAssertEqual(executor.calls, [["inspect", "demo_db_1"]])
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.attempts, 1)
    }

    func testExecutionRunnerStopsWhenReadinessFailsAndSkipsRemainingCommands() {
        let executor = FakeContainerCommandExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["run", "--name", "demo_db_1", "postgres"],
                exitCode: 0,
                standardOutput: "",
                standardError: ""
            ))
        ])
        let readinessChecker = FakeContainerReadinessChecker(results: [
            .init(
                requirement: .init(service: "db", condition: .healthy, containerName: "demo_db_1"),
                status: .timedOut,
                attempts: 3,
                error: "container is not healthy yet."
            )
        ])
        let plan = makePlan(commands: [
            PlannedCommand(action: .runService, service: "db", arguments: ["run", "--name", "demo_db_1", "postgres"]),
            PlannedCommand(action: .runService, service: "web", arguments: ["run", "--name", "demo_web_1", "nginx"]),
            PlannedCommand(action: .runService, service: "worker", arguments: ["run", "--name", "demo_worker_1", "busybox"])
        ], dependencyCondition: .serviceHealthy, emitReadinessChecks: true)

        let report = AppleContainerExecutionRunner().run(
            plan: plan,
            dryRun: false,
            executor: executor,
            enforceReadiness: true,
            readinessChecker: readinessChecker
        )

        XCTAssertEqual(executor.calls, [["run", "--name", "demo_db_1", "postgres"]])
        XCTAssertEqual(report.readinessResults.map(\.status), [.timedOut])
        XCTAssertEqual(report.results.map(\.status), [.executed, .failed, .skipped])
        XCTAssertEqual(report.results[1].errorCode, .readinessTimedOut)
        XCTAssertEqual(report.results[2].errorCode, .skippedPreviousFailure)
        XCTAssertTrue(report.results[1].error?.contains("Readiness check timedOut") == true)
        XCTAssertEqual(report.summary.succeeded, 1)
        XCTAssertEqual(report.summary.failed, 1)
        XCTAssertEqual(report.summary.skipped, 1)
    }

    func testExecutionRunnerReportsCancelledWhenReadinessWaitIsCancelled() {
        let executor = FakeContainerCommandExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["run", "--name", "demo_db_1", "postgres"],
                exitCode: 0,
                standardOutput: "",
                standardError: ""
            ))
        ])
        let readinessChecker = FakeContainerReadinessChecker(results: [
            .init(
                requirement: .init(service: "db", condition: .healthy, containerName: "demo_db_1"),
                status: .cancelled,
                error: "Readiness wait cancelled."
            )
        ])
        let plan = makePlan(commands: [
            PlannedCommand(action: .runService, service: "db", arguments: ["run", "--name", "demo_db_1", "postgres"]),
            PlannedCommand(action: .runService, service: "web", arguments: ["run", "--name", "demo_web_1", "nginx"])
        ], dependencyCondition: .serviceHealthy, emitReadinessChecks: true)

        let report = AppleContainerExecutionRunner().run(
            plan: plan,
            dryRun: false,
            executor: executor,
            enforceReadiness: true,
            readinessChecker: readinessChecker
        )

        XCTAssertEqual(report.readinessResults.map(\.status), [.cancelled])
        XCTAssertEqual(report.results.map(\.status), [.executed, .cancelled])
        XCTAssertEqual(report.results[1].errorCode, .readinessCancelled)
        XCTAssertEqual(report.summary.cancelled, 1)
        XCTAssertTrue(report.results[1].error?.contains("Readiness check cancelled") == true)
    }

    func testExecutionRunnerStopsAfterFailureAndMarksRemainingCommandsSkipped() {
        let executor = FakeContainerCommandExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["start", "demo_db_1"],
                exitCode: 0,
                standardOutput: "",
                standardError: ""
            )),
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["start", "demo_web_1"],
                exitCode: 2,
                standardOutput: "",
                standardError: "failed\n"
            ))
        ])
        let plan = makePlan(commands: [
            PlannedCommand(action: .startService, service: "db", arguments: ["start", "demo_db_1"]),
            PlannedCommand(action: .startService, service: "web", arguments: ["start", "demo_web_1"]),
            PlannedCommand(action: .startService, service: "worker", arguments: ["start", "demo_worker_1"])
        ])

        let report = AppleContainerExecutionRunner().run(plan: plan, dryRun: false, executor: executor)

        XCTAssertEqual(executor.calls, [["start", "demo_db_1"], ["start", "demo_web_1"]])
        XCTAssertEqual(report.results.map(\.status), [.executed, .failed, .skipped])
        XCTAssertEqual(report.results[1].exitCode, 2)
        XCTAssertEqual(report.results[1].standardError, "failed\n")
        XCTAssertEqual(report.results[1].errorCode, .nonZeroExit)
        XCTAssertEqual(report.results[1].error, "failed")
        XCTAssertEqual(report.results[2].errorCode, .skippedPreviousFailure)
        XCTAssertEqual(report.summary.succeeded, 1)
        XCTAssertEqual(report.summary.failed, 1)
        XCTAssertEqual(report.summary.skipped, 1)
    }

    func testExecutionRunnerFailsDelegatedProviderCommandsWithoutCallingExecutor() {
        let executor = FakeContainerCommandExecutor()
        let plan = makePlan(commands: [
            PlannedCommand(
                action: .delegateService,
                service: "db",
                arguments: ["compose-provider", "run", "db", "awesomecloud"]
            ),
            PlannedCommand(action: .runService, service: "web", arguments: ["run", "--name", "demo_web_1", "nginx"])
        ])

        let report = AppleContainerExecutionRunner().run(plan: plan, dryRun: false, executor: executor)

        XCTAssertEqual(executor.calls, [])
        XCTAssertEqual(report.results.map(\.status), [.failed, .skipped])
        XCTAssertEqual(report.results[0].errorCode, .unsupportedPlanAction)
        XCTAssertEqual(report.results[0].error, "Planned action delegateService is not executable through Apple Container yet.")
        XCTAssertEqual(report.results[1].errorCode, .skippedPreviousFailure)
        XCTAssertEqual(report.summary.failed, 1)
        XCTAssertEqual(report.summary.skipped, 1)
    }

    func testExecutionRunnerFailsPauseCommandsWithoutCallingExecutor() {
        let executor = FakeContainerCommandExecutor()
        let plan = makePlan(commands: [
            PlannedCommand(action: .pauseService, service: "web", arguments: ["pause", "demo_web_1"]),
            PlannedCommand(action: .startService, service: "worker", arguments: ["start", "demo_worker_1"])
        ])

        let report = AppleContainerExecutionRunner().run(plan: plan, dryRun: false, executor: executor)

        XCTAssertEqual(executor.calls, [])
        XCTAssertEqual(report.results.map(\.status), [.failed, .skipped])
        XCTAssertEqual(report.results[0].errorCode, .unsupportedPlanAction)
        XCTAssertEqual(report.results[0].error, "Planned action pauseService is not executable through Apple Container yet.")
        XCTAssertEqual(report.results[1].errorCode, .skippedPreviousFailure)
    }

    func testExecutionRunnerFailsUnpauseCommandsWithoutCallingExecutor() {
        let executor = FakeContainerCommandExecutor()
        let plan = makePlan(commands: [
            PlannedCommand(action: .unpauseService, service: "web", arguments: ["unpause", "demo_web_1"]),
            PlannedCommand(action: .startService, service: "worker", arguments: ["start", "demo_worker_1"])
        ])

        let report = AppleContainerExecutionRunner().run(plan: plan, dryRun: false, executor: executor)

        XCTAssertEqual(executor.calls, [])
        XCTAssertEqual(report.results.map(\.status), [.failed, .skipped])
        XCTAssertEqual(report.results[0].errorCode, .unsupportedPlanAction)
        XCTAssertEqual(report.results[0].error, "Planned action unpauseService is not executable through Apple Container yet.")
        XCTAssertEqual(report.results[1].errorCode, .skippedPreviousFailure)
    }

    func testExecutionRunnerMapsThrownExecutorErrorToStableErrorCode() {
        let executor = FakeContainerCommandExecutor(results: [
            .failure(ContainerCommandExecutionError.containerCLIUnavailable)
        ])
        let plan = makePlan(commands: [
            PlannedCommand(action: .startService, service: "web", arguments: ["start", "demo_web_1"]),
            PlannedCommand(action: .startService, service: "worker", arguments: ["start", "demo_worker_1"])
        ])

        let report = AppleContainerExecutionRunner().run(plan: plan, dryRun: false, executor: executor)

        XCTAssertEqual(report.results.map(\.status), [.failed, .skipped])
        XCTAssertEqual(report.results[0].errorCode, .containerCLIUnavailable)
        XCTAssertEqual(report.results[1].errorCode, .skippedPreviousFailure)
        XCTAssertEqual(report.summary.failed, 1)
        XCTAssertEqual(report.summary.skipped, 1)
    }

    func testExecutionRunnerStopsBeforeExecutorWhenRuntimeStatusIsUnavailable() {
        let executor = FakeContainerCommandExecutor()
        var plan = makePlan(commands: [
            PlannedCommand(action: .startService, service: "web", arguments: ["start", "demo_web_1"]),
            PlannedCommand(action: .startService, service: "worker", arguments: ["start", "demo_worker_1"])
        ])
        plan.runtimeStatus = AppleContainerRuntimeStatus(
            executablePath: nil,
            availability: .unavailable,
            issues: [
                .init(
                    code: .containerCLIUnavailable,
                    message: "Apple container CLI executable 'container' was not found."
                )
            ]
        )

        let report = AppleContainerExecutionRunner().run(plan: plan, dryRun: false, executor: executor)

        XCTAssertEqual(executor.calls, [])
        XCTAssertEqual(report.runtimeStatus, plan.runtimeStatus)
        XCTAssertEqual(report.results.map(\.status), [.failed, .skipped])
        XCTAssertEqual(report.results[0].errorCode, .containerCLIUnavailable)
        XCTAssertEqual(report.results[0].error, "Apple container CLI executable 'container' was not found.")
        XCTAssertEqual(report.results[1].errorCode, .skippedPreviousFailure)
        XCTAssertEqual(report.summary.failed, 1)
        XCTAssertEqual(report.summary.skipped, 1)
    }

    func testExecutionReportRoundTripsAsJSON() throws {
        let plan = makePlan(commands: [
            PlannedCommand(action: .stopService, service: "web", arguments: ["stop", "demo_web_1"])
        ])
        let report = AppleContainerExecutionRunner().run(
            plan: plan,
            dryRun: true,
            executor: FakeContainerCommandExecutor()
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(AppleContainerExecutionReport.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, "1.8.0")
        XCTAssertEqual(decoded.projectName, "demo")
        XCTAssertEqual(decoded.runtime, "apple-container")
        XCTAssertEqual(decoded.executable, "container")
        XCTAssertNil(decoded.runtimeStatus)
        XCTAssertEqual(decoded.operation, "up")
        XCTAssertEqual(decoded.selectedServices, [])
        XCTAssertEqual(decoded.executionGraph?.nodes.count, 1)
        XCTAssertEqual(decoded.results.first?.command.arguments, ["stop", "demo_web_1"])
    }

    func testExecutionReportCarriesRuntimeStatus() throws {
        let runtimeStatus = AppleContainerRuntimeStatus(
            executablePath: "/opt/homebrew/bin/container",
            availability: .available,
            version: "container 1.2.3"
        )
        var plan = makePlan(commands: [
            PlannedCommand(action: .stopService, service: "web", arguments: ["stop", "demo_web_1"])
        ])
        plan.runtimeStatus = runtimeStatus

        let report = AppleContainerExecutionRunner().run(
            plan: plan,
            dryRun: true,
            executor: FakeContainerCommandExecutor()
        )

        XCTAssertEqual(report.runtimeStatus, runtimeStatus)
    }

    func testExecutionReportDecodesOlderJSONWithoutSelectedServices() throws {
        let json = """
        {
          "schemaVersion": "1.2.0",
          "projectName": "demo",
          "sourcePath": "/tmp/demo/compose.yaml",
          "runtime": "apple-container",
          "executable": "container",
          "operation": "up",
          "dryRun": true,
          "diagnostics": [],
          "results": [],
          "summary": {
            "total": 0,
            "succeeded": 0,
            "failed": 0,
            "skipped": 0,
            "durationMilliseconds": 0
          }
        }
        """

        let decoded = try JSONDecoder().decode(AppleContainerExecutionReport.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.selectedServices, [])
        XCTAssertNil(decoded.executionGraph)
        XCTAssertEqual(decoded.readinessResults, [])
        XCTAssertEqual(decoded.summary.cancelled, 0)
    }

    func testExecutionRunnerEmitsProgressEventsAroundReadinessAndCommands() {
        let recorder = RuntimeEventRecorder()
        let executor = FakeContainerCommandExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["run", "--name", "demo_db_1", "postgres"],
                exitCode: 0,
                standardOutput: "db\n",
                standardError: ""
            )),
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["run", "--name", "demo_web_1", "nginx"],
                exitCode: 0,
                standardOutput: "web\n",
                standardError: ""
            ))
        ])
        let readinessChecker = FakeContainerReadinessChecker(results: [
            .init(
                requirement: .init(service: "db", condition: .healthy, containerName: "demo_db_1"),
                status: .ready
            )
        ])
        let plan = makePlan(commands: [
            PlannedCommand(action: .runService, service: "db", arguments: ["run", "--name", "demo_db_1", "postgres"]),
            PlannedCommand(action: .runService, service: "web", arguments: ["run", "--name", "demo_web_1", "nginx"])
        ], dependencyCondition: .serviceHealthy, emitReadinessChecks: true)

        let report = AppleContainerExecutionRunner().run(
            plan: plan,
            dryRun: false,
            executor: executor,
            enforceReadiness: true,
            readinessChecker: readinessChecker,
            controls: .init(progress: { recorder.events.append($0) })
        )

        XCTAssertEqual(report.results.map(\.status), [.executed, .executed])
        XCTAssertEqual(recorder.commandStartedIndexes, [0, 1])
        XCTAssertEqual(recorder.readinessStartedContainerNames, ["demo_db_1"])
        XCTAssertEqual(recorder.readinessFinishedStatuses, [.ready])
        XCTAssertEqual(recorder.commandFinishedStatuses, [.executed, .executed])
    }

    func testExecutionRunnerCanCancelBeforeNextCommandAndSkipRemainingCommands() {
        let recorder = RuntimeEventRecorder()
        let executor = FakeContainerCommandExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/usr/bin/container",
                arguments: ["start", "demo_db_1"],
                exitCode: 0,
                standardOutput: "",
                standardError: ""
            ))
        ])
        let plan = makePlan(commands: [
            PlannedCommand(action: .startService, service: "db", arguments: ["start", "demo_db_1"]),
            PlannedCommand(action: .startService, service: "web", arguments: ["start", "demo_web_1"]),
            PlannedCommand(action: .startService, service: "worker", arguments: ["start", "demo_worker_1"])
        ])

        let report = AppleContainerExecutionRunner().run(
            plan: plan,
            dryRun: false,
            executor: executor,
            controls: .init(
                isCancelled: { recorder.cancelled },
                progress: { event in
                    recorder.events.append(event)
                    if case .commandFinished(let execution) = event, execution.commandIndex == 0 {
                        recorder.cancelled = true
                    }
                }
            )
        )

        XCTAssertEqual(executor.calls, [["start", "demo_db_1"]])
        XCTAssertEqual(report.results.map(\.status), [.executed, .cancelled, .skipped])
        XCTAssertEqual(report.summary.cancelled, 1)
        XCTAssertEqual(report.summary.skipped, 1)
        XCTAssertEqual(recorder.commandCancelledIndexes, [1])
        XCTAssertEqual(recorder.commandSkippedIndexes, [2])
    }

    func testDefaultReadinessCheckerCanBeCancelledBeforeInspecting() {
        let executor = FakeContainerCommandExecutor()
        let checker = DefaultContainerReadinessChecker(sleeper: { _ in })

        let result = checker.wait(
            for: .init(service: "db", condition: .healthy, containerName: "demo_db_1"),
            executor: executor,
            controls: .init(isCancelled: { true })
        )

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.attempts, 0)
        XCTAssertEqual(executor.calls, [])
    }

    private func createTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ContainerComposeCore-ContainerRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func createContainerScript(at url: URL, with script: String) throws {
        let attributes = [FileAttributeKey.posixPermissions: 0o755]
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: script.data(using: .utf8),
            attributes: attributes
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func makePlan(
        commands: [PlannedCommand],
        dependencyCondition: ComposeDependencyCondition = .serviceStarted,
        emitReadinessChecks: Bool = false
    ) -> AppleContainerPlan {
        let project = ComposeProject(
            name: "demo",
            services: [
                ComposeService(name: "db", image: "postgres"),
                ComposeService(
                    name: "web",
                    image: "nginx",
                    dependsOn: ["db"],
                    dependsOnMetadata: [
                        "db": .init(condition: dependencyCondition)
                    ]
                ),
                ComposeService(name: "worker", image: "busybox")
            ],
            sourcePath: "/tmp/demo/compose.yaml"
        )
        return AppleContainerPlan(
            project: project,
            operation: "up",
            commands: commands,
            emitReadinessChecks: emitReadinessChecks
        )
    }
}

private final class FakeContainerCommandExecutor: ContainerCommandExecutor {
    var calls: [[String]] = []
    private var results: [Result<CommandExecutionResult, Error>]
    private let onExecute: (([String]) throws -> Void)?

    init(
        results: [Result<CommandExecutionResult, Error>] = [],
        onExecute: (([String]) throws -> Void)? = nil
    ) {
        self.results = results
        self.onExecute = onExecute
    }

    func execute(arguments: [String]) throws -> CommandExecutionResult {
        calls.append(arguments)
        try onExecute?(arguments)
        guard !results.isEmpty else {
            throw ContainerCommandExecutionError.processFailed("unexpected call")
        }
        switch results.removeFirst() {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

private final class FakeAsyncContainerCommandExecutor: AsyncContainerCommandExecutor {
    var calls: [[String]] = []
    private var results: [Result<CommandExecutionResult, Error>]

    init(results: [Result<CommandExecutionResult, Error>] = []) {
        self.results = results
    }

    func execute(arguments: [String]) async throws -> CommandExecutionResult {
        calls.append(arguments)
        guard !results.isEmpty else {
            throw ContainerCommandExecutionError.processFailed("unexpected call")
        }
        switch results.removeFirst() {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

private final class FakeContainerReadinessChecker: ContainerReadinessChecking {
    var requirements: [AppleContainerReadinessRequirement] = []
    private var results: [AppleContainerReadinessResult]

    init(results: [AppleContainerReadinessResult]) {
        self.results = results
    }

    func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: ContainerCommandExecutor
    ) -> AppleContainerReadinessResult {
        requirements.append(requirement)
        guard !results.isEmpty else {
            return .init(
                requirement: requirement,
                status: .failed,
                error: "unexpected readiness call"
            )
        }
        var result = results.removeFirst()
        result.requirement = requirement
        return result
    }
}

private final class FakeAsyncContainerReadinessChecker: AsyncContainerReadinessChecking {
    var requirements: [AppleContainerReadinessRequirement] = []
    private var results: [AppleContainerReadinessResult]

    init(results: [AppleContainerReadinessResult]) {
        self.results = results
    }

    func wait(
        for requirement: AppleContainerReadinessRequirement,
        executor: AsyncContainerCommandExecutor
    ) async -> AppleContainerReadinessResult {
        requirements.append(requirement)
        guard !results.isEmpty else {
            return .init(
                requirement: requirement,
                status: .failed,
                error: "unexpected readiness call"
            )
        }
        var result = results.removeFirst()
        result.requirement = requirement
        return result
    }
}

private final class RuntimeEventRecorder: @unchecked Sendable {
    var events: [AppleContainerExecutionEvent] = []
    var cancelled = false

    var commandStartedIndexes: [Int] {
        events.compactMap { event in
            if case .commandStarted(let commandIndex, _) = event {
                return commandIndex
            }
            return nil
        }
    }

    var commandFinishedStatuses: [PlannedCommandExecutionStatus] {
        events.compactMap { event in
            if case .commandFinished(let execution) = event {
                return execution.status
            }
            return nil
        }
    }

    var commandCancelledIndexes: [Int] {
        events.compactMap { event in
            if case .commandCancelled(let execution) = event {
                return execution.commandIndex
            }
            return nil
        }
    }

    var commandSkippedIndexes: [Int] {
        events.compactMap { event in
            if case .commandSkipped(let execution) = event {
                return execution.commandIndex
            }
            return nil
        }
    }

    var readinessStartedContainerNames: [String] {
        events.compactMap { event in
            if case .readinessStarted(_, let requirement) = event {
                return requirement.containerName
            }
            return nil
        }
    }

    var readinessFinishedStatuses: [AppleContainerReadinessStatus] {
        events.compactMap { event in
            if case .readinessFinished(let result) = event {
                return result.status
            }
            return nil
        }
    }
}
