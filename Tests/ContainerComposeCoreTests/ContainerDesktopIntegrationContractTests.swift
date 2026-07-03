import XCTest
@testable import ContainerComposeCore

final class ContainerDesktopIntegrationContractTests: XCTestCase {
    func testDesktopSnippetSnapshotUsesInMemoryComposeYAML() throws {
        let snapshot = try ContainerComposeService().dryRunDesktopSnapshot(.init(
            operation: .up,
            composeYAML: """
            services:
              api:
                image: example/api:dev
              web:
                image: nginx:alpine
                depends_on:
                  api:
                    condition: service_started
            """,
            projectDirectory: "/tmp/container-desktop-paste",
            projectName: "desktop-paste",
            emitReadinessChecks: true
        ))

        XCTAssertEqual(snapshot.project.sourcePath, "/tmp/container-desktop-paste/compose.yaml")
        XCTAssertEqual(snapshot.project.services.map(\.name), ["api", "web"])
        XCTAssertEqual(snapshot.commands.map(\.displayCommand), [
            "container network create desktop-paste_default",
            "container run --name desktop-paste_api_1 --detach --network desktop-paste_default example/api:dev",
            "container run --name desktop-paste_web_1 --detach --network desktop-paste_default nginx:alpine"
        ])
        XCTAssertEqual(snapshot.commands.map(\.execution?.status), [.planned, .planned, .planned])
        XCTAssertEqual(snapshot.commands[2].dependsOnCommandIndexes, [1])
        XCTAssertEqual(snapshot.commands[2].readiness.map(\.containerName), ["desktop-paste_api_1"])
        XCTAssertEqual(snapshot.report?.dryRun, true)
    }

    func testDesktopPlanEnvelopePreservesPlanAndConfigOperationNames() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let service = ContainerComposeService()
        let planResult = try service.makePlan(.init(
            operation: .plan,
            projectDirectory: workdir.path
        ))
        let configResult = try service.makePlan(.init(
            operation: .config,
            projectDirectory: workdir.path
        ))

        XCTAssertEqual(planResult.plan.operation, "plan")
        XCTAssertEqual(planResult.plan.commands.map(\.action), [.createNetwork, .runService])
        XCTAssertEqual(configResult.plan.operation, "config")
        XCTAssertEqual(configResult.plan.commands, [])
    }

    func testDesktopSnapshotCarriesRemoteProvenanceGeneratedFilesReadinessAndDryRunExecutions() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        include:
          - https://example.test/shared/compose.yaml
        services:
          web:
            image: nginx:alpine
            depends_on:
              api:
                condition: service_started
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let remoteYAML = """
        services:
          api:
            image: example/api:dev
            build:
              context: .
              dockerfile_inline: |
                FROM scratch
                LABEL app=api
        """
        let service = ContainerComposeService(remoteIncludeResolver: { request in
            XCTAssertEqual(request.sanitizedURL, "https://example.test/shared/compose.yaml")
            XCTAssertEqual(request.includedFrom, workdir.appendingPathComponent("compose.yaml").path)
            XCTAssertEqual(request.includeStack, [workdir.appendingPathComponent("compose.yaml").path])
            return ComposeLoader.RemoteIncludeResponse(
                yaml: remoteYAML,
                cacheKey: "desktop-cache:shared-compose",
                cacheStatus: .hit,
                source: "container-desktop-cache"
            )
        })

        let snapshot = try service.dryRunDesktopSnapshot(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-contract",
            environment: [:],
            allowRemoteIncludes: true,
            emitReadinessChecks: true
        ))

        XCTAssertEqual(snapshot.project.remoteIncludes, [
            ComposeRemoteInclude(
                url: "https://example.test/shared/compose.yaml",
                cacheKey: "desktop-cache:shared-compose",
                cacheStatus: .hit,
                source: "container-desktop-cache",
                contentLength: remoteYAML.utf8.count
            )
        ])

        let buildPreview = try XCTUnwrap(snapshot.commands.first { $0.action == .buildService && $0.service == "api" })
        XCTAssertEqual(buildPreview.generatedFiles.count, 1)
        XCTAssertEqual(buildPreview.generatedFiles.first?.kind, .inlineDockerfile)
        XCTAssertEqual(buildPreview.generatedFiles.first?.diagnosticsPath, "services.api.build.dockerfile_inline")
        XCTAssertTrue(buildPreview.displayCommand.contains("--file"))
        XCTAssertEqual(buildPreview.execution?.status, .planned)

        let apiRunPreview = try XCTUnwrap(snapshot.commands.first { $0.action == .runService && $0.service == "api" })
        XCTAssertEqual(apiRunPreview.dependsOnCommandIndexes, [0])
        XCTAssertEqual(apiRunPreview.execution?.status, .planned)

        let webPreview = try XCTUnwrap(snapshot.commands.first { $0.action == .runService && $0.service == "web" })
        XCTAssertEqual(webPreview.dependsOnCommandIndexes, [2])
        XCTAssertEqual(webPreview.readiness.map(\.containerName), ["desktop-contract_api_1"])
        XCTAssertEqual(webPreview.execution?.status, .planned)
        XCTAssertEqual(snapshot.report?.dryRun, true)
    }

    func testDesktopSnapshotReflectsExecutionFailuresAndSkippedCommands() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          api:
            image: example/api:dev
          web:
            image: nginx:alpine
            depends_on:
              - api
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let service = ContainerComposeService()
        let result = try service.makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-execution"
        ))
        let failingExecutor = ContractFakeContainerCommandExecutor(results: [
            .failure(ContainerCommandExecutionError.processFailed("runtime denied"))
        ])

        let report = service.execute(
            plan: result.plan,
            dryRun: false,
            executor: failingExecutor
        )
        let snapshot = ContainerComposeDesktopSnapshot(
            project: result.project,
            plan: result.plan,
            report: report
        )

        XCTAssertEqual(snapshot.commands.map { $0.execution?.status }, [.failed, .skipped, .skipped])
        XCTAssertEqual(snapshot.commands.first?.execution?.errorCode, .processFailed)
        XCTAssertEqual(snapshot.commands.first?.execution?.error, "processFailed(\"runtime denied\")")
        XCTAssertEqual(snapshot.commands[1].execution?.errorCode, .skippedPreviousFailure)
        XCTAssertEqual(snapshot.commands[1].execution?.error, "Skipped because a previous command failed.")
        XCTAssertEqual(failingExecutor.calls, [
            ["network", "create", "desktop-execution_default"]
        ])
    }

    func testDesktopSnapshotCarriesRuntimeStatusForAppBanners() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let runtimeStatus = AppleContainerRuntimeStatus(
            executablePath: nil,
            availability: .unavailable,
            issues: [
                .init(
                    code: .containerCLIUnavailable,
                    message: "Apple container CLI executable 'container' was not found."
                )
            ]
        )
        let service = ContainerComposeService()
        let result = try service.makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-runtime",
            runtimeStatus: runtimeStatus
        ))
        let report = AppleContainerExecutionReport(
            plan: result.plan,
            dryRun: false,
            results: []
        )

        let snapshot = ContainerComposeDesktopSnapshot(
            project: result.project,
            plan: result.plan,
            report: report
        )

        XCTAssertEqual(snapshot.runtimeStatus, runtimeStatus)
        XCTAssertEqual(snapshot.plan.runtimeStatus, runtimeStatus)
        XCTAssertEqual(snapshot.report?.runtimeStatus, runtimeStatus)
        XCTAssertEqual(snapshot.commands.first?.displayCommand, "container network create desktop-runtime_default")
    }

    func testDesktopCommandPreviewDecodesOlderJSONWithoutGeneratedFiles() throws {
        let json = """
        {
          "commandIndex": 0,
          "action": "runService",
          "service": "web",
          "arguments": ["run", "--name", "demo_web_1", "nginx"],
          "displayCommand": "container run --name demo_web_1 nginx"
        }
        """

        let decoded = try JSONDecoder().decode(ContainerComposeDesktopCommandPreview.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.commandIndex, 0)
        XCTAssertEqual(decoded.action, .runService)
        XCTAssertEqual(decoded.service, "web")
        XCTAssertEqual(decoded.generatedFiles, [])
        XCTAssertEqual(decoded.dependsOnCommandIndexes, [])
        XCTAssertEqual(decoded.readiness, [])
    }

    func testDesktopCommandPreviewInfersDisplayCommandWhenMissing() throws {
        let json = """
        {
          "commandIndex": 0,
          "action": "buildService",
          "service": "web",
          "arguments": ["build", "--tag", "demo_web:latest", "/tmp/demo web"]
        }
        """

        let decoded = try JSONDecoder().decode(ContainerComposeDesktopCommandPreview.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.displayCommand, "container build --tag demo_web:latest '/tmp/demo web'")
        XCTAssertEqual(decoded.generatedFiles, [])
        XCTAssertEqual(decoded.dependsOnCommandIndexes, [])
        XCTAssertEqual(decoded.readiness, [])
    }

    func testDesktopCommandPreviewDecodesLegacySnakeCaseDisplayCommand() throws {
        let json = """
        {
          "commandIndex": 0,
          "action": "runService",
          "service": "web",
          "arguments": ["run", "nginx"],
          "display_command": "legacy container run nginx"
        }
        """

        let decoded = try JSONDecoder().decode(ContainerComposeDesktopCommandPreview.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.displayCommand, "legacy container run nginx")
    }

    func testDesktopCommandPreviewDecodesLegacySnakeCaseFieldAliases() throws {
        let json = """
        {
          "command_index": 0,
          "action": "runService",
          "service": "web",
          "arguments": ["run", "--name", "legacy_web_1", "nginx"],
          "depends_on_command_indexes": [2],
          "display_command": "legacy container run --name legacy_web_1 nginx"
        }
        """

        let decoded = try JSONDecoder().decode(ContainerComposeDesktopCommandPreview.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.commandIndex, 0)
        XCTAssertEqual(decoded.dependsOnCommandIndexes, [2])
        XCTAssertEqual(decoded.displayCommand, "legacy container run --name legacy_web_1 nginx")
        XCTAssertEqual(decoded.generatedFiles, [])
        XCTAssertEqual(decoded.readiness, [])
    }

    private func makeTemporaryWorkdir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-container-desktop-contract-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class ContractFakeContainerCommandExecutor: ContainerCommandExecutor {
    var calls: [[String]] = []
    private var results: [Result<CommandExecutionResult, Error>]

    init(results: [Result<CommandExecutionResult, Error>]) {
        self.results = results
    }

    func execute(arguments: [String]) throws -> CommandExecutionResult {
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
