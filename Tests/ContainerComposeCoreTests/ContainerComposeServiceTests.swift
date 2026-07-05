import XCTest
@testable import ContainerComposeCore

final class ContainerComposeServiceTests: XCTestCase {
    func testFacadePlansUpFromInMemoryComposeYAMLForDesktopSnippet() throws {
        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            composeYAML: """
            name: pasted-demo
            services:
              web:
                image: nginx:alpine
                ports:
                  - "8080:80"
            """,
            projectDirectory: "/tmp/pasted",
            detach: true
        ))

        XCTAssertEqual(result.project.name, "pasted-demo")
        XCTAssertEqual(result.project.sourcePath, "/tmp/pasted/compose.yaml")
        XCTAssertEqual(result.plan.commands.map(\.action), [.createNetwork, .runService])
        XCTAssertEqual(result.plan.commands.map(\.service), [nil, "web"])
        XCTAssertEqual(result.plan.commands[0].arguments, ["network", "create", "pasted-demo_default"])
        XCTAssertEqual(result.plan.commands[1].arguments, [
            "run",
            "--name",
            "pasted-demo_web_1",
            "--detach",
            "--publish",
            "8080:80",
            "--network",
            "pasted-demo_default",
            "nginx:alpine"
        ])
    }

    func testInMemoryComposeYAMLResolvesIncludesRelativeToSyntheticSourcePath() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          db:
            image: postgres:16
        """.write(to: workdir.appendingPathComponent("shared.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            composeYAML: """
            include:
              - ../shared.yaml
            services:
              web:
                image: nginx:alpine
                depends_on:
                  - db
            """,
            composeYAMLSourcePath: "snippets/pasted.yaml",
            projectDirectory: workdir.path,
            projectName: "snippet-demo"
        ))

        XCTAssertEqual(result.project.sourcePath, workdir.appendingPathComponent("snippets/pasted.yaml").path)
        XCTAssertEqual(result.project.services.map(\.name), ["db", "web"])
        XCTAssertEqual(result.plan.commands.filter { $0.action == .runService }.map(\.service), ["db", "web"])
        XCTAssertEqual(result.plan.executionGraph?.edges.map(\.fromCommandIndex), [1])
        XCTAssertEqual(result.plan.executionGraph?.edges.map(\.toCommandIndex), [2])
    }

    func testInMemoryComposeYAMLOverridesComposeFileEnvironmentDefault() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          file:
            image: busybox
        """.write(to: workdir.appendingPathComponent("custom.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            composeYAML: """
            services:
              snippet:
                image: alpine
            """,
            projectDirectory: workdir.path,
            environment: [
                "COMPOSE_FILE": "custom.yaml",
                "COMPOSE_PROJECT_NAME": "env-demo"
            ]
        ))

        XCTAssertEqual(result.project.name, "env-demo")
        XCTAssertEqual(result.project.services.map(\.name), ["snippet"])
    }

    func testFacadeUsesComposeEnvFilesForInMemoryComposeYAMLInterpolation() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try "IMAGE=from-dot-env\n".write(
            to: workdir.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try "IMAGE=nginx:alpine\n".write(
            to: workdir.appendingPathComponent("preview.env"),
            atomically: true,
            encoding: .utf8
        )

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            composeYAML: """
            services:
              web:
                image: ${IMAGE}
            """,
            projectDirectory: workdir.path,
            composeEnvFiles: ["preview.env"]
        ))

        XCTAssertEqual(result.project.services.first?.image, "nginx:alpine")
        XCTAssertEqual(result.plan.commands.first { $0.action == .runService }?.arguments.last, "nginx:alpine")
    }

    func testInMemoryComposeYAMLResolvesLongSyntaxIncludeProjectDirectoryAndEnvFile() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }
        try FileManager.default.createDirectory(
            at: workdir.appendingPathComponent("shared"),
            withIntermediateDirectories: true
        )
        try "IMAGE=redis:7-alpine\n".write(
            to: workdir.appendingPathComponent("shared/defaults.env"),
            atomically: true,
            encoding: .utf8
        )
        try """
        services:
          redis:
            image: ${IMAGE}
        """.write(to: workdir.appendingPathComponent("shared/compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            composeYAML: """
            include:
              - path: compose.yaml
                project_directory: shared
                env_file: defaults.env
            services:
              web:
                image: nginx:alpine
                depends_on:
                  - redis
            """,
            composeYAMLSourcePath: "pasted.yaml",
            projectDirectory: workdir.path,
            projectName: "include-env-demo"
        ))

        XCTAssertEqual(result.project.services.map(\.name), ["redis", "web"])
        XCTAssertEqual(result.project.services.first { $0.name == "redis" }?.image, "redis:7-alpine")
        XCTAssertFalse(result.project.diagnostics.contains { $0.path == "include.env_file" })
        XCTAssertEqual(result.plan.commands.filter { $0.action == .runService }.map(\.service), ["redis", "web"])
    }

    func testInMemoryComposeYAMLAllowsRemoteIncludeWhenFlagEnabled() throws {
        let remoteYAML = """
        services:
          api:
            image: example/api:dev
        """
        let service = ContainerComposeService(remoteIncludeResolver: { request in
            XCTAssertEqual(request.sanitizedURL, "https://example.test/shared.yaml")
            XCTAssertEqual(request.includedFrom, "/tmp/snippet/compose.yaml")
            XCTAssertEqual(request.includeStack, ["/tmp/snippet/compose.yaml"])
            return .init(
                yaml: remoteYAML,
                cacheKey: "snippet-cache",
                cacheStatus: .hit,
                source: "container-desktop-cache"
            )
        })

        let result = try service.makePlan(.init(
            operation: .up,
            composeYAML: """
            include:
              - https://example.test/shared.yaml
            services:
              web:
                image: nginx:alpine
                depends_on:
                  - api
            """,
            projectDirectory: "/tmp/snippet",
            allowRemoteIncludes: true
        ))

        XCTAssertEqual(result.project.remoteIncludes, [
            ComposeRemoteInclude(
                url: "https://example.test/shared.yaml",
                cacheKey: "snippet-cache",
                cacheStatus: .hit,
                source: "container-desktop-cache",
                contentLength: remoteYAML.utf8.count
            )
        ])
        XCTAssertEqual(result.project.services.map(\.name), ["api", "web"])
    }

    func testInMemoryComposeYAMLRejectsRemoteIncludeWhenFlagDisabled() throws {
        XCTAssertThrowsError(try ContainerComposeService().makePlan(.init(
            operation: .up,
            composeYAML: """
            include:
              - https://example.test/shared.yaml
            services:
              web:
                image: nginx:alpine
            """,
            projectDirectory: "/tmp/snippet"
        ))) { error in
            guard case ComposeLoadError.remoteIncludeDisabled("https://example.test/shared.yaml") = error else {
                return XCTFail("Expected remote include disabled error, got \(error).")
            }
        }
    }

    func testFacadePlansUpFromComposeFileForDesktopIntegration() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        name: desktop-demo
        services:
          db:
            image: postgres:16
          web:
            image: nginx:alpine
            depends_on:
              - db
            ports:
              - "8080:80"
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            detach: true
        ))

        XCTAssertEqual(result.project.name, "desktop-demo")
        XCTAssertEqual(result.plan.operation, "up")
        XCTAssertEqual(result.plan.schemaVersion, "1.8.0")
        XCTAssertEqual(result.plan.commands.filter { $0.action == .runService }.map(\.service), ["db", "web"])
        XCTAssertEqual(result.plan.executionGraph?.edges, [
            AppleContainerExecutionEdge(
                fromCommandIndex: 1,
                toCommandIndex: 2,
                dependencyMetadata: AppleContainerDependencyMetadata()
            )
        ])
        XCTAssertTrue(result.plan.commands.contains { $0.arguments.contains("desktop-demo_web_1") })
    }

    func testFacadeUsesParentComposeDiscoveryWhenProjectDirectoryIsNested() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }
        let nested = workdir.appendingPathComponent("services/api")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try """
        name: parent-stack
        services:
          api:
            image: example/api:dev
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: nested.path
        ))

        XCTAssertEqual(result.project.sourcePath, workdir.appendingPathComponent("compose.yaml").path)
        XCTAssertEqual(result.project.name, "parent-stack")
        XCTAssertEqual(result.plan.commands.first { $0.action == .runService }?.arguments, [
            "run",
            "--name",
            "parent-stack_api_1",
            "--detach",
            "--network",
            "parent-stack_default",
            "example/api:dev"
        ])
    }

    func testFacadePlansFromOrderedComposeSourcesForMixedStdinCLIFlow() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        name: mixed-cli
        services:
          web:
            image: nginx:alpine
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            composeSources: [
                ComposeSource(path: "compose.yaml"),
                ComposeSource(path: "compose.stdin.yaml", yaml: """
                services:
                  web:
                    ports:
                      - "8080:80"
                """)
            ],
            projectDirectory: workdir.path,
            detach: true
        ))

        XCTAssertEqual(result.project.sourcePath, workdir.appendingPathComponent("compose.yaml").path)
        XCTAssertEqual(result.plan.commands.first { $0.action == .runService }?.arguments, [
            "run",
            "--name",
            "mixed-cli_web_1",
            "--detach",
            "--publish",
            "8080:80",
            "--network",
            "mixed-cli_default",
            "nginx:alpine"
        ])
    }

    func testFacadePlansSelectedUpWithDependencyClosureWithoutMutatingProject() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          db:
            image: postgres
          api:
            image: backend
            depends_on:
              - db
          web:
            image: nginx
            depends_on:
              - api
          worker:
            image: busybox
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "selected-demo",
            services: ["web"]
        ))

        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["api", "db", "web", "worker"])
        XCTAssertEqual(result.plan.selectedServices, ["web"])
        XCTAssertEqual(result.plan.commands.filter { $0.action == .runService }.map(\.service), ["db", "api", "web"])
        XCTAssertEqual(result.plan.executionGraph?.edges, [
            AppleContainerExecutionEdge(
                fromCommandIndex: 1,
                toCommandIndex: 2,
                dependencyMetadata: AppleContainerDependencyMetadata()
            ),
            AppleContainerExecutionEdge(
                fromCommandIndex: 2,
                toCommandIndex: 3,
                dependencyMetadata: AppleContainerDependencyMetadata()
            )
        ])
    }

    func testFacadeSelectedUpActivatesTargetServiceProfiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          debug:
            image: busybox
            profiles:
              - debug
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            services: ["debug"]
        ))

        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["debug", "web"])
        XCTAssertEqual(result.plan.commands.filter { $0.action == .runService }.map(\.service), ["debug"])
    }

    func testFacadePlansOneOffRunForProfiledTarget() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          debug:
            image: busybox
            profiles:
              - debug
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .run,
            projectDirectory: workdir.path,
            services: ["debug"],
            runOptions: .init(noDependencies: true, command: ["echo", "ok"])
        ))

        XCTAssertEqual(result.plan.operation, "run")
        XCTAssertEqual(result.plan.selectedServices, ["debug"])
        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["debug", "web"])
        XCTAssertEqual(result.plan.commands, [
            PlannedCommand(
                action: .createNetwork,
                arguments: ["network", "create", "\(result.project.name)_default"]
            ),
            PlannedCommand(
                action: .runService,
                service: "debug",
                arguments: [
                    "run",
                    "--name",
                    "\(result.project.name)_debug_run_1",
                    "--interactive",
                    "--tty",
                    "--network",
                    "\(result.project.name)_default",
                    "busybox",
                    "echo",
                    "ok"
                ]
            )
        ])
    }

    func testFacadePlansCreateForProfiledTarget() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          debug:
            image: busybox
            profiles:
              - debug
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .create,
            projectDirectory: workdir.path,
            services: ["debug"]
        ))

        XCTAssertEqual(result.plan.operation, "create")
        XCTAssertEqual(result.plan.selectedServices, ["debug"])
        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["debug", "web"])
        XCTAssertEqual(result.plan.commands, [
            PlannedCommand(
                action: .createNetwork,
                arguments: ["network", "create", "\(result.project.name)_default"]
            ),
            PlannedCommand(
                action: .createService,
                service: "debug",
                arguments: [
                    "create",
                    "--name",
                    "\(result.project.name)_debug_1",
                    "--network",
                    "\(result.project.name)_default",
                    "busybox"
                ]
            )
        ])
    }

    func testFacadePlansPullForSelectedServicesAndProfiledTargets() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          debug:
            image: busybox
            profiles:
              - debug
          build-only:
            build: ./app
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .pull,
            projectDirectory: workdir.path,
            services: ["debug"]
        ))

        XCTAssertEqual(result.plan.operation, "pull")
        XCTAssertEqual(result.plan.selectedServices, ["debug"])
        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["build-only", "debug", "web"])
        XCTAssertEqual(result.plan.commands, [
            PlannedCommand(action: .pullImage, service: "debug", arguments: ["image", "pull", "busybox"])
        ])
        XCTAssertFalse(result.plan.diagnostics.contains { $0.path == "services.build-only.image" })
    }

    func testFacadePlansPushForSelectedServicesAndProfiledTargets() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          debug:
            image: example/debug:dev
            profiles:
              - debug
          build-only:
            build: ./app
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .push,
            projectDirectory: workdir.path,
            services: ["debug"],
            pushOptions: .init(quiet: true)
        ))

        XCTAssertEqual(result.plan.operation, "push")
        XCTAssertEqual(result.plan.selectedServices, ["debug"])
        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["build-only", "debug", "web"])
        XCTAssertEqual(result.plan.commands, [
            PlannedCommand(action: .pushImage, service: "debug", arguments: ["image", "push", "--progress", "none", "example/debug:dev"])
        ])
        XCTAssertFalse(result.plan.diagnostics.contains { $0.path == "services.build-only.image" })
    }

    func testFacadePushWarnsForBuildOnlyServices() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          build-only:
            build: ./app
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .push,
            projectDirectory: workdir.path
        ))

        XCTAssertEqual(result.plan.commands.map(\.service), ["web"])
        XCTAssertTrue(result.plan.diagnostics.contains {
            $0.severity == .warning
                && $0.path == "services.build-only.image"
                && $0.message.contains("Push planning skipped")
        })
    }

    func testFacadePlansImagesWithSelectedServiceMetadata() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          debug:
            image: busybox
            profiles:
              - debug
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .images,
            projectDirectory: workdir.path,
            services: ["debug"],
            imagesOptions: .init(format: "json", quiet: true)
        ))

        XCTAssertEqual(result.plan.operation, "images")
        XCTAssertEqual(result.plan.selectedServices, ["debug"])
        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["debug", "web"])
        XCTAssertEqual(result.plan.commands, [
            PlannedCommand(
                action: .listImages,
                arguments: ["image", "list", "--format", "json", "--quiet"],
                diagnostics: [
                    ComposeDiagnostic(
                        severity: .warning,
                        path: "images",
                        message: "Apple Container does not expose Compose project filtering for image lists yet; this lists images from the local runtime."
                    ),
                    ComposeDiagnostic(
                        severity: .warning,
                        path: "images.services",
                        message: "Docker Compose SERVICE filters cannot be mapped to container image list yet; selected services remain visible in plan metadata."
                    )
                ]
            )
        ])
    }

    func testFacadePlansBuildForSelectedServicesAndProfiledTargets() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          debug:
            image: debug:dev
            build: ./debug
            profiles:
              - debug
          worker:
            build: ./worker
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .build,
            projectDirectory: workdir.path,
            services: ["debug"]
        ))

        XCTAssertEqual(result.plan.operation, "build")
        XCTAssertEqual(result.plan.selectedServices, ["debug"])
        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["debug", "web", "worker"])
        XCTAssertEqual(result.plan.commands.map(\.action), [.buildService])
        XCTAssertEqual(result.plan.commands.first?.service, "debug")
        XCTAssertEqual(Array(result.plan.commands.first?.arguments.prefix(3) ?? []), ["build", "--tag", "debug:dev"])
        XCTAssertFalse(result.plan.diagnostics.contains { $0.path == "services.web.build" })
    }

    func testFacadeBuildWarnsForImageOnlyServices() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          api:
            build: ./api
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .build,
            projectDirectory: workdir.path
        ))

        XCTAssertEqual(result.plan.commands.map(\.service), ["api"])
        XCTAssertTrue(result.plan.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.web.build"
            && $0.message.contains("skipped service 'web'")
        })
    }

    func testFacadePlansInlineDockerfileGeneratedFileForBuild() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          api:
            image: example/api:dev
            build:
              context: ./api
              dockerfile_inline: |
                FROM scratch
                LABEL app=api
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .build,
            projectDirectory: workdir.path,
            projectName: "demo"
        ))

        let command = try XCTUnwrap(result.plan.commands.first)
        XCTAssertEqual(command.action, .buildService)
        XCTAssertEqual(command.generatedFiles.count, 1)
        XCTAssertEqual(command.generatedFiles.first?.kind, .inlineDockerfile)
        XCTAssertEqual(command.generatedFiles.first?.contents, "FROM scratch\nLABEL app=api")
        XCTAssertEqual(command.generatedFiles.first?.diagnosticsPath, "services.api.build.dockerfile_inline")
        XCTAssertTrue(command.arguments.contains("--file"))
        XCTAssertTrue(command.arguments.contains(command.generatedFiles[0].path))
        XCTAssertFalse(command.diagnostics.contains { $0.path == "services.api.build.dockerfile_inline" })
    }

    func testFacadePullWarnsForBuildOnlyServices() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          api:
            build: ./api
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .pull,
            projectDirectory: workdir.path
        ))

        XCTAssertEqual(result.plan.commands.map(\.service), ["web"])
        XCTAssertTrue(result.plan.diagnostics.contains {
            $0.severity == .warning
            && $0.path == "services.api.image"
            && $0.message.contains("skipped service 'api'")
        })
    }

    func testFacadeSelectedUpWarnsWhenDependencyProfileIsInactive() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          bar:
            image: bar
            profiles:
              - test
          zot:
            image: zot
            depends_on:
              - bar
            profiles:
              - debug
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            services: ["zot"]
        ))

        XCTAssertEqual(result.project.services.map(\.name), ["zot"])
        XCTAssertEqual(result.plan.commands.filter { $0.action == .runService }.map(\.service), ["zot"])
        XCTAssertTrue(result.plan.diagnostics.contains {
            $0.path == "services.zot.depends_on.bar"
        })
    }

    func testFacadePreservesHealthcheckAndEmitsPlannerDiagnostics() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          api:
            image: example/api
            healthcheck:
              test: ["CMD", "curl", "-f", "http://localhost/health"]
              interval: 10s
              retries: 2
          web:
            image: nginx
            depends_on:
              api:
                condition: service_healthy
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "health-demo"
        ))
        let api = try XCTUnwrap(result.project.services.first { $0.name == "api" })
        let apiRun = try XCTUnwrap(result.plan.commands.first { $0.service == "api" })
        let webRun = try XCTUnwrap(result.plan.commands.first { $0.service == "web" })

        XCTAssertEqual(api.healthcheck, ComposeHealthcheck(
            test: ["CMD", "curl", "-f", "http://localhost/health"],
            interval: "10s",
            retries: 2
        ))
        XCTAssertTrue(apiRun.diagnostics.contains { $0.path == "services.api.healthcheck" })
        XCTAssertFalse(webRun.diagnostics.contains { $0.path == "services.web.depends_on.api.condition" })
    }

    func testFacadeSelectedStartActivatesTargetServiceProfiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          debug:
            image: busybox
            profiles:
              - debug
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .start,
            projectDirectory: workdir.path,
            projectName: "profiled",
            services: ["debug"]
        ))

        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["debug", "web"])
        XCTAssertEqual(result.plan.selectedServices, ["debug"])
        XCTAssertEqual(result.plan.commands.map(\.arguments), [["start", "profiled_debug_1"]])
    }

    func testFacadePlansServiceLabelsAndReportsReservedLabels() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
            labels:
              com.example.role: frontend
              com.docker.compose.project: blocked
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "demo"
        ))

        let command = try XCTUnwrap(result.plan.commands.first { $0.action == .runService })
        XCTAssertTrue(command.arguments.contains("--label"))
        XCTAssertTrue(command.arguments.contains("com.example.role=frontend"))
        XCTAssertFalse(command.arguments.contains { $0.contains("com.docker.compose.project") })
        XCTAssertTrue(result.plan.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.web.labels.com.docker.compose.project"
        })
    }

    func testFacadePlansCustomContainerNameForDesktopCommands() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
            container_name: public-web
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path
        ))

        XCTAssertEqual(result.project.services.first?.containerName, "public-web")
        XCTAssertEqual(result.plan.commands.first { $0.action == .runService }?.arguments, [
            "run",
            "--name",
            "public-web",
            "--detach",
            "--network",
            "\(result.project.name)_default",
            "nginx"
        ])
    }

    func testFacadePlansBuildOnlyServiceForDesktopCommands() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            build: ./web
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-build"
        ))

        XCTAssertEqual(result.project.services.first?.build, ComposeBuild(context: "./web"))
        XCTAssertEqual(result.plan.commands.map(\.action), [.buildService, .createNetwork, .runService])
        XCTAssertEqual(Array(result.plan.commands[0].arguments.prefix(3)), ["build", "--tag", "desktop-build_web:latest"])
        XCTAssertEqual(result.plan.commands[2].arguments.last, "desktop-build_web:latest")
    }

    func testFacadePreservesBuildContextWhenOverrideAddsBuildOptions() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            build: ./web
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          web:
            build:
              dockerfile: Dockerfile.prod
              args:
                APP_ENV: production
        """.write(to: workdir.appendingPathComponent("compose.override.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-build-merge"
        ))
        let buildCommand = try XCTUnwrap(result.plan.commands.first { $0.action == .buildService })

        XCTAssertEqual(result.project.services.first?.build, ComposeBuild(
            context: "./web",
            dockerfile: "Dockerfile.prod",
            args: ["APP_ENV=production"]
        ))
        XCTAssertEqual(buildCommand.arguments, [
            "build",
            "--tag",
            "desktop-build-merge_web:latest",
            "--file",
            workdir.appendingPathComponent("web/Dockerfile.prod").path,
            "--build-arg",
            "APP_ENV=production",
            workdir.appendingPathComponent("web").path
        ])
    }

    func testFacadeDeduplicatesMergedServiceNetworksForDesktopCommands() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
            networks:
              - front
              - back
        networks:
          front: {}
          back: {}
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          web:
            networks:
              - front
              - cache
        networks:
          cache: {}
        """.write(to: workdir.appendingPathComponent("compose.override.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-networks"
        ))
        let runCommand = try XCTUnwrap(result.plan.commands.first { $0.action == .runService })
        let networkValues = runCommand.arguments.enumerated().compactMap { index, argument in
            argument == "--network" ? runCommand.arguments[index + 1] : nil
        }

        XCTAssertEqual(result.project.services.first?.networks, ["front", "back", "cache"])
        XCTAssertEqual(networkValues, [
            "desktop-networks_front",
            "desktop-networks_back",
            "desktop-networks_cache"
        ])
    }

    func testDesktopSnapshotRendersCommandPreviewsAndGraphMetadata() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          db:
            image: postgres
          web:
            build: ./web app
            command: ["echo", "hello world"]
            depends_on:
              db:
                condition: service_started
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let snapshot = try ContainerComposeService().makeDesktopSnapshot(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-preview",
            emitReadinessChecks: true
        ))
        let resolvedWorkdir = workdir.standardizedFileURL

        XCTAssertEqual(snapshot.plan.schemaVersion, "1.8.0")
        XCTAssertEqual(snapshot.commands.map(\.action), [.buildService, .createNetwork, .runService, .runService])
        XCTAssertEqual(snapshot.commands[0].displayCommand, "container build --tag desktop-preview_web:latest '\(resolvedWorkdir.path)/web app'")
        XCTAssertEqual(snapshot.commands[3].dependsOnCommandIndexes, [0, 2])
        XCTAssertEqual(snapshot.commands[3].readiness.map(\.containerName), ["desktop-preview_db_1"])
        XCTAssertNil(snapshot.commands[0].execution)
    }

    func testDesktopDryRunSnapshotAttachesPlannedExecutions() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let snapshot = try ContainerComposeService().dryRunDesktopSnapshot(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-dry-run"
        ))

        XCTAssertEqual(snapshot.report?.dryRun, true)
        XCTAssertEqual(snapshot.commands.map { $0.execution?.status }, [.planned, .planned])
        XCTAssertEqual(snapshot.commands[0].displayCommand, "container network create desktop-dry-run_default")
        XCTAssertEqual(snapshot.commands[1].displayCommand, "container run --name desktop-dry-run_web_1 --detach --network desktop-dry-run_default nginx")
        XCTAssertEqual(snapshot.readinessResults, [])
    }

    func testFacadeReportsContainerNameCollisionsAfterProjectNameOverride() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          api:
            image: backend
            container_name: custom_db_1
          db:
            image: postgres
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "custom"
        ))

        XCTAssertTrue(result.plan.diagnostics.contains {
            $0.severity == .error
            && $0.path == "services.db"
            && $0.message.contains("api")
        })
    }

    func testFacadeReportsMissingSelectedUpServiceInPlanDiagnostics() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            services: ["missing"]
        ))

        XCTAssertEqual(result.plan.selectedServices, ["missing"])
        XCTAssertTrue(result.plan.commands.isEmpty)
        XCTAssertTrue(result.plan.diagnostics.contains {
            $0.severity == .warning && $0.path == "services.missing"
        })
    }

    func testFacadeDownCanRemoveNetworksAndOptInVolumes() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
            volumes:
              - data:/usr/share/nginx/html
            networks:
              - front
        networks:
          front:
          shared:
            external: true
        volumes:
          data:
          shared-data:
            external: true
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .down,
            projectDirectory: workdir.path,
            projectName: "demo",
            removeVolumes: true
        ))

        XCTAssertEqual(result.plan.schemaVersion, "1.8.0")
        XCTAssertEqual(result.plan.commands.map(\.action), [
            .stopService,
            .deleteService,
            .deleteNetwork,
            .deleteVolume
        ])
        XCTAssertEqual(result.plan.commands[2].arguments, ["network", "delete", "demo_front"])
        XCTAssertEqual(result.plan.commands[3].arguments, ["volume", "delete", "demo_data"])
    }

    func testFacadeAppliesProjectNameProfilesAndSelectedServices() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          debug:
            image: busybox
            profiles:
              - debug
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .logs,
            projectDirectory: workdir.path,
            projectName: "Desktop Project",
            profiles: ["debug"],
            services: ["debug"],
            follow: true,
            tail: 25
        ))

        XCTAssertEqual(result.project.name, "Desktop Project")
        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["debug", "web"])
        XCTAssertEqual(result.plan.commands.map(\.service), ["debug"])
        XCTAssertEqual(result.plan.commands.first?.arguments, ["logs", "--follow", "-n", "25", "desktop-project_debug_1"])
    }

    func testFacadePlansStatsForSelectedServices() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          db:
            image: postgres
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .stats,
            projectDirectory: workdir.path,
            projectName: "demo",
            services: ["web"],
            noStream: true
        ))

        XCTAssertEqual(result.plan.operation, "stats")
        XCTAssertEqual(result.plan.selectedServices, ["web"])
        XCTAssertEqual(result.plan.commands.map(\.action), [.statsService])
        XCTAssertEqual(result.plan.commands.first?.arguments, ["stats", "--no-stream", "demo_web_1"])
    }

    func testFacadePlansTopForSelectedServices() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          db:
            image: postgres
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .top,
            projectDirectory: workdir.path,
            projectName: "demo",
            services: ["web"]
        ))

        XCTAssertEqual(result.plan.operation, "top")
        XCTAssertEqual(result.plan.selectedServices, ["web"])
        XCTAssertEqual(result.plan.commands.map(\.action), [.topService])
        XCTAssertEqual(result.plan.commands.first?.arguments, ["exec", "demo_web_1", "ps"])
        XCTAssertEqual(result.plan.commands.first?.diagnostics.first?.path, "top")
    }

    func testFacadePlansPsForSelectedServicesRetainsMetadataAndCannotFilter() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          db:
            image: postgres
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .ps,
            projectDirectory: workdir.path,
            projectName: "demo",
            services: ["web"],
            all: true
        ))

        XCTAssertEqual(result.plan.operation, "ps")
        XCTAssertEqual(result.plan.selectedServices, ["web"])
        XCTAssertEqual(result.plan.commands.map(\.action), [.listServices])
        XCTAssertEqual(result.plan.commands.first?.arguments, ["list", "--all"])
        XCTAssertEqual(result.plan.commands.first?.diagnostics.map(\.path), ["ps", "ps.services"])
    }

    func testFacadePlansPsWarnsForMissingSelectedServiceAndPreservesBroadList() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .ps,
            projectDirectory: workdir.path,
            projectName: "demo",
            services: ["missing"]
        ))

        XCTAssertEqual(result.plan.operation, "ps")
        XCTAssertEqual(result.plan.selectedServices, ["missing"])
        XCTAssertEqual(result.plan.commands.map(\.action), [.listServices])
        XCTAssertEqual(result.plan.commands.first?.arguments, ["list", "--all"])
        XCTAssertEqual(result.plan.commands.first?.diagnostics.map(\.path), ["ps", "ps.services"])
        XCTAssertEqual(result.plan.diagnostics.map(\.path), ["services.missing"])
    }

    func testFacadePlansPsWithProfiledTargetService() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          debug:
            image: busybox
            profiles:
              - debug
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .ps,
            projectDirectory: workdir.path,
            services: ["debug"]
        ))

        XCTAssertEqual(result.plan.operation, "ps")
        XCTAssertEqual(result.plan.selectedServices, ["debug"])
        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["debug", "web"])
        XCTAssertTrue(result.plan.diagnostics.isEmpty)
        XCTAssertEqual(result.plan.commands.first?.arguments, ["list", "--all"])
    }

    func testFacadePlansKillForSelectedServices() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          db:
            image: postgres
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .kill,
            projectDirectory: workdir.path,
            projectName: "demo",
            services: ["web"],
            signal: "SIGINT"
        ))

        XCTAssertEqual(result.plan.operation, "kill")
        XCTAssertEqual(result.plan.selectedServices, ["web"])
        XCTAssertEqual(result.plan.commands.map(\.action), [.killService])
        XCTAssertEqual(result.plan.commands.first?.arguments, ["kill", "--signal", "SIGINT", "demo_web_1"])
    }

    func testFacadePlansRemoveWithStopForSelectedServices() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          db:
            image: postgres
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .rm,
            projectDirectory: workdir.path,
            projectName: "demo",
            services: ["web"],
            stopBeforeRemove: true
        ))

        XCTAssertEqual(result.plan.operation, "rm")
        XCTAssertEqual(result.plan.selectedServices, ["web"])
        XCTAssertEqual(result.plan.commands.map(\.action), [.stopService, .deleteService])
        XCTAssertEqual(result.plan.commands.map(\.arguments), [
            ["stop", "demo_web_1"],
            ["delete", "demo_web_1"]
        ])
    }

    func testFacadePlansExecForSelectedService() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          db:
            image: postgres
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .exec,
            projectDirectory: workdir.path,
            projectName: "demo",
            services: ["web"],
            execCommand: ["php", "-v"],
            execOptions: .init(tty: false)
        ))

        XCTAssertEqual(result.plan.operation, "exec")
        XCTAssertEqual(result.plan.selectedServices, ["web"])
        XCTAssertEqual(result.plan.commands.map(\.action), [.execService])
        XCTAssertEqual(result.plan.commands.first?.arguments, ["exec", "--interactive", "demo_web_1", "php", "-v"])
    }

    func testFacadePlansCopyForSelectedService() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          db:
            image: postgres
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .cp,
            projectDirectory: workdir.path,
            projectName: "demo",
            services: ["web"],
            copySource: "web:/var/log/app.log",
            copyDestination: "./app.log"
        ))

        XCTAssertEqual(result.plan.operation, "cp")
        XCTAssertEqual(result.plan.selectedServices, ["web"])
        XCTAssertEqual(result.plan.commands.map(\.action), [.copyService])
        XCTAssertEqual(result.plan.commands.first?.arguments, ["copy", "demo_web_1:/var/log/app.log", "./app.log"])
    }

    func testFacadeReadsComposeEnvironmentDefaultsWhenRequestLeavesOptionsEmpty() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          web:
            image: nginx
          tools:
            image: busybox
            profiles:
              - tools
        """.write(to: workdir.appendingPathComponent("custom.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .start,
            projectDirectory: workdir.path,
            environment: [
                "COMPOSE_FILE": "custom.yaml",
                "COMPOSE_PROFILES": "tools",
                "COMPOSE_PROJECT_NAME": "env-project"
            ]
        ))

        XCTAssertEqual(result.project.name, "env-project")
        XCTAssertEqual(result.project.services.map(\.name).sorted(), ["tools", "web"])
        XCTAssertEqual(result.plan.commands.map(\.service), ["tools", "web"])
    }

    func testFacadeProducesDryRunExecutionReportWithoutRuntimeExecutor() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        name: dry-run-demo
        services:
          web:
            image: nginx
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let report = try ContainerComposeService().dryRun(.init(
            operation: .down,
            projectDirectory: workdir.path
        ))

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.projectName, "dry-run-demo")
        XCTAssertEqual(report.operation, "down")
        XCTAssertEqual(report.results.map(\.status), [.planned, .planned, .planned])
        XCTAssertEqual(report.executionGraph?.nodes.count, 3)
        XCTAssertEqual(report.summary.total, 3)
        XCTAssertEqual(report.summary.succeeded, 3)
    }

    func testFacadeCanEmitReadinessMetadataForDesktopGraphRendering() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          db:
            image: postgres
          web:
            image: nginx
            depends_on:
              - db
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-ready",
            emitReadinessChecks: true
        ))

        XCTAssertEqual(result.plan.executionGraph?.nodes[2].readiness, [
            AppleContainerReadinessRequirement(service: "db", containerName: "desktop-ready_db_1")
        ])
    }

    func testFacadeCanEnforceReadinessWithInjectedCheckerForDesktopExecution() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          db:
            image: postgres
          web:
            image: nginx
            depends_on:
              db:
                condition: service_started
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let service = ContainerComposeService()
        let result = try service.makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-ready",
            emitReadinessChecks: true
        ))
        let executor = ServiceFakeContainerCommandExecutor(results: [
            .success(.init(
                executablePath: "/usr/bin/container",
                arguments: ["network", "create", "desktop-ready_default"],
                exitCode: 0,
                standardOutput: "",
                standardError: ""
            )),
            .success(.init(
                executablePath: "/usr/bin/container",
                arguments: ["run", "--name", "desktop-ready_db_1", "--detach", "postgres"],
                exitCode: 0,
                standardOutput: "",
                standardError: ""
            )),
            .success(.init(
                executablePath: "/usr/bin/container",
                arguments: ["run", "--name", "desktop-ready_web_1", "--detach", "nginx"],
                exitCode: 0,
                standardOutput: "",
                standardError: ""
            ))
        ])
        let readinessChecker = ServiceFakeReadinessChecker(results: [
            .init(requirement: .init(service: "db", containerName: "desktop-ready_db_1"), status: .ready)
        ])

        let report = service.execute(
            plan: result.plan,
            dryRun: false,
            executor: executor,
            enforceReadiness: true,
            readinessChecker: readinessChecker
        )

        XCTAssertEqual(executor.calls.count, 3)
        XCTAssertEqual(readinessChecker.requirements.map(\.containerName), ["desktop-ready_db_1"])
        XCTAssertEqual(report.readinessResults.map(\.status), [.ready])
        XCTAssertEqual(report.results.map(\.status), [.executed, .executed, .executed])
    }

    func testFacadeCanEmitLongFormDependsOnMetadataInPlan() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          db:
            image: postgres
          web:
            image: nginx
            depends_on:
              db:
                condition: service_healthy
                restart: true
                required: false
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-long",
            emitReadinessChecks: true
        ))

        XCTAssertEqual(result.plan.executionGraph?.schemaVersion, "1.1.0")
        XCTAssertEqual(result.plan.executionGraph?.edges.first?.dependencyMetadata, AppleContainerDependencyMetadata(
            condition: .serviceHealthy,
            restart: true,
            required: false
        ))
        XCTAssertEqual(result.plan.executionGraph?.nodes[2].readiness.first?.condition, .healthy)
    }

    func testFacadePreservesMergedDependsOnMetadataAcrossComposeFiles() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        services:
          api:
            image: backend
          db:
            image: postgres
          web:
            image: nginx
            depends_on:
              db:
                condition: service_healthy
                restart: true
                required: false
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        try """
        services:
          web:
            depends_on:
              - api
              - db
        """.write(to: workdir.appendingPathComponent("compose.override.yaml"), atomically: true, encoding: .utf8)

        let result = try ContainerComposeService().makePlan(.init(
            operation: .up,
            projectDirectory: workdir.path,
            projectName: "desktop-merged",
            emitReadinessChecks: true
        ))

        let graph = try XCTUnwrap(result.plan.executionGraph)
        let runtimeIndexByService = Dictionary(uniqueKeysWithValues: result.plan.commands.enumerated().compactMap { index, command in
            command.action == .runService ? command.service.map { ($0, index) } : nil
        })
        let webIndex = try XCTUnwrap(runtimeIndexByService["web"])
        let apiIndex = try XCTUnwrap(runtimeIndexByService["api"])
        let dbIndex = try XCTUnwrap(runtimeIndexByService["db"])
        let apiEdge = try XCTUnwrap(graph.edges.first {
            $0.fromCommandIndex == apiIndex && $0.toCommandIndex == webIndex
        })
        let dbEdge = try XCTUnwrap(graph.edges.first {
            $0.fromCommandIndex == dbIndex && $0.toCommandIndex == webIndex
        })
        let webNode = try XCTUnwrap(graph.nodes.first { $0.commandIndex == webIndex })

        XCTAssertEqual(apiEdge.dependencyMetadata, AppleContainerDependencyMetadata())
        XCTAssertEqual(dbEdge.dependencyMetadata, AppleContainerDependencyMetadata(
            condition: .serviceHealthy,
            restart: true,
            required: false
        ))
        XCTAssertEqual(webNode.readiness.first { $0.service == "api" }?.condition, .started)
        XCTAssertEqual(webNode.readiness.first { $0.service == "db" }?.condition, .healthy)
    }

    func testFacadeInjectsRemoteIncludeFetcherForTrustedDesktopFetches() throws {
        let workdir = try makeTemporaryWorkdir()
        defer { try? FileManager.default.removeItem(at: workdir) }

        try """
        include:
          - https://example.test/shared.compose.yaml
        services: {}
        """.write(to: workdir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let yamlByURL = [
            "https://example.test/shared.compose.yaml": """
            services:
              worker:
                image: busybox
            """
        ]
        let service = ContainerComposeService(remoteIncludeResolver: { request in
            guard let yaml = yamlByURL[request.url.absoluteString] else {
                throw ComposeLoadError.fileNotFound([request.url.absoluteString])
            }
            return ComposeLoader.RemoteIncludeResponse(
                yaml: yaml,
                cacheKey: "desktop-shared-compose",
                cacheStatus: .hit,
                source: "container-desktop-cache"
            )
        })

        let result = try service.makePlan(.init(
            operation: .plan,
            projectDirectory: workdir.path,
            projectName: "remote-demo",
            environment: [:],
            allowRemoteIncludes: true,
            detach: true
        ))

        XCTAssertEqual(result.project.name, "remote-demo")
        XCTAssertEqual(result.project.services.map(\.name), ["worker"])
        XCTAssertEqual(result.project.remoteIncludes.first?.cacheKey, "desktop-shared-compose")
        XCTAssertEqual(result.project.remoteIncludes.first?.cacheStatus, .hit)
        XCTAssertEqual(result.project.remoteIncludes.first?.source, "container-desktop-cache")
        XCTAssertEqual(result.plan.commands.first { $0.action == .runService }?.service, "worker")
    }

    private func makeTemporaryWorkdir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-compose-service-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class ServiceFakeContainerCommandExecutor: ContainerCommandExecutor {
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

private final class ServiceFakeReadinessChecker: ContainerReadinessChecking {
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
            return .init(requirement: requirement, status: .failed)
        }
        var result = results.removeFirst()
        result.requirement = requirement
        return result
    }
}
