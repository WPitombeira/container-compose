import ContainerComposeCore
import Foundation
import XCTest

final class ContainerDesktopPublicAPIBoundaryTests: XCTestCase {
    func testExternalPackageCanCreateDesktopSnapshotAndExecuteWithAsyncExecutor() async throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let service = ContainerComposeService()
        let snapshot = try service.makeDesktopSnapshot(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "public-api"
        ))

        XCTAssertEqual(snapshot.commands.map(\.displayCommand), [
            "container network create public-api_default",
            "container run --name public-api_web_1 --detach --network public-api_default nginx:alpine"
        ])

        let executor = PublicAPIAsyncExecutor(results: [
            .success(CommandExecutionResult(
                executablePath: "/usr/local/bin/container",
                arguments: ["network", "create", "public-api_default"],
                exitCode: 0,
                standardOutput: "network\n",
                standardError: "",
                durationMilliseconds: 10
            )),
            .success(CommandExecutionResult(
                executablePath: "/usr/local/bin/container",
                arguments: ["run", "--name", "public-api_web_1", "--detach", "--network", "public-api_default", "nginx:alpine"],
                exitCode: 0,
                standardOutput: "started\n",
                standardError: "",
                durationMilliseconds: 12
            ))
        ])

        let report = await service.execute(
            plan: snapshot.plan,
            dryRun: false,
            executor: executor
        )

        XCTAssertEqual(executor.calls, [
            ["network", "create", "public-api_default"],
            ["run", "--name", "public-api_web_1", "--detach", "--network", "public-api_default", "nginx:alpine"]
        ])
        XCTAssertEqual(report.results.map(\.status), [.executed, .executed])
        XCTAssertEqual(report.summary.succeeded, 2)

        let encoded = try JSONEncoder().encode(ContainerComposeDesktopSnapshot(
            project: snapshot.project,
            plan: snapshot.plan,
            report: report
        ))
        let decoded = try JSONDecoder().decode(ContainerComposeDesktopSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.commands.first?.execution?.status, .executed)
        XCTAssertEqual(decoded.commands.first?.arguments, executor.calls.first)
    }

    func testExternalPackageCanPreviewInMemoryComposeYAMLSnippet() throws {
        let service = ContainerComposeService()
        let snapshot = try service.makeDesktopSnapshot(.init(
            operation: .up,
            composeYAML: """
            services:
              api:
                image: example/api:dev
              web:
                image: nginx:alpine
                depends_on:
                  - api
            """,
            projectDirectory: "/tmp/container-desktop-paste",
            projectName: "paste-preview"
        ))

        XCTAssertEqual(snapshot.project.sourcePath, "/tmp/container-desktop-paste/compose.yaml")
        XCTAssertEqual(snapshot.project.services.map(\.name), ["api", "web"])
        XCTAssertEqual(snapshot.commands.map(\.displayCommand), [
            "container network create paste-preview_default",
            "container run --name paste-preview_api_1 --detach --network paste-preview_default example/api:dev",
            "container run --name paste-preview_web_1 --detach --network paste-preview_default nginx:alpine"
        ])
        XCTAssertEqual(snapshot.commands[2].dependsOnCommandIndexes, [1])
    }

    func testExternalPackageCanPreviewMixedComposeSourcesWithoutTemporaryFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx:alpine
            environment:
              LOG_LEVEL: info
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let service = ContainerComposeService()
        let snapshot = try service.makeDesktopSnapshot(.init(
            operation: .up,
            composeSources: [
                ComposeSource(path: "compose.yaml"),
                ComposeSource(path: "snippets/pasted-override.yaml", yaml: """
                services:
                  web:
                    environment:
                      LOG_LEVEL: debug
                    ports:
                      - "8080:80"
                """)
            ],
            projectDirectory: workdir.path,
            projectName: "mixed-preview"
        ))

        XCTAssertEqual(snapshot.project.sourcePath, workdir.appendingPathComponent("compose.yaml").path)
        XCTAssertEqual(snapshot.project.services.first?.environment["LOG_LEVEL"], "debug")
        XCTAssertEqual(snapshot.commands.map(\.displayCommand), [
            "container network create mixed-preview_default",
            "container run --name mixed-preview_web_1 --detach --env LOG_LEVEL=debug --publish 8080:80 --network mixed-preview_default nginx:alpine"
        ])
    }

    private func makeTemporaryWorkdir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-public-api-boundary-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class PublicAPIAsyncExecutor: AsyncContainerCommandExecutor {
    var calls: [[String]] = []
    private var results: [Result<CommandExecutionResult, Error>]

    init(results: [Result<CommandExecutionResult, Error>]) {
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
